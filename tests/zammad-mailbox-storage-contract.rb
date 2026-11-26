# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 WasalX
require 'minitest/autorun'
require 'ostruct'
require 'json'
module ActiveRecord
  class ActiveRecordError < StandardError; end
  class RecordNotFound < ActiveRecordError; end
  class StatementInvalid < ActiveRecordError; end
  class RecordInvalid < ActiveRecordError; end
end
module Exceptions
  class Forbidden < StandardError; end
end
class Object
  def blank?; respond_to?(:empty?) ? empty? : !self; end
  def present?; !blank?; end
end
class Hash
  def deep_dup; Marshal.load(Marshal.dump(self)); end
end
class String
  def blank?; strip.empty?; end
end
module Wasalx
  module ServiceIdentity
    def self.canonical(value); value; end
  end
  module PortalDelegation
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  end
end
module StorageFixture
  class << self
    attr_accessor :rows, :receipts, :error, :depth, :rollbacks
  end
end
module Transaction
  def self.execute
    snapshot = [StorageFixture.rows.dup, StorageFixture.receipts.dup]
    StorageFixture.depth += 1
    begin
      yield
    rescue StandardError
      StorageFixture.rows, StorageFixture.receipts = snapshot
      StorageFixture.rollbacks += 1
      raise
    ensure
      StorageFixture.depth -= 1
    end
  end
end
class EmptyStorageRelation
  def where(*); self; end
  def not(*); self; end
  def any?; false; end
  def exists?; false; end
end
class Group
  def self.lock; self; end
  def self.find(*); OpenStruct.new(id: 1, active: true); end
end
class EmailAddress
  def self.where(*); EmptyStorageRelation.new; end
end
class Channel
  attr_accessor :preferences, :options, :active, :group, :updated_by_id
  def self.where(*); EmptyStorageRelation.new; end
  def self.connection
    @connection ||= Object.new.tap { |value| value.define_singleton_method(:execute) { |_sql| nil } }
  end
  def initialize(**)
    @preferences = {}
    @active = false
  end
  def assign_attributes(**values)
    values.each { |key, value| public_send("#{key}=", value) }
  end
  def save!
    raise 'storage failure must occur inside native transaction' unless StorageFixture.depth.positive?
    StorageFixture.rows << options
    raise StorageFixture.error
  end
end
class WasalxAdminOperation
  def self.find_by(operation_id:)
    StorageFixture.receipts.find { |row| row[:operation_id] == operation_id }
  end
  def self.create!(**values); StorageFixture.receipts << values; end
end
require_relative '../zammad-package/lib/wasalx/portal_mailbox_administration'
class MailboxStorageContractTest < Minitest::Test
  def setup
    StorageFixture.rows = []
    StorageFixture.receipts = []
    StorageFixture.depth = StorageFixture.rollbacks = 0
    @prior = ENV.values_at('WASALX_MAIL_ALLOWED_HOSTS', 'WASALX_SERVICE_JWT_SECRET')
    ENV['WASALX_MAIL_ALLOWED_HOSTS'] = 'mail.fixture.test'
    ENV['WASALX_SERVICE_JWT_SECRET'] = 'synthetic-storage-fixture-hmac'
    @actor = OpenStruct.new(id: 9)
    @actor.define_singleton_method(:reload) { self }
    @actor.define_singleton_method(:permissions!) { |_permission| true }
    @operation = '10000000-0000-4000-8000-000000000001'
    @envelope = { 'actor' => { 'user_id' => 'owner-fixture' }, 'operation' => 'MAILBOX_CREATE', 'input' => {
      'operation_id' => @operation,
      'config' => { 'email' => 'owned@example.test', 'name' => 'Synthetic mailbox', 'team_id' => '1',
        'inbound' => { 'host' => 'mail.fixture.test', 'port' => 993, 'user' => 'owned', 'folder' => 'INBOX', 'security' => 'TLS' },
        'outbound' => { 'host' => 'mail.fixture.test', 'port' => 587, 'user' => 'owned', 'security' => 'STARTTLS' } },
      'credentials' => { 'inbound' => 'SyntheticCredential', 'outbound' => 'SyntheticCredential' } } }
  end
  def teardown
    %w[WASALX_MAIL_ALLOWED_HOSTS WASALX_SERVICE_JWT_SECRET].zip(@prior) { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end
  def invoke(envelope = @envelope)
    Wasalx::PortalMailboxAdministration.new(actor: @actor, envelope: envelope, authorizer: -> { @actor }).call
  end
  def test_real_mutation_boundary_rolls_back_and_redacts_storage_errors_without_terminal_proof
    [ActiveRecord::StatementInvalid, ActiveRecord::RecordInvalid].each do |error_class|
      StorageFixture.error = error_class.new('SyntheticCredential in native database detail')
      error = assert_raises(Wasalx::PortalMailboxAdministration::StorageError) { invoke }
      assert_equal 'Mailbox storage unavailable', error.message
      assert_nil error.cause
      assert_equal 0, StorageFixture.depth
      assert_empty StorageFixture.rows
      assert_empty StorageFixture.receipts
      assert_operator StorageFixture.rollbacks, :>, 0
      result = invoke(@envelope.merge('operation' => 'MAILBOX_RECEIPT', 'input' => {
        'operation_id' => @operation, 'kind' => 'MAILBOX_CREATE', 'cancel_if_missing' => false }))
      assert_equal({ state: 'UNKNOWN' }, result)
      assert_empty StorageFixture.receipts
    end
  end
  def test_record_not_found_keeps_native_semantics_after_rollback
    StorageFixture.error = ActiveRecord::RecordNotFound.new('Missing native row')
    raised = assert_raises(ActiveRecord::RecordNotFound) { invoke }
    assert_same StorageFixture.error, raised
    assert_equal 0, StorageFixture.depth
    assert_equal 1, StorageFixture.rollbacks
    assert_empty StorageFixture.rows
    assert_empty StorageFixture.receipts
  end
end
