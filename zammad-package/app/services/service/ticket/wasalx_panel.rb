# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'uri'
require 'time'

# Builds the small, read-only agent panel payload. Operational state comes
# from the WasalX control plane; ticket metadata is local so an outage still
# leaves a useful, explicitly degraded panel instead of pretending a session
# is healthy.
class Service::Ticket::WasalxPanel < Service::Base
  CONNECTION_STATES = %w[
    PROVISIONING AWAITING_AUTH CONNECTING WORKING DEGRADED ACTION_REQUIRED
    FAILED PAUSED REVOKED
  ].freeze
  BINDING_STATES = %w[DRAFT ACTIVE PAUSED].freeze
  CORRELATION_STATES = %w[OPEN RESOLVED DETACHED].freeze
  DELIVERY_STATES = %w[
    QUEUED CLAIMED SENDING SENT DELIVERED READ FAILED_RETRYABLE
    FAILED_TERMINAL OUTCOME_UNKNOWN BLOCKED
  ].freeze
  BOT_STATES = %w[BOT ACTION_PENDING HANDOFF_PENDING HUMAN RESOLVED].freeze
  EMAIL_ROUTING_STATES = %w[PENDING APPLIED FAILED_TERMINAL].freeze
  EMAIL_ROUTING_ACK_STATES = %w[PENDING SUCCEEDED FAILED_TERMINAL].freeze
  PROVIDERS = %w[WAHA META].freeze
  MAX_TEXT_LENGTH = 255

  def initialize(ticket:, current_user:)
    @ticket = ticket
    @current_user = current_user
  end

  def execute
    email_routing = email_routing_context
    raise ActiveRecord::RecordNotFound, 'WasalX ticket metadata is missing' if !group_ticket? && email_routing.nil?

    context = group_ticket? ? control_context : email_control_context(email_routing)
    message_contexts = group_ticket? ? group_message_contexts : { items: [], truncated: false }
    {
      ticket: {
        id:                 ticket.id,
        number:             safe_text(ticket.number),
        reference:          optional_text(ticket.wasalx_reference),
        correlation_status: context[:correlation_state] || local_enum(ticket.wasalx_correlation_status, CORRELATION_STATES),
        rule_version:       optional_text(ticket.wasalx_rule_version),
        bot_state:          context[:bot_state] || local_enum(ticket.wasalx_bot_state, BOT_STATES)
      },
      group: {
        id:   group_ticket? ? safe_text(ticket.wasalx_group_id) : 'email-routing',
        name: group_ticket? ? optional_text(context[:group_name]) || optional_text(ticket.wasalx_group_name) || 'Managed WhatsApp group' : 'Email routing'
      },
      connection: {
        id:                     group_ticket? ? safe_text(ticket.wasalx_connection_id) : 'email-routing',
        provider:               context[:provider] || local_enum(ticket.wasalx_provider, PROVIDERS),
        state:                  context[:connection_state],
        binding_state:          context[:binding_state],
        available:              context[:available],
        last_heartbeat_at:      context[:last_heartbeat_at],
        last_provider_event_at: context[:last_provider_event_at]
      },
      delivery: {
        id:                          context[:delivery_id],
        article_id:                  context[:zammad_article_id],
        state:                       context[:delivery_state] || local_enum(ticket.wasalx_delivery_status, DELIVERY_STATES) || 'NOT_SENT',
        updated_at:                  context[:delivery_updated_at],
        retry_allowed:               context[:delivery_retry_allowed] == true,
        retry_requires_confirmation: context[:delivery_retry_requires_confirmation] == true
      },
      portal_url: administrative_portal_url,
      message_context: message_contexts[:items].first,
      trigger_sender: message_contexts[:items].first&.slice(:sender_name, :sender_phone, :from_me) || local_trigger_sender,
      message_contexts: message_contexts[:items],
      message_contexts_truncated: message_contexts[:truncated],
      email_routing: email_routing,
      can_retry: retry_permission?
    }
  end

  private

  attr_reader :ticket, :current_user

  def group_ticket?
    required = [ticket.wasalx_connection_id, ticket.wasalx_group_id]
    required.all? { |value| !value.nil? && !value.to_s.strip.empty? }
  end

  def email_routing_context
    article = ticket.articles.reverse.find do |candidate|
      (candidate.preferences || {})['wasalx_email_routing_payload'].is_a?(Hash)
    end
    return nil if article.nil?

    preferences = article.preferences || {}
    routing_state = local_enum(preferences['wasalx_email_routing_state'], EMAIL_ROUTING_STATES)
    acknowledgement_state = local_enum(preferences['wasalx_email_routing_ack_state'], EMAIL_ROUTING_ACK_STATES)
    return nil if routing_state.nil?

    {
      article_id: article.id.to_s,
      routing_state: routing_state,
      acknowledgement_state: acknowledgement_state,
      retry_allowed: retry_permission? && [routing_state, acknowledgement_state].include?('FAILED_TERMINAL'),
      updated_at: article.updated_at&.utc&.iso8601(6)
    }
  end

  def email_control_context(email_routing)
    {
      available: true, provider: nil, connection_state: email_routing[:routing_state],
      binding_state: 'UNKNOWN', correlation_state: nil, bot_state: nil,
      group_name: 'Email routing', delivery_state: email_routing[:acknowledgement_state] || email_routing[:routing_state],
      delivery_id: nil, zammad_article_id: nil, delivery_retry_allowed: false,
      delivery_retry_requires_confirmation: false, last_heartbeat_at: nil,
      last_provider_event_at: email_routing[:updated_at], delivery_updated_at: email_routing[:updated_at]
    }
  end

  def control_context
    response = Wasalx::Client.get(
      "/internal/v1/zammad/tickets/#{Integer(ticket.id)}/context",
      scope: 'zammad:context'
    )
    raise ArgumentError, 'WasalX returned a mismatched ticket context' if response.fetch('ticket_id').to_s != ticket.id.to_s
    raise ArgumentError, 'WasalX returned a mismatched connection context' if response.fetch('connection_id').to_s != ticket.wasalx_connection_id.to_s

    {
      available:               true,
      provider:                required_enum(response, 'provider', PROVIDERS),
      connection_state:        required_enum(response, 'connection_state', CONNECTION_STATES),
      binding_state:           required_enum(response, 'binding_state', BINDING_STATES),
      correlation_state:       required_enum(response, 'correlation_state', CORRELATION_STATES),
      bot_state:               optional_enum(response['bot_state'], BOT_STATES),
      group_name:              optional_text(response['group_name']),
      delivery_state:          optional_enum(response['delivery_state'], DELIVERY_STATES),
      delivery_id:             optional_uuid(response['delivery_id']),
      zammad_article_id:       optional_identifier(response['zammad_article_id']),
      delivery_retry_allowed:  response['delivery_retry_allowed'] == true,
      delivery_retry_requires_confirmation: response['delivery_retry_requires_confirmation'] == true,
      last_heartbeat_at:       optional_timestamp(response['last_heartbeat_at']),
      last_provider_event_at:  optional_timestamp(response['last_provider_event_at']),
      delivery_updated_at:     optional_timestamp(response['delivery_updated_at'])
    }
  rescue Wasalx::Client::RequestFailed, KeyError, NoMethodError, TypeError, ArgumentError
    {
      available: false, provider: nil, connection_state: 'UNAVAILABLE', binding_state: 'UNKNOWN',
      correlation_state: nil, bot_state: nil, group_name: nil, delivery_state: nil, delivery_id: nil,
      zammad_article_id: nil, delivery_retry_allowed: false,
      delivery_retry_requires_confirmation: false, last_heartbeat_at: nil,
      last_provider_event_at: nil, delivery_updated_at: nil
    }
  end

  def group_message_contexts
    response = Wasalx::Client.get(
      "/internal/v1/zammad/group-workspace/tickets/#{Integer(ticket.id)}/message-context",
      scope: 'zammad:groups', actor: group_actor
    )
    values = response['items'].is_a?(Array) ? response.fetch('items').first(100) : [response]
    items = values.map do |value|
      group_id = optional_uuid(value.fetch('group_id'))
      message_id = optional_uuid(value.fetch('message_id'))
      raise ArgumentError, 'WasalX returned an invalid message context' if group_id.nil? || message_id.nil?

      {
        group_id: group_id, message_id: message_id,
        sender_name: optional_text(value['sender_name']),
        sender_phone: optional_phone(value['sender_phone']),
        from_me: value['from_me'] == true
      }
    end
    raise ArgumentError, 'WasalX returned an invalid message context' if items.empty?

    { items: items, truncated: response['truncated'] == true }
  rescue Wasalx::Client::RequestFailed, KeyError, NoMethodError, TypeError, ArgumentError
    { items: [], truncated: false }
  end

  def required_enum(response, key, allowed)
    value = response.fetch(key).to_s
    raise ArgumentError, "WasalX response #{key} is invalid" if !allowed.include?(value)

    value
  end

  def optional_enum(value, allowed)
    return nil if value.nil? || value.to_s.empty?

    text = value.to_s
    raise ArgumentError, 'WasalX response state is invalid' if !allowed.include?(text)

    text
  end

  def local_enum(value, allowed)
    return nil if value.nil? || value.to_s.empty?

    text = value.to_s
    allowed.include?(text) ? text : nil
  end

  def optional_timestamp(value)
    return nil if value.nil? || value.to_s.empty?

    Time.iso8601(value.to_s).utc.iso8601(6)
  end

  def optional_uuid(value)
    return nil if value.nil? || value.to_s.empty?

    text = value.to_s
    raise ArgumentError, 'WasalX response delivery ID is invalid' if !text.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i)

    text
  end

  def optional_identifier(value)
    return nil if value.nil? || value.to_s.empty?

    text = value.to_s
    raise ArgumentError, 'WasalX response article ID is invalid' if !text.match?(/\A[1-9][0-9]{0,15}\z/)

    text
  end

  def local_trigger_sender
    article = ticket.articles.reverse.find do |candidate|
      preferences = candidate.preferences || {}
      provider_origin = (preferences['wasalx_origin'] || preferences[:wasalx_origin]).to_s == 'provider'
      identity_present = (preferences['wasalx_sender_name'] || preferences[:wasalx_sender_name] ||
        preferences['wasalx_sender_phone'] || preferences[:wasalx_sender_phone]).present?
      provider_origin && identity_present && candidate.origin_by_id.present?
    end
    return nil if article.nil?

    preferences = article.preferences || {}
    name = optional_text(preferences['wasalx_sender_name'] || preferences[:wasalx_sender_name])
    phone = optional_phone(preferences['wasalx_sender_phone'] || preferences[:wasalx_sender_phone])
    return nil if name.nil? && phone.nil?

    { sender_name: name, sender_phone: phone, from_me: false }
  rescue ArgumentError
    nil
  end

  def optional_phone(value)
    return nil if value.nil? || value.to_s.empty?

    text = value.to_s
    raise ArgumentError, 'WasalX response sender phone is invalid' if !text.match?(/\A\+[1-9][0-9]{5,14}\z/)

    text
  end

  def safe_text(value)
    text = optional_text(value)
    raise ArgumentError, 'WasalX ticket text is missing' if text.nil?

    text
  end

  def optional_text(value)
    return nil if value.nil?

    text = value.to_s
    text = text.unicode_normalize(:nfc) if text.respond_to?(:unicode_normalize)
    text = text.gsub(/[[:cntrl:]\u200B-\u200F\u202A-\u202E\u2060-\u206F]/, ' ').gsub(/\s+/, ' ').strip
    return nil if text.empty?

    text[0, MAX_TEXT_LENGTH]
  end

  def retry_permission?
    current_user.permissions?('ticket.agent.wasalx_retry') || current_user.permissions?('admin')
  end

  def group_actor
    {
      user_id: current_user.id,
      group_ids: current_user.group_ids_access('read'),
      group_admin: current_user.permissions?('admin')
    }
  end

  def administrative_portal_url
    return nil if !retry_permission?

    value = ENV['WASALX_PORTAL_URL']
    return nil if value.nil? || value.strip.empty?

    uri = URI.parse(value)
    return nil if !uri.is_a?(URI::HTTPS) || uri.host.nil? || uri.userinfo

    uri.fragment = nil
    uri.query = URI.encode_www_form(view: 'cases', ticket: ticket.number.to_s)
    uri.to_s
  rescue URI::InvalidURIError
    nil
  end
end
