# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 WasalX
require 'minitest/autorun'
require 'ostruct'

# Small unit doubles exercise the package's authorization decisions. Real native
# Token/Role callbacks and the atomic transaction are covered by the image gate.
module ActiveSupport
  module Concern
    def included(base = nil, &block); super(base) if base; end
  end
end
class Object
  def present?; !nil? && self != false && (!respond_to?(:empty?) || !empty?); end
end
class Hash
  def with_indifferent_access; transform_keys(&:to_s).tap { |h| h.default_proc = ->(map, key) { map[key.to_s] unless key.is_a?(String) } }; end
end
module Exceptions
  class Forbidden < StandardError; end
end
class Relation < Array
  def pluck(name); map { |entry| entry.public_send(name) }; end
  def exists?; any?; end
end
class Setting
  class << self
    attr_accessor :value
    def find_by(name:); OpenStruct.new(state_current: { 'value' => value }); end
  end
end
class User
  class << self
    attr_accessor :records
    def find_by(id:); records[id.to_i]; end
    def find(id); records.fetch(id.to_i); end
    def where(*); Relation.new(records.values.select { |user| user.login.start_with?('tenant-automation-') }); end
    def joins(*); self; end
  end
end
class Token
  class << self
    attr_accessor :records
    def find_by(id:); records[id.to_i]; end
    def where(**); Relation.new(records.values); end
  end
end
class Authorization
  def self.exists?(user_id:); User.records[user_id].authorized; end
end
class NativeUser
  attr_accessor :id, :login, :preferences, :active, :password, :authorized, :permission_names, :role_names, :factors
  def initialize(id)
    @id = id; @login = "human-#{id}"; @preferences = {}; @active = true; @authorized = false
    @permission_names = []; @role_names = []; @factors = []
  end
  def persisted?; true; end
  def permissions; Relation.new(permission_names.map { |name| OpenStruct.new(name: name) }); end
  def permissions?(name); permission_names.include?(name); end
  def roles; Relation.new(role_names.map { |name| OpenStruct.new(name: name) }); end
  def two_factor_preferences; Relation.new(factors); end
end
class NativeToken
  attr_accessor :id, :user_id, :action, :persistent, :preferences, :name, :expired
  def initialize(id, user_id, scopes, name)
    @id = id; @user_id = user_id; @action = 'api'; @persistent = true; @preferences = { permission: scopes }; @name = name; @expired = false
  end
  def expired?; expired; end
  def user; User.find_by(id: user_id); end
end
ENV['WASALX_TENANT_ID'] = '10000000-0000-4000-8000-000000000001'
ENV['WASALX_ZAMMAD_INSTANCE_ID'] = '20000000-0000-4000-8000-000000000001'
load File.join(ENV.fetch('WASALX_TEST_PACKAGE_ROOT', File.expand_path('../zammad-package', __dir__)), 'lib/wasalx/service_identity.rb')

class TenantServiceIdentityContract < Minitest::Test
  Guard = Wasalx::ServiceIdentity
  def setup
    Setting.value = nil
    @human = NativeUser.new(4)
    @human.permission_names = %w[admin.system admin.data_privacy ticket.agent]
    @machine = NativeUser.new(5)
    @machine.login = Guard.login
    @machine.preferences = { Guard::MARKER => { 'tenant_id' => ENV['WASALX_TENANT_ID'], 'instance_id' => ENV['WASALX_ZAMMAD_INSTANCE_ID'] } }
    @machine.permission_names = %w[ticket.agent wasalx_service wasalx_privacy]
    @machine.role_names = %w[Agent]
    User.records = { 4 => @human, 5 => @machine }
    @runtime = NativeToken.new(11, 5, Guard::SCOPES['runtime'], 'WasalX Service')
    @privacy = NativeToken.new(12, 5, Guard::SCOPES['privacy'], 'WasalX Privacy')
    Token.records = { 11 => @runtime, 12 => @privacy }
    @receipt = { 'schema_version' => 1, 'phase' => 'BOUND', 'revision' => 2,
      'tenant_id' => ENV['WASALX_TENANT_ID'], 'instance_id' => ENV['WASALX_ZAMMAD_INSTANCE_ID'],
      'automation_native_user_id' => '5', 'human_native_user_id' => '4', 'legacy_native_user_id' => '3',
      'runtime_token_id' => '11', 'privacy_token_id' => '12', 'automation_login' => Guard.login,
      'runtime_scope_names' => Guard::SCOPES['runtime'], 'privacy_scope_names' => Guard::SCOPES['privacy'] }
    Setting.value = @receipt
  end

  def test_fresh_receipt_binds_real_owner_without_inventing_a_retired_predecessor
    @receipt['schema_version'] = 2
    @receipt['origin'] = 'FRESH'
    @receipt['human_subject'] = 'actual-owner-subject'
    @receipt['human_email'] = 'owner@example.invalid'
    @receipt.delete('legacy_native_user_id')
    assert_equal 'FRESH', Guard.receipt['origin']
    assert Guard.token_allowed?(@machine, @runtime, 'runtime')
    assert Guard.token_allowed?(@machine, @privacy, 'privacy')
    refute Guard.token_allowed?(@human, @runtime, 'runtime')
    @receipt['human_native_user_id'] = @machine.id.to_s
    assert_raises(Guard::Conflict) { Guard.receipt }
    refute Guard.token_allowed?(@machine, @runtime, 'runtime')
  end

  def test_fresh_receipt_cannot_claim_legacy_completion_or_missing_owner_identity
    @receipt.merge!('schema_version' => 2, 'origin' => 'FRESH', 'phase' => 'COMPLETE',
      'human_subject' => 'owner-subject', 'human_email' => 'owner@example.invalid')
    assert_raises(Guard::Conflict) { Guard.receipt }
    @receipt['phase'] = 'BOUND'
    @receipt.delete('human_subject')
    assert_raises(Guard::Conflict) { Guard.receipt }
  end

  def test_exact_token_identity_and_scope_separation
    assert Guard.authorize!(@machine, @runtime)
    assert Guard.authorize!(@machine, @privacy, 'privacy')
    refute Guard.token_allowed?(@machine, @privacy, 'runtime')
    refute Guard.token_allowed?(@machine, @runtime, 'privacy')
    clone = NativeToken.new(13, 5, Guard::SCOPES['runtime'], 'WasalX Service')
    Token.records[13] = clone
    refute Guard.token_allowed?(@machine, clone, 'runtime')
    @runtime.preferences = { permission: %w[ticket.agent wasalx_service wasalx_privacy] }
    refute Guard.token_allowed?(@machine, @runtime, 'runtime')
  end

  def test_same_machine_with_any_human_authority_or_credentials_is_denied
    mutations = [-> { @machine.permission_names << 'admin.system' }, -> { @machine.role_names << 'Admin' },
      -> { @machine.authorized = true }, -> { @machine.password = 'fixture-hash' }, -> { @machine.factors << :totp },
      -> { @machine.active = false }, -> { @runtime.expired = true }, -> { @runtime.persistent = false },
      -> { @runtime.action = 'PasswordReset' }, -> { @runtime.user_id = 4 }]
    mutations.each do |change|
      setup
      change.call
      refute Guard.token_allowed?(@machine, @runtime, 'runtime')
    end
  end

  def test_machine_guard_reads_persisted_roles_instead_of_a_cached_user
    stale = @machine.dup
    @machine.permission_names = @machine.permission_names + ['admin.system']
    refute Guard.token_allowed?(stale, @runtime, 'runtime')
    assert Guard.automation?(stale)
  end

  def test_prepared_machine_cannot_authenticate_but_only_exact_legacy_tokens_continue
    @receipt['phase'] = 'PREPARED'
    @receipt['legacy_native_user_id'] = '4'
    @runtime.user_id = 4
    @runtime.preferences = { permission: Guard::LEGACY_SCOPES['runtime'] }
    assert Guard.authorize!(@human, @runtime)
    refute Guard.token_allowed?(@machine, @runtime, 'runtime')
    assert Guard.automation?(@machine)
    @runtime.preferences = { permission: ['admin.system'] }
    assert_raises(Exceptions::Forbidden) { Guard.authorize!(@human, @runtime) }
  end

  def test_missing_and_corrupt_receipts_never_return_machine_to_interactive_or_legacy_access
    [nil, {}, { 'phase' => 'BOUND', 'tenant_id' => 'foreign' }].each do |receipt|
      Setting.value = receipt
      assert Guard.automation?(@machine)
      assert_raises(Guard::Conflict) { Guard.legacy_bootstrap_allowed! }
      assert_raises(Exceptions::Forbidden) { Guard.authorize!(@machine, @runtime) }
    end
  end

  def test_ordinary_admin_or_agent_and_arbitrary_token_cannot_call_machine_endpoints
    assert_raises(Exceptions::Forbidden) { Guard.authorize!(@human, @runtime) }
    Setting.value = nil
    User.records.delete(5)
    @runtime.user_id = 4
    @runtime.name = 'Unrelated admin token'
    @privacy.user_id = 4
    assert_raises(Exceptions::Forbidden) { Guard.authorize!(@human, @runtime) }
    @runtime.name = 'WasalX Service'
    assert Guard.authorize!(@human, @runtime) # Untouched legacy contract only.
    @human.permission_names = ['ticket.agent']
    assert_raises(Exceptions::Forbidden) { Guard.authorize!(@human, @runtime) }
  end

  def test_prepared_machine_password_reset_signup_and_password_authentication_are_blocked
    @receipt['phase'] = 'PREPARED'
    auth = Class.new do
      attr_accessor :user
      def can_login?; true; end
      prepend Wasalx::ServiceIdentity::PasswordAuthentication
    end.new
    auth.user = @machine
    refute auth.can_login?
    auth.user = @human
    assert auth.can_login?
    recovery = Class.new do
      class << self
        attr_accessor :user, :calls
        def identify(_name); user; end
        def password_reset_new_token(_name); self.calls += 1; :token; end
        def signup_new_token(_user); self.calls += 1; :token; end
        def by_reset_token(_token); user; end
      end
    end
    recovery.singleton_class.prepend Guard::Recovery
    recovery.user = @machine; recovery.calls = 0
    assert_nil recovery.password_reset_new_token('machine')
    assert_nil recovery.signup_new_token(@machine)
    assert_nil recovery.by_reset_token('old-token')
    assert_equal 0, recovery.calls
    recovery.user = @human
    assert_equal :token, recovery.password_reset_new_token('human')
    assert_equal @human, recovery.by_reset_token('human-token')
  end
  def test_readback_and_reconcile_recheck_current_machine_and_complete_retirement
    secrets = { 'runtime' => 'fixture-runtime-secret', 'privacy' => 'fixture-privacy-secret' }
    seen = []
    original = %i[owner! verify_tokens! verify_retirement!].to_h { |name| [name, Guard.method(name)] }
    owner = @human
    Guard.define_singleton_method(:owner!) { |_record| owner }
    Guard.define_singleton_method(:verify_tokens!) { |_record, secrets:| seen << :tokens }
    Guard.define_singleton_method(:verify_retirement!) { |_record, _owner| seen << :retirement }
    assert_equal @receipt, Guard.verify_current!(@receipt, secrets: secrets)
    assert_equal [:tokens], seen
    @receipt['phase'] = 'COMPLETE'
    Guard.verify_current!(@receipt, secrets: secrets)
    assert_equal [:tokens, :tokens, :retirement], seen
    @machine.active = false
    assert_raises(Guard::Conflict) { Guard.verify_current!(@receipt, secrets: secrets) }
    assert_equal [:tokens, :tokens, :retirement], seen
  ensure
    original.each { |name, method| Guard.define_singleton_method(name, method) }

  end

  def test_offline_startup_checks_integrity_without_authorizing_a_transition
    secrets = { 'runtime' => 'fixture-runtime-secret', 'privacy' => 'fixture-privacy-secret' }
    seen = []
    original = %i[native_owner! owner! verify_tokens! verify_native_retirement!].to_h { |name| [name, Guard.method(name)] }
    owner = @human
    Guard.define_singleton_method(:native_owner!) { |_record| seen << :local_owner; owner }
    Guard.define_singleton_method(:owner!) { |_record| raise Guard::Conflict, 'Control plane unavailable' }
    Guard.define_singleton_method(:verify_tokens!) { |_record, secrets:| seen << :tokens }
    Guard.define_singleton_method(:verify_native_retirement!) { |_record, _owner| seen << :local_retirement }
    before = Marshal.dump(Setting.value)
    assert_equal @receipt, Guard.verify_startup!(@receipt, secrets: secrets)
    assert_equal [:local_owner, :tokens], seen
    assert_equal before, Marshal.dump(Setting.value)
    assert_raises(Guard::Conflict) { Guard.verify_current!(@receipt, secrets: secrets) }
    @receipt['phase'] = 'COMPLETE'
    Guard.verify_startup!(@receipt, secrets: secrets)
    assert_equal [:local_owner, :tokens, :local_owner, :tokens, :local_retirement], seen
    @machine.active = false
    assert_raises(Guard::Conflict) { Guard.verify_startup!(@receipt, secrets: secrets) }
    assert_equal :local_owner, seen.last
  ensure
    original.each { |name, method| Guard.define_singleton_method(name, method) }
  end

end
