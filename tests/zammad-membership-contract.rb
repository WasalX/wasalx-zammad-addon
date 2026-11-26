# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 WasalX
require 'minitest/autorun'
require 'ostruct'
require 'json'

module Exceptions
  class NotAuthorized < StandardError; end
end
module ActiveRecord
  class ActiveRecordError < StandardError; end
  class ConnectionNotDefined < ActiveRecordError; end
  module SessionStore
    class Session
      class << self
        attr_accessor :records
        def find_by(session_id:); records[session_id]; end
      end
    end
  end
  class Base
    class << self
      attr_accessor :pool, :opened, :removed
      def connection_pool
        pool || raise(ConnectionNotDefined)
      end
      def establish_connection
        self.opened += 1
        self.pool = Object.new.tap { |value| value.define_singleton_method(:with_connection) { |&block| block.call } }
      end
      def remove_connection
        self.removed += 1
        self.pool = nil
      end
    end
  end
end
module Wasalx
  # Machine authority has its own contract suite; these membership fixtures are human-only.
  module ServiceIdentity
    def self.automation?(_user); false; end
    def self.token_allowed?(_user, _token, _purpose); false; end
  end
  class Client
    class RequestFailed < StandardError; end
    class << self
      attr_accessor :response, :calls
      def post(path, payload, scope:)
        self.calls << [path, payload, scope]
        raise response if response.is_a?(Exception)
        response
      end
    end
  end
end
class WasalxMembership
  class << self
    attr_accessor :records
    def find_by(user_id:)
      records[user_id.to_i]
    end
  end
end
package_root = ENV.fetch('WASALX_TEST_PACKAGE_ROOT', File.expand_path('../zammad-package', __dir__))
load File.join(package_root, 'lib/wasalx/session_assurance.rb')
load File.join(package_root, 'lib/wasalx/membership_access.rb')
load File.join(package_root, 'lib/wasalx/membership_projection.rb')

class User
  class << self
    attr_accessor :record, :query_error
    def find_by(id:)
      raise query_error if query_error
      record if record&.id == id
    end
  end
end
class Sessions
  class Event; end
  class << self
    attr_accessor :records
    def get(id); records[id]; end
  end
end
class SessionsController; end
# The image compatibility gate supplies actual pinned native source. No socket
# implementation is copied into the fixture or substituted with a fake sender.
if ENV['WASALX_TEST_NATIVE_ROOT']
  class WebsocketServer
    def self.cattr_reader(*names); singleton_class.attr_reader(*names); end
  end
  load File.join(ENV.fetch('WASALX_TEST_NATIVE_ROOT'), 'lib/sessions/event/base.rb')
  load File.join(ENV.fetch('WASALX_TEST_NATIVE_ROOT'), 'lib/websocket_server.rb')
  Sessions::Event::Base.prepend(Wasalx::MembershipAccess::LegacyDirectTransport)
  WebsocketServer.singleton_class.prepend(Wasalx::MembershipAccess::LegacyDirectTransport)
end
class Authorization
  class Provider
    class AccountError < StandardError; end
  end
  class << self
    attr_accessor :record, :created
    def transaction; yield; end
    def connection; self; end
    def execute(_sql); end
    def find_by(**_args); record; end
    def create_from_hash(_hash, _user = nil); self.created += 1; :legacy_created; end
  end
  singleton_class.prepend(Wasalx::MembershipAccess::OidcCreation)
end

class MembershipContractTest < Minitest::Test
  def setup
    WasalxMembership.records = {}
    Wasalx::Client.calls = []
    Wasalx::Client.response = { 'allowed' => true, 'authentication_policy' => {
      'mfa_required' => false, 'session_timeout_minutes' => 480, 'policy_version' => 1, 'subject' => 'stable-subject',
      'mfa_amr_values' => ['mfa'], 'mfa_acr_values' => [] } }
    @user = OpenStruct.new(id: 12, active: true, roles: [OpenStruct.new(name: 'Agent')])
    @membership = OpenStruct.new(portal_user_id: '30000000-0000-4000-8000-000000000003', subject: 'stable-subject', revision: 4, member_state: 'ACTIVE', portal_role: 'agent')
    User.record = @user
    User.query_error = nil
    ActiveRecord::Base.pool = nil
    ActiveRecord::Base.opened = ActiveRecord::Base.removed = 0
    Sessions.records = {}
    ActiveRecord::SessionStore::Session.records = { 'native-session' => OpenStruct.new(data: { 'user_id' => 12 }, created_at: Time.now) }
    Authorization.record = nil
    Authorization.created = 0
  end

  def test_legacy_guard_owns_only_missing_pool_and_always_cleans_it
    Sessions.records['staff'] = { user: { 'id' => 12 } }
    assert Wasalx::MembershipAccess.legacy_allowed?('staff', { 'id' => 12 })
    assert_equal [1, 1, nil], [ActiveRecord::Base.opened, ActiveRecord::Base.removed, ActiveRecord::Base.pool]
    borrowed = ActiveRecord::Base.establish_connection
    assert Wasalx::MembershipAccess.legacy_allowed?('staff')
    assert_same borrowed, ActiveRecord::Base.pool
    assert_equal 1, ActiveRecord::Base.removed
    ActiveRecord::Base.remove_connection
    User.query_error = ActiveRecord::ActiveRecordError.new('Synthetic unavailable database')
    refute Wasalx::MembershipAccess.legacy_allowed?('staff')
    assert_nil ActiveRecord::Base.pool
    assert_equal 3, ActiveRecord::Base.removed
    User.query_error = RuntimeError.new('Synthetic unexpected failure')
    assert_raises(RuntimeError) { Wasalx::MembershipAccess.legacy_allowed?('staff') }
    assert_nil ActiveRecord::Base.pool
    assert_equal 4, ActiveRecord::Base.removed
  end

  def test_legacy_public_and_removed_session_paths_do_not_open_database
    assert Wasalx::MembershipAccess.legacy_allowed?('public')
    refute Wasalx::MembershipAccess.legacy_allowed?('removed', { 'id' => 12 })
    assert_equal [0, 0], [ActiveRecord::Base.opened, ActiveRecord::Base.removed]
  end

  def test_first_login_is_fenced_by_authoritative_opt_in_even_with_zero_native_rows
    hash = { 'provider' => 'openid_connect', 'uid' => 'stable-subject' }
    Wasalx::Client.response = { 'enabled' => true, 'native_user_id' => nil }
    assert_raises(Authorization::Provider::AccountError) { Authorization.create_from_hash(hash) }
    assert_equal 0, Authorization.created
    Wasalx::Client.response = { 'enabled' => true, 'native_user_id' => '12' }
    assert_raises(Authorization::Provider::AccountError) { Authorization.create_from_hash(hash) }
    Authorization.record = OpenStruct.new(user_id: 12)
    assert_equal Authorization.record, Authorization.create_from_hash(hash)
    assert_raises(Authorization::Provider::AccountError) { Authorization.create_from_hash(hash, OpenStruct.new(id: 13)) }
    Wasalx::Client.response = Wasalx::Client::RequestFailed.new
    assert_raises(Authorization::Provider::AccountError) { Authorization.create_from_hash(hash) }
    Wasalx::Client.response = { 'enabled' => false }
    Authorization.record = nil
    assert_equal :legacy_created, Authorization.create_from_hash(hash)
    assert_equal 1, Authorization.created
  end

  def test_native_legacy_transports_deny_queued_private_delivery_after_session_storage_is_destroyed
    skip 'Native source runs in the pinned image compatibility gate' unless ENV['WASALX_TEST_NATIVE_ROOT']
    WasalxMembership.records[12] = @membership
    deliveries = []
    closes = []
    socket = Object.new
    socket.define_singleton_method(:send) { |data| deliveries << data }
    socket.define_singleton_method(:close_websocket) { closes << true }
    [Sessions::Event::Base, WebsocketServer].each do |native|
      clients = { 'staff' => { session: { 'id' => 12, Wasalx::SessionAssurance::REFERENCE => 'native-session' }, websocket: socket } }
      sender = native == WebsocketServer ? native : native.allocate
      sender.instance_variable_set(:@clients, clients)
      sender.instance_variable_set(:@options, {})
      Sessions.records['staff'] = { user: { 'id' => 12, Wasalx::SessionAssurance::REFERENCE => 'native-session' } }
      sender.websocket_send('staff', { ticket: 'allowed before removal' })
      before = deliveries.length
      Sessions.records.delete('staff')
      @membership.revision += 1 # Including a now-ready re-add must not revive the old socket.
      sender.websocket_send('staff', { ticket: 'queued before removal' })
      assert_equal before, deliveries.length
      assert_empty clients
      clients['public'] = { websocket: socket }
      sender.websocket_send('public', { event: 'protocol handshake' })
      assert_equal before + 1, deliveries.length
    end
    assert_equal [true, true], closes
  end

  def test_legacy_and_service_accounts_do_not_depend_on_membership_network_calls
    Wasalx::Client.response = Wasalx::Client::RequestFailed.new
    assert Wasalx::MembershipAccess.allowed?(@user)
    assert_empty Wasalx::Client.calls
  end

  def test_native_role_drift_is_denied_without_modifying_independent_group_grants
    WasalxMembership.records[12] = @membership
    User.record = OpenStruct.new(id: 12, active: true, roles: [OpenStruct.new(name: 'Agent'), OpenStruct.new(name: 'Admin')])
    refute Wasalx::MembershipAccess.allowed?(@user)
    User.record.roles = []
    refute Wasalx::MembershipAccess.allowed?(@user)
    assert_empty Wasalx::Client.calls
  end

  def test_managed_access_uses_immutable_portal_identity_native_id_and_current_revision
    WasalxMembership.records[12] = @membership
    assert Wasalx::MembershipAccess.allowed?(@user)
    assert_equal ['/internal/v1/zammad/membership/check', { user_id: @membership.portal_user_id, native_user_id: '12', revision: 4 }, 'zammad:membership'], Wasalx::Client.calls.last
    Wasalx::Client.response = { 'allowed' => false }
    refute Wasalx::MembershipAccess.allowed?(@user)
    Wasalx::Client.response = Wasalx::Client::RequestFailed.new
    refute Wasalx::MembershipAccess.allowed?(@user)
  end

  def test_inactive_removed_and_auditor_accounts_deny_without_network_or_stale_cache
    WasalxMembership.records[12] = @membership
    @user.active = false
    refute Wasalx::MembershipAccess.allowed?(@user)
    @user.active = true
    %w[SUSPENDED REMOVED].each do |state|
      @membership.member_state = state
      refute Wasalx::MembershipAccess.allowed?(@user)
    end
    @membership.member_state = 'ACTIVE'
    @membership.portal_role = 'auditor'
    refute Wasalx::MembershipAccess.allowed?(@user)
    assert_empty Wasalx::Client.calls
  end

  def test_http_authentication_and_modern_socket_data_are_fenced_before_native_execution
    WasalxMembership.records[12] = @membership
    Wasalx::Client.response = { 'allowed' => false }
    controller = Class.new do
      def session; OpenStruct.new(id: nil); end
      def authentication_check_prerequesits(user, auth_type)
        raise 'native authentication must not be reached'
      end
      prepend Wasalx::MembershipAccess::Authentication
    end.new
    assert_raises(Exceptions::NotAuthorized) { controller.send(:authentication_check_prerequesits, @user, 'session') }
    channel = Class.new do
      attr_accessor :current_user, :connection
      def transmit(data, **options); raise 'private data must not be transmitted'; end
      def execute(data); raise 'stale session must not execute'; end
      prepend Wasalx::MembershipAccess::CableChannel
    end.new
    closed = []
    channel.current_user = @user
    channel.connection = Object.new
    channel.connection.define_singleton_method(:wasalx_membership_revision) { 4 }
    channel.connection.define_singleton_method(:wasalx_session_reference) { 'retired-session' }
    channel.connection.define_singleton_method(:close) { |reconnect:| closed << reconnect }
    channel.execute({})
    channel.transmit({ ticket: 'private' })
    assert_equal [false, false], closed
    # The server's current projection is ready again, but the old socket retains
    # its pre-downgrade/pre-suspension UserContext and must never regain authority.
    Wasalx::Client.response = { 'allowed' => true }
    @membership.revision = 5
    channel.execute({})
    channel.transmit({ ticket: 'private' })
    @membership.revision = 7
    channel.transmit({ ticket: 'private after re-add' })
    assert_equal [false, false, false, false, false], closed
  end

  def test_identity_request_rejects_foreign_tenant_or_instance_and_invalid_provenance
    ENV['WASALX_TENANT_ID'] = '10000000-0000-4000-8000-000000000001'
    ENV['WASALX_ZAMMAD_INSTANCE_ID'] = '11000000-0000-4000-8000-000000000001'
    payload = { 'action' => 'APPLY', 'tenant_id' => ENV['WASALX_TENANT_ID'], 'instance_id' => ENV['WASALX_ZAMMAD_INSTANCE_ID'], 'user_id' => @membership.portal_user_id, 'subject' => 'stable-subject', 'email' => 'staff@example.test', 'name' => 'Staff Member', 'role' => 'agent', 'state' => 'ACTIVE', 'revision' => 4, 'native_user_id' => nil, 'adopt_user_id' => nil }
    Wasalx::MembershipProjection.validate!(payload)
    { 'tenant_id' => '20000000-0000-4000-8000-000000000002', 'instance_id' => '22000000-0000-4000-8000-000000000002', 'revision' => 0, 'subject' => "subject\n", 'email' => 'Staff@example.test', 'role' => 'admin', 'native_user_id' => '0' }.each do |key, value|
      assert_raises(ArgumentError) { Wasalx::MembershipProjection.validate!(payload.merge(key => value)) }
    end
    assert_raises(ArgumentError) { Wasalx::MembershipProjection.validate!(payload.merge('unknown' => true)) }
  end
end
