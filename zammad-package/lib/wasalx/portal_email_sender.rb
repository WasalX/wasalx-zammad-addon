# SPDX-License-Identifier: AGPL-3.0-only
require_relative 'portal_mailbox_administration'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>

module Wasalx
  module PortalEmailSender
    Sender = Struct.new(:group, :address, :channel)

    # Resolve only the team's configured sender. Native addresses can remain
    # active when their mailbox is paused; an unrelated account is never a fallback.
    def self.resolve(group)
      current = Group.find_by(id: group.id, active: true)
      address = current && EmailAddress.find_by(id: current.email_address_id, active: true)
      channel = address && Channel.find_by(id: address.channel_id, active: true)
      Sender.new(current, address, channel) if channel && customer_account?(channel) && outbound?(channel)
    end

    def self.available?(group)
      !!(group && resolve(group))
    end

    def self.customer_account?(channel)
      Validations::ChannelEmailAccountUniquenessValidator::MATCHED_AREAS.include?(channel.area)
    end

    def self.outbound?(channel)
      options = channel.options
      outbound = options[:outbound] || options['outbound'] || {}
      adapter = outbound[:adapter] || outbound['adapter'] || options[:adapter] || options['adapter']
      return false unless adapter.is_a?(String) && !adapter.empty?
      driver = Channel.driver_class(adapter)
      # Keep SMTP/XOAUTH2, Graph and other native email outbound implementations.
      # Capability admission does not probe a transport or duplicate native delivery.
      driver < Channel::Driver::BaseEmailOutbound &&
        driver.method_defined?(:deliver) &&
        driver.instance_method(:deliver).owner != Channel::Driver::BaseEmailOutbound
    rescue NameError
      false
    end

    # Caller owns Transaction.execute. Match mailbox administration's lock order,
    # then re-read every exact binding after a delayed PAUSE/configuration wait.
    def self.lock!(group)
      raise Exceptions::Forbidden unless Channel.connection.transaction_open?
      candidate = resolve(group)
      raise Exceptions::Forbidden unless candidate
      Channel.connection.execute("SELECT pg_advisory_xact_lock(#{PortalMailboxAdministration.effect_lock_key(candidate.channel.id)})")
      channel = Channel.where(id: candidate.channel.id).lock('FOR SHARE').first
      current = Group.where(id: group.id).lock('FOR SHARE').first
      address = current && EmailAddress.where(id: current.email_address_id).lock('FOR SHARE').first
      raise Exceptions::Forbidden unless current&.active && address&.active && channel&.active &&
        customer_account?(channel) && address.id == candidate.address.id &&
        address.channel_id == channel.id && outbound?(channel)
      current.association(:email_address).target = address
      Sender.new(current, address, channel)
    end

    def self.assert_native_binding!(article, sender)
      raise Exceptions::Forbidden unless article.preferences['email_address_id'] == sender.address.id
    end
  end
end
