# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 WasalX
require 'minitest/autorun'
require 'ostruct'
require_relative '../zammad-package/lib/wasalx/portal_email_sender'

module Exceptions
  class Forbidden < StandardError; end
end

module Validations
  class ChannelEmailAccountUniquenessValidator
    MATCHED_AREAS = %w[Email::Account Google::Account Microsoft365::Account MicrosoftGraph::Account].freeze
  end
end

class Group
  class << self
    attr_accessor :rows
    def find_by(**criteria); rows.find { |row| criteria.all? { |key,value| row.public_send(key) == value } }; end
    def where(**criteria); SenderRelation.new(rows.select { |row| criteria.all? { |key,value| row.public_send(key) == value } }); end
  end
end
class EmailAddress < Group; end
class Channel < Group
  module Driver
    class BaseEmailOutbound
      def deliver(*); raise 'must never deliver in capability check'; end
    end
    class Smtp < BaseEmailOutbound
      def deliver(*); raise 'must never deliver'; end
    end
    class MicrosoftGraphOutbound < BaseEmailOutbound
      def deliver(*); raise 'must never deliver'; end
    end
    class Null; end
  end
  class << self
    attr_accessor :connection
    def driver_class(adapter); Driver.const_get(adapter); end
  end
end
class SenderRelation
  def initialize(rows); @rows=rows; end
  def lock(mode); raise unless mode == 'FOR SHARE'; self; end
  def first; @rows.first; end
end
class PortalEmailSenderContractTest < Minitest::Test
  def setup
    @group = OpenStruct.new(id: 1, active: true, email_address_id: 10)
    @group.define_singleton_method(:association) { |_name| @association ||= OpenStruct.new }
    @address = OpenStruct.new(id: 10, active: true, channel_id: 20)
    @channel = OpenStruct.new(id: 20, active: true, area: 'Email::Account',
      options: { outbound: { adapter: 'Smtp', options: { authentication: 'xoauth2' } } })
    Group.rows = [@group]
    EmailAddress.rows = [@address]
    Channel.rows = [@channel]
    @connection = OpenStruct.new(transaction_open?: true)
    @connection.define_singleton_method(:execute) { |sql| raise unless sql.match?(/\ASELECT pg_advisory_xact_lock\([0-9]+\)\z/); @on_lock&.call }
    @connection.define_singleton_method(:on_lock=) { |block| @on_lock=block }
    Channel.connection = @connection
  end

  def test_exact_configured_active_sender_is_required_without_fallback
    assert Wasalx::PortalEmailSender.available?(@group)
    assert Wasalx::PortalEmailSender.available?(OpenStruct.new(id: 1, email_address_id: 999))
    fallback = OpenStruct.new(id: 21, active: true, area: 'Email::Account', options: @channel.options)
    Channel.rows << fallback
    @channel.active = false
    refute Wasalx::PortalEmailSender.available?(@group)
    assert_raises(Exceptions::Forbidden) { Wasalx::PortalEmailSender.lock!(@group) }
    @channel.active = true
    @address.channel_id = nil
    refute Wasalx::PortalEmailSender.available?(@group)
    @address.channel_id = 20
    @address.active = false
    refute Wasalx::PortalEmailSender.available?(@group)
    @address.active = true
    @group.email_address_id = nil
    refute Wasalx::PortalEmailSender.available?(@group)
    @group.email_address_id = 10
    @group.active = false
    refute Wasalx::PortalEmailSender.available?(@group)
    @group.active = true
    @channel.area = 'Email::Notification'
    refute Wasalx::PortalEmailSender.available?(@group)
  end

  def test_native_oauth_smtp_and_graph_are_allowed_without_transport_probes
    assert Wasalx::PortalEmailSender.available?(@group)
    %w[Google::Account Microsoft365::Account].each do |area|
      @channel.area = area
      assert Wasalx::PortalEmailSender.available?(@group)
      assert_equal @address.id, Wasalx::PortalEmailSender.lock!(@group).address.id
    end
    @channel.area = 'MicrosoftGraph::Account'
    @channel.options = { 'outbound' => { 'adapter' => 'MicrosoftGraphOutbound' }, 'auth' => { 'type' => 'Microsoft365' } }
    assert Wasalx::PortalEmailSender.available?(@group)
    assert_equal @address.id, Wasalx::PortalEmailSender.lock!(@group).address.id
    @channel.area = 'Email::Account'
    @channel.options = { adapter: 'Smtp' }
    assert Wasalx::PortalEmailSender.available?(@group)
    %w[Null BaseEmailOutbound NotInstalled].each do |adapter|
      @channel.options = { outbound: { adapter: adapter } }
      refute Wasalx::PortalEmailSender.available?(@group)
    end
  end

  def test_paused_while_waiting_and_sender_replacement_fail_closed
    @connection.on_lock = -> { @channel.active = false }
    assert_raises(Exceptions::Forbidden) { Wasalx::PortalEmailSender.lock!(@group) }
    @channel.active = true
    replacement = OpenStruct.new(id: 11, active: true, channel_id: 20)
    EmailAddress.rows << replacement
    @connection.on_lock = -> { @group.email_address_id = 11 }
    assert_raises(Exceptions::Forbidden) { Wasalx::PortalEmailSender.lock!(@group) }
  end

  def test_active_exact_sender_is_pinned_and_native_metadata_is_checked
    sender = Wasalx::PortalEmailSender.lock!(@group)
    assert_same @address, sender.address
    assert_same @address, sender.group.association(:email_address).target
    Wasalx::PortalEmailSender.assert_native_binding!(OpenStruct.new(preferences: { 'email_address_id' => 10 }), sender)
    assert_raises(Exceptions::Forbidden) do
      Wasalx::PortalEmailSender.assert_native_binding!(OpenStruct.new(preferences: { 'email_address_id' => 11 }), sender)
    end
    @connection.define_singleton_method(:transaction_open?) { false }
    assert_raises(Exceptions::Forbidden) { Wasalx::PortalEmailSender.lock!(@group) }
  end

end
