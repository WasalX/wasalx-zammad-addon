# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>

require 'digest'
require 'base64'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'rubygems'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
INSTALLER = File.join(ROOT, 'infra/docker/full/zammad/install-package.rb')

PackageRecord = Struct.new(:name, :version, :state)

class Package
  class << self
    attr_accessor :record, :calls, :bins

    def find_by(name:)
      record if record&.name == name
    end

    def install(file:, reinstall: false)
      metadata = JSON.parse(File.read(file))
      calls << [:install, metadata.fetch('version'), reinstall]
      if record && !reinstall && Gem::Version.new(record.version) >= Gem::Version.new(metadata.fetch('version'))
        raise 'Zammad refused a same-version or downgrade install'
      end

      if record&.state == 'installed'
        JSON.parse(bins.fetch([record.name, record.version])).fetch('files').each do |entry|
          _delete_file(entry.fetch('location'), entry.fetch('permission'), Base64.strict_decode64(entry.fetch('content')))
        end
      end
      metadata.fetch('files').each do |entry|
        _write_file(entry.fetch('location'), entry.fetch('permission'), Base64.strict_decode64(entry.fetch('content')))
      end
      bins[[metadata.fetch('name'), metadata.fetch('version')]] = JSON.generate(metadata)
      self.record = PackageRecord.new(metadata.fetch('name'), metadata.fetch('version'), 'installed') unless reinstall
      record.state = 'installed' if reinstall
      record
    end

    def _write_file(location, permission, data)
      path = File.join(ENV.fetch('WASALX_ZAMMAD_ROOT'), location)
      FileUtils.mkdir_p(File.dirname(path))
      File.rename(path, "#{path}.save") if File.exist?(path)
      File.binwrite(path, data)
      File.chmod(permission.to_i(8), path)
    end

    def _delete_file(location, _permission, _data)
      FileUtils.rm_f(File.join(ENV.fetch('WASALX_ZAMMAD_ROOT'), location))
    end

    def _get_bin(name, version)
      bins.fetch([name, version])
    end

    def uninstall(name:, version:, migration_not_down:)
      raise 'Unexpected package record' unless record&.name == name && record.version == version

      calls << [:uninstall, name, version, migration_not_down]
      JSON.parse(bins.fetch([name, version])).fetch('files').each do |entry|
        _delete_file(entry.fetch('location'), entry.fetch('permission'), Base64.strict_decode64(entry.fetch('content')))
      end
      removed = record
      self.record = nil
      removed
    end
  end

  class Migration
    class << self
      attr_accessor :receipts, :query_error

      def exists?(name:, version:)
        raise query_error if query_error

        receipts.include?([name, version])
      end
    end
  end
end

module Delayed
  class Job
    class << self
      attr_accessor :handlers, :query_error

      def where(query, pattern)
        raise query_error if query_error
        raise 'Unexpected legacy job query' unless query == 'handler LIKE ?' && pattern == '%WasalxTicketRoutingJob%'

        @matching = handlers.any? { |handler| handler.include?('WasalxTicketRoutingJob') }
        self
      end

      def exists?
        @matching == true
      end
    end
  end
end

class ZammadPackageInstallContractTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('wasalx-zammad-install')
    @application_root = File.join(@directory, 'zammad')
    FileUtils.mkdir_p(File.join(@application_root, 'contrib'))
    Package.calls = []
    Package.bins = {}
    Package::Migration.receipts = []
    Package::Migration.query_error = nil
    Delayed::Job.handlers = []
    Delayed::Job.query_error = nil
  end

  def teardown
    %w[WASALX_ZPM_PATH WASALX_PACKAGE_VERSION WASALX_PACKAGE_SHA256 WASALX_ZAMMAD_ROOT].each { |name| ENV.delete(name) }
    FileUtils.remove_entry(@directory)
  end

  def archive(version, files)
    JSON.generate(
      name: 'wasalx',
      version: version,
      files: files.map do |location, content|
        { location: location, permission: '644', content: Base64.strict_encode64(content) }
      end,
    )
  end

  def materialize(files)
    files.each do |location, content|
      path = File.join(@application_root, location)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, content)
      File.chmod(0o644, path)
    end
  end

  def run_installer(expected_version, installed:, baked_version:, baked_files:, target_files:, installed_files: baked_files, installed_archive: nil)
    artifact = File.join(@directory, "wasalx-#{expected_version}.zpm")
    baked_archive = archive(baked_version, baked_files)
    target_archive = archive(expected_version, target_files)
    File.binwrite(File.join(@application_root, 'contrib', 'wasalx.zpm'), baked_archive)
    File.binwrite(artifact, target_archive)
    materialize(baked_files)
    yield @application_root if block_given?
    Package.record = installed
    Package.bins[[installed.name, installed.version]] = installed_archive || archive(installed.version, installed_files) if installed
    ENV['WASALX_ZPM_PATH'] = artifact
    ENV['WASALX_PACKAGE_VERSION'] = expected_version
    ENV['WASALX_PACKAGE_SHA256'] = Digest::SHA256.file(artifact).hexdigest
    ENV['WASALX_ZAMMAD_ROOT'] = @application_root
    capture_io { load INSTALLER }
    Package.record
  end

  def test_downgrade_replaces_the_stored_artifact_without_reversing_migrations
    installed = PackageRecord.new('wasalx', '0.5.27', 'installed')

    result = run_installer(
      '0.5.26',
      installed: installed,
      baked_version: '0.5.27',
      baked_files: { 'app/shared.rb' => 'current shared', 'db/addon/wasalx/current_only.rb' => 'current only' },
      target_files: { 'app/shared.rb' => 'predecessor shared', 'db/addon/wasalx/predecessor.rb' => 'predecessor only' },
    )

    assert_equal '0.5.26', result.version
    assert_equal 'installed', result.state
    assert_equal [
      [:uninstall, 'wasalx', '0.5.27', true],
      [:install, '0.5.26', false],
    ], Package.calls
    refute_path_exists File.join(@application_root, 'db/addon/wasalx/current_only.rb')
    assert_equal 'predecessor shared', File.binread(File.join(@application_root, 'app/shared.rb'))
    assert_equal 'predecessor only', File.binread(File.join(@application_root, 'db/addon/wasalx/predecessor.rb'))
  end

  def test_exact_installed_package_is_an_idempotent_no_op
    installed = PackageRecord.new('wasalx', '0.5.27', 'installed')

    files = { 'app/shared.rb' => 'current shared' }
    result = run_installer('0.5.27', installed: installed, baked_version: '0.5.27', baked_files: files, target_files: files)

    assert_same installed, result
    assert_empty Package.calls
  end

  def test_exact_uninstalled_package_uses_zammads_supported_reinstall_path
    installed = PackageRecord.new('wasalx', '0.5.27', 'uninstalled')

    files = { 'app/shared.rb' => 'current shared' }
    result = run_installer('0.5.27', installed: installed, baked_version: '0.5.27', baked_files: files, target_files: files)

    assert_same installed, result
    assert_equal 'installed', result.state
    assert_equal [[:install, '0.5.27', true]], Package.calls
  end

  def test_initial_predecessor_install_removes_every_baked_current_file_before_install
    result = run_installer(
      '0.5.26',
      installed: nil,
      baked_version: '0.5.27',
      baked_files: { 'app/shared.rb' => 'current shared', 'db/addon/wasalx/current_only.rb' => 'current only' },
      target_files: { 'app/shared.rb' => 'predecessor shared', 'db/addon/wasalx/predecessor.rb' => 'predecessor only' },
    )

    assert_equal '0.5.26', result.version
    assert_equal [[:install, '0.5.26', false]], Package.calls
    refute_path_exists File.join(@application_root, 'db/addon/wasalx/current_only.rb')
    assert_equal 'predecessor shared', File.binread(File.join(@application_root, 'app/shared.rb'))
  end

  def test_initial_current_install_does_not_leave_zammad_save_files
    files = { 'app/shared.rb' => 'current shared' }
    result = run_installer(
      '0.5.27',
      installed: nil,
      baked_version: '0.5.27',
      baked_files: files,
      target_files: files,
    )

    assert_equal '0.5.27', result.version
    assert_equal 'current shared', File.binread(File.join(@application_root, 'app/shared.rb'))
    refute_path_exists File.join(@application_root, 'app/shared.rb.save')
  end

  def test_exact_old_record_reinstalls_target_over_fresh_current_image_files
    installed = PackageRecord.new('wasalx', '0.5.26', 'installed')
    result = run_installer(
      '0.5.26',
      installed: installed,
      baked_version: '0.5.27',
      baked_files: { 'app/shared.rb' => 'current shared', 'db/addon/wasalx/current_only.rb' => 'current only' },
      installed_files: { 'app/shared.rb' => 'predecessor shared' },
      target_files: { 'app/shared.rb' => 'predecessor shared' },
    )

    assert_same installed, result
    assert_equal [[:install, '0.5.26', true]], Package.calls
    refute_path_exists File.join(@application_root, 'db/addon/wasalx/current_only.rb')
    assert_equal 'predecessor shared', File.binread(File.join(@application_root, 'app/shared.rb'))
  end

  def test_same_version_alternate_artifact_is_rejected
    installed = PackageRecord.new('wasalx', '0.5.27', 'installed')
    error = assert_raises(RuntimeError) do
      run_installer(
        '0.5.27',
        installed: installed,
        baked_version: '0.5.27',
        baked_files: { 'app/shared.rb' => 'immutable bytes' },
        target_files: { 'app/shared.rb' => 'different bytes' },
      )
    end

    assert_equal 'WasalX same-version package differs from the immutable image artifact', error.message
    assert_empty Package.calls
  end

  def test_immutable_install_rejects_wrong_mode_before_database_changes
    skip 'POSIX file-mode semantics are qualified on the Linux release runner' if Gem.win_platform?
    files = { 'app/shared.rb' => 'current shared' }
    error = assert_raises(RuntimeError) do
      run_installer('0.5.27', installed: nil, baked_version: '0.5.27', baked_files: files, target_files: files) do |root|
        File.chmod(0o600, File.join(root, 'app/shared.rb'))
      end
    end
    assert_match(/immutable package file mismatch/, error.message)
    assert_empty Package.calls
  end

  def test_immutable_upgrade_and_rollback_preserve_baked_files_and_native_metadata
    [['0.5.26', '0.5.27'], ['0.5.27', '0.5.26']].each do |old_version, target_version|
      files = { 'app/shared.rb' => 'new bytes' }
      result = run_installer(target_version, installed: PackageRecord.new('wasalx', old_version, 'installed'),
                            baked_version: target_version, baked_files: files, target_files: files,
                            installed_files: { 'app/shared.rb' => 'old bytes', 'app/old.rb' => 'old only' })
      assert_equal target_version, result.version
      assert_equal 'new bytes', File.binread(File.join(@application_root, 'app/shared.rb'))
      refute_path_exists File.join(@application_root, 'app/shared.rb.save')
      refute_path_exists File.join(@application_root, 'app/old.rb')
    end
  end

  def test_immutable_install_rejects_stale_and_backup_files_before_database_changes
    ['app/old.rb', 'app/shared.rb.save'].each do |unexpected|
      files = { 'app/shared.rb' => 'new bytes' }
      error = assert_raises(RuntimeError) do
        run_installer('0.5.27', installed: PackageRecord.new('wasalx', '0.5.26', 'installed'),
                      baked_version: '0.5.27', baked_files: files, target_files: files,
                      installed_files: { 'app/old.rb' => 'old only' }) do |root|
          File.binwrite(File.join(root, unexpected), 'old only')
        end
      end
      assert_match(/immutable package (stale file|backup) exists/, error.message)
      assert_empty Package.calls
      File.delete(File.join(@application_root, unexpected))
    end
  end

  def test_immutable_install_rejects_symlink_before_database_changes
    skip 'symlinks are qualified on the Linux release runner' if Gem.win_platform?
    files = { 'app/shared.rb' => 'current shared' }
    error = assert_raises(RuntimeError) do
      run_installer('0.5.27', installed: nil, baked_version: '0.5.27', baked_files: files, target_files: files) do |root|
        path = File.join(root, 'app/shared.rb')
        File.rename(path, "#{path}.other")
        File.symlink("#{path}.other", path)
      end
    end
    assert_match(/package path is a symlink/, error.message)
    assert_empty Package.calls
  end

  def test_immutable_install_rejects_native_method_contract_drift
    files = { 'app/shared.rb' => 'current shared' }
    original = Package.method(:_write_file)
    Package.define_singleton_method(:_write_file) { |*| raise 'must not execute' }
    error = assert_raises(RuntimeError) do
      run_installer('0.5.27', installed: nil, baked_version: '0.5.27', baked_files: files, target_files: files)
    end
    assert_equal 'WasalX native package file contract changed', error.message
    assert_empty Package.calls
  ensure
    Package.define_singleton_method(:_write_file, original)
  end

  def test_immutable_adapter_rejects_unexpected_native_effects_and_restores_methods
    files = { 'app/shared.rb' => 'current shared' }
    original_install = Package.method(:install)
    original_write = Package.method(:_write_file)
    original_delete = Package.method(:_delete_file)
    [[:_write_file, 'app/unowned.rb', '644', 'bad'],
     [:_write_file, 'app/shared.rb', '644', 'bad'],
     [:_write_file, 'app/shared.rb', '600', 'current shared'],
     [:_delete_file, 'app/unowned.rb', '644', 'bad']].each do |method, *args|
      Package.define_singleton_method(:install) { |**| public_send(method, *args) }
      error = assert_raises(RuntimeError) do
        run_installer('0.5.27', installed: nil, baked_version: '0.5.27', baked_files: files, target_files: files)
      end
      assert_match(/unexpected immutable package/, error.message)
      assert_equal original_write, Package.method(:_write_file)
      assert_equal original_delete, Package.method(:_delete_file)
    end
  ensure
    Package.define_singleton_method(:install, original_install)
  end

  def test_modified_late_file_aborts_before_any_owned_file_is_removed
    installed = PackageRecord.new('wasalx', '0.5.27', 'installed')
    files = { 'app/safe.rb' => 'safe bytes', 'app/modified.rb' => 'owned bytes' }
    error = assert_raises(RuntimeError) do
      run_installer('0.5.27', installed: installed, baked_version: '0.5.27', baked_files: files, target_files: files) do |root|
        File.binwrite(File.join(root, 'app/modified.rb'), 'operator bytes')
      end
    end

    assert_equal 'WasalX immutable package file mismatch: app/modified.rb', error.message
    assert_equal 'safe bytes', File.binread(File.join(@application_root, 'app/safe.rb'))
    assert_equal 'operator bytes', File.binread(File.join(@application_root, 'app/modified.rb'))
    assert_empty Package.calls
  end

  def test_late_symlink_ancestor_aborts_before_any_owned_file_is_removed
    installed = PackageRecord.new('wasalx', '0.5.27', 'installed')
    baked = { 'app/safe.rb' => 'safe bytes', 'linked/owned.rb' => 'owned bytes' }
    external = File.join(@directory, 'external')
    FileUtils.mkdir_p(external)
    File.binwrite(File.join(external, 'owned.rb'), 'external bytes')
    probe = File.join(@directory, 'symlink-probe')
    begin
      File.symlink(external, probe)
      File.unlink(probe)
    rescue NotImplementedError, Errno::EACCES, Errno::EPERM
      skip 'directory symlinks are unavailable on this host'
    end
    error = assert_raises(RuntimeError) do
      run_installer(
        '0.5.26', installed: installed, baked_version: '0.5.27', baked_files: baked,
        target_files: { 'app/target.rb' => 'target bytes' },
      ) do |root|
        FileUtils.remove_entry(File.join(root, 'linked'))
        File.symlink(external, File.join(root, 'linked'))
      end
    end

    assert_equal 'WasalX package path is a symlink: linked/owned.rb', error.message
    assert_equal 'safe bytes', File.binread(File.join(@application_root, 'app/safe.rb'))
    assert_equal 'external bytes', File.binread(File.join(external, 'owned.rb'))
    assert_empty Package.calls
  end

  def test_same_old_version_alternate_artifact_is_rejected_before_reinstall
    installed = PackageRecord.new('wasalx', '0.5.26', 'installed')
    error = assert_raises(RuntimeError) do
      run_installer(
        '0.5.26',
        installed: installed,
        baked_version: '0.5.27',
        baked_files: { 'app/shared.rb' => 'current bytes' },
        installed_files: { 'app/shared.rb' => 'stored predecessor bytes' },
        target_files: { 'app/shared.rb' => 'alternate predecessor bytes' },
      )
    end

    assert_equal 'WasalX same-version package differs from the stored artifact', error.message
    assert_empty Package.calls
  end

  def test_same_version_stored_archive_with_reordered_keys_is_rejected
    installed = PackageRecord.new('wasalx', '0.5.26', 'installed')
    files = { 'app/shared.rb' => 'owned bytes' }
    parsed = JSON.parse(archive('0.5.26', files))
    reordered = JSON.generate('version' => parsed.fetch('version'), 'name' => parsed.fetch('name'), 'files' => parsed.fetch('files'))

    error = assert_raises(RuntimeError) do
      run_installer(
        '0.5.26', installed: installed, baked_version: '0.5.26', baked_files: files,
        target_files: files, installed_archive: reordered,
      )
    end

    assert_equal 'WasalX same-version package differs from the stored artifact', error.message
    assert_empty Package.calls
  end

  def test_boundary_transition_blocks_routing_jobs_before_reading_or_removing_package_files
    Delayed::Job.handlers = ['job_class: WasalxTicketRoutingJob']

    [['0.5.42', '0.5.43'], ['0.5.43', '0.5.42'], ['0.5.44', '0.5.45'], ['0.5.45', '0.5.44'], ['0.5.45', '0.5.46'], ['0.5.46', '0.5.45']].each do |installed_version, target_version|
      error = assert_raises(RuntimeError) do
        run_installer(
          target_version, installed: PackageRecord.new('wasalx', installed_version, 'installed'), baked_version: target_version,
          baked_files: { 'app/safe.rb' => 'safe bytes' }, target_files: { 'app/safe.rb' => 'new bytes' },
        )
      end

      assert_equal 'WasalX routing jobs must finish before package transition', error.message
      assert_equal 'safe bytes', File.binread(File.join(@application_root, 'app/safe.rb'))
      assert_empty Package.calls
    end
  end

  def test_same_version_with_an_incomplete_migration_blocks_legacy_routing_jobs
    Delayed::Job.handlers = ['job_class: WasalxTicketRoutingJob']
    files = { 'app/shared.rb' => 'current shared' }

    error = assert_raises(RuntimeError) do
      run_installer('0.5.46', installed: PackageRecord.new('wasalx', '0.5.46', 'installed'),
                    baked_version: '0.5.46', baked_files: files, target_files: files)
    end

    assert_equal 'WasalX routing jobs must finish before package transition', error.message
    assert_empty Package.calls
  end

  def test_same_version_with_a_complete_migration_is_an_idempotent_no_op
    Package::Migration.receipts = [['wasalx', '202609020015']]
    Delayed::Job.handlers = ['job_class: WasalxTicketRoutingJob']
    installed = PackageRecord.new('wasalx', '0.5.46', 'installed')
    files = { 'app/shared.rb' => 'current shared' }

    result = run_installer('0.5.46', installed: installed, baked_version: '0.5.46', baked_files: files, target_files: files)

    assert_same installed, result
    assert_empty Package.calls
  end

  def test_same_version_fails_closed_when_migration_receipts_cannot_be_inspected
    Package::Migration.query_error = StandardError.new('private database details')
    files = { 'app/shared.rb' => 'current shared' }

    error = assert_raises(RuntimeError) do
      run_installer('0.5.46', installed: PackageRecord.new('wasalx', '0.5.46', 'installed'),
                    baked_version: '0.5.46', baked_files: files, target_files: files)
    end

    assert_equal 'WasalX package migration preflight is unavailable', error.message
    refute_includes error.message, 'private database details'
    assert_empty Package.calls
  end

  def test_boundary_transition_fails_closed_when_the_routing_queue_cannot_be_inspected
    Delayed::Job.query_error = StandardError.new('private database details')

    [['0.5.42', '0.5.43'], ['0.5.43', '0.5.42'], ['0.5.44', '0.5.45'], ['0.5.45', '0.5.44'], ['0.5.45', '0.5.46'], ['0.5.46', '0.5.45']].each do |installed_version, target_version|
      error = assert_raises(RuntimeError) do
        run_installer(
          target_version, installed: PackageRecord.new('wasalx', installed_version, 'installed'), baked_version: target_version,
          baked_files: { 'app/safe.rb' => 'safe bytes' }, target_files: { 'app/safe.rb' => 'new bytes' },
        )
      end

      assert_equal 'WasalX routing queue preflight is unavailable', error.message
      refute_includes error.message, 'private database details'
      assert_equal 'safe bytes', File.binread(File.join(@application_root, 'app/safe.rb'))
      assert_empty Package.calls
    end
  end

  def test_boundary_transition_fails_closed_when_the_delayed_job_model_is_unavailable
    job_model = Delayed.send(:remove_const, :Job)
    begin
      [['0.5.42', '0.5.43'], ['0.5.43', '0.5.42'], ['0.5.44', '0.5.45'], ['0.5.45', '0.5.44'], ['0.5.45', '0.5.46'], ['0.5.46', '0.5.45']].each do |installed_version, target_version|
        error = assert_raises(RuntimeError) do
          run_installer(
            target_version, installed: PackageRecord.new('wasalx', installed_version, 'installed'), baked_version: target_version,
            baked_files: { 'app/safe.rb' => 'safe bytes' }, target_files: { 'app/safe.rb' => 'new bytes' },
          )
        end

        assert_equal 'WasalX routing queue preflight is unavailable', error.message
        assert_equal 'safe bytes', File.binread(File.join(@application_root, 'app/safe.rb'))
        assert_empty Package.calls
      end
    ensure
      Delayed.const_set(:Job, job_model)
    end
  end

  def test_stored_archive_identity_mismatch_is_rejected_before_owned_files_are_removed
    installed = PackageRecord.new('wasalx', '0.5.43', 'installed')
    stored = JSON.parse(archive('0.5.43', { 'app/safe.rb' => 'safe bytes' }))
    stored['version'] = '0.5.42'

    error = assert_raises(RuntimeError) do
      run_installer(
        '0.5.42', installed: installed, baked_version: '0.5.43',
        baked_files: { 'app/safe.rb' => 'safe bytes' }, target_files: { 'app/target.rb' => 'target bytes' },
        installed_archive: JSON.generate(stored),
      )
    end

    assert_equal 'WasalX stored package identity mismatch', error.message
    assert_equal 'safe bytes', File.binread(File.join(@application_root, 'app/safe.rb'))
    assert_empty Package.calls
  end
end
