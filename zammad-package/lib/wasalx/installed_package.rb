# SPDX-License-Identifier: AGPL-3.0-only
require 'json'
# Copyright (c) 2026 WasalX
require 'digest'
require 'base64'
require 'pathname'

module Wasalx
  module InstalledPackage
    def self.verify!
      root = Rails.root.to_s
      bytes = File.binread(File.join(root, 'contrib/wasalx.zpm'))
      archive = JSON.parse(bytes)
      package = Package.find_by!(name: 'wasalx')
      raise 'Native package is not installed' unless archive['name'] == package.name && archive['version'] == package.version && package.state == 'installed'
      raise 'Native package stored archive differs' unless JSON.parse(Package._get_bin(package.name, package.version)) == archive
      files = archive.fetch('files')
      raise 'Native package is empty' unless files.is_a?(Array) && !files.empty?
      seen = {}
      files.each do |entry|
        location = entry.fetch('location')
        safe = location.is_a?(String) && location.match?(/\A[A-Za-z0-9._\/-]+\z/) && !location.start_with?('/') &&
               Pathname.new(location).cleanpath.to_s == location && location.split('/').none? { |part| part.empty? || part == '..' }
        raise 'Native package file is invalid' unless safe && entry['permission'] == '644' && !seen[location]
        seen[location] = true
        path = File.join(root, location)
        cursor = root
        location.split('/').each do |part|
          cursor = File.join(cursor, part)
          raise 'Native package file is a symlink' if File.lstat(cursor).symlink?
        end
        expected = Base64.strict_decode64(entry.fetch('content'))
        raise 'Native package file differs' unless !expected.empty? && File.file?(path) && (File.lstat(path).mode & 0o7777) == 0o644 && File.binread(path) == expected
      end
      # Baked by the immutable image build, not taken from the handover request or
      # mutable pod environment. The signed image admission binds this same tree.
      source_path = '/usr/local/lib/wasalx/source-identity.json'
      details = File.lstat(source_path)
      raise 'Native source identity is writable' unless details.file? && !details.symlink? && details.uid.zero? && (details.mode & 0o222).zero?
      source = JSON.parse(File.binread(source_path))
      raise 'Native source identity is unfrozen' unless %w[commit tree].all? { |key| source[key].to_s.match?(/\A[0-9a-f]{40}\z/) }
      { 'candidate_commit_sha' => source.fetch('commit'), 'candidate_tree_sha' => source.fetch('tree'),
        'native_package_sha256' => Digest::SHA256.hexdigest(bytes), 'package_version' => package.version, 'source_files_verified' => seen.length }
    end
  end
end
