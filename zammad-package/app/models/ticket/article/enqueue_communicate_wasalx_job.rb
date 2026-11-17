# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
# Schedules WasalX communication only for a committed, public article that an
# agent deliberately created with the WasalX article type. Inbound customer
# articles, system articles, notes, and imports are deliberately non-communicative.
module Ticket::Article::EnqueueCommunicateWasalxJob
  extend ActiveSupport::Concern

  included do
    before_create :ticket_article_preflight_wasalx_outbound
    after_create_commit :ticket_article_enqueue_communicate_wasalx_job
    after_create :ticket_article_enqueue_wasalx_routing_job
  end

  # Shared with native ticket closure: only articles that can enqueue an
  # outbound job may delay closure until their durable admission is recorded.
  def wasalx_agent_outbound?
    return false if internal != false || wasalx_provider_origin?

    sender = sender_id && Ticket::Article::Sender.lookup(id: sender_id)
    type = type_id && Ticket::Article::Type.lookup(id: type_id)
    sender&.name == 'Agent' && type&.name == 'wasalx group message'
  end

  private

  def ticket_article_preflight_wasalx_outbound
    # Imports deliberately have no outbound job. Preserve that distinction for
    # later ticket closure; no create can supply its own exemption, including a
    # note that is subsequently reclassified as a communicative article.
    (preferences || {}).delete(:wasalx_native_reply_intent_id)
    (preferences || {}).delete('wasalx_native_reply_intent_id')
    (preferences || {}).delete(:wasalx_imported)
    (preferences || {}).delete('wasalx_imported')
    return true unless wasalx_agent_outbound?

    if Setting.get('import_mode')
      self.preferences ||= {}
      preferences['wasalx_imported'] = true
      return true
    end

    ticket = Ticket.find(ticket_id)
    user = created_by
    raise ArgumentError, 'Agent identity is missing' if user.nil?
    query = URI.encode_www_form(connection_id: ticket.wasalx_connection_id, group_id: ticket.wasalx_group_id, ticket_id: ticket.id)
    # This nested lock joins the actual article transaction; it remains held
    # through commit/rollback even for a standalone ticket-article create.
    ticket.with_lock do
      available = Wasalx::Client.get(
        "/internal/v1/zammad/outbound/preflight?#{query}", scope: 'zammad:outbound',
        actor: { user_id: created_by_id, group_ids: user.group_ids_access('read'), group_admin: user.permissions?('admin') }
      )
      if available['keep_open'] == true
        raise ArgumentError, 'Agent access unavailable' unless user.active && user.permissions?('ticket.agent') &&
          user.group_ids_access('full').map(&:to_s).include?(ticket.group_id.to_s)
        operation_id = SecureRandom.uuid
        request_sha256 = Digest::SHA256.hexdigest(JSON.generate([ENV.fetch('WASALX_TENANT_ID'), ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'), ticket.id, user.id, operation_id]))
        admitted = Wasalx::Client.post('/internal/v1/zammad/outbound/native-intent',
          { operation_id: operation_id, connection_id: ticket.wasalx_connection_id, chat_id: ticket.wasalx_group_id,
            ticket_id: ticket.id, native_group_id: ticket.group_id, request_sha256: request_sha256 }, scope: 'zammad:outbound',
          actor: { user_id: created_by_id, group_ids: user.group_ids_access('full'), group_admin: false })
        raise ArgumentError, 'Reply admission mismatch' unless admitted['id'] == operation_id && admitted['human_ownership_epoch'].is_a?(Integer)
        self.preferences ||= {}
        preferences['wasalx_native_reply_intent_id'] = operation_id
      end
    end
    true
  rescue Wasalx::Client::RequestFailed, KeyError, TypeError, ArgumentError, NoMethodError
    errors.add(:base, __('WhatsApp access or availability could not be verified. Refresh the ticket and try again.'))
    raise ActiveRecord::RecordInvalid.new(self)
  end

  def ticket_article_enqueue_communicate_wasalx_job
    return true if Setting.get('import_mode') || !wasalx_agent_outbound?

    CommunicateWasalxJob.perform_later(id)
  end

  def wasalx_provider_origin?
    origin = (preferences || {})['wasalx_origin'] || (preferences || {})[:wasalx_origin]
    origin == 'provider' || subject == 'Sent from WhatsApp device'
  end

  def ticket_article_enqueue_wasalx_routing_job
    return true if Setting.get('import_mode') || internal != false || !sender_id || !type_id
    return true unless application_handle_info_postmaster == true
    return true if (preferences || {})['is-auto-response'] == true || (preferences || {})[:'is-auto-response'] == true

    sender = Ticket::Article::Sender.lookup(id: sender_id)
    type = Ticket::Article::Type.lookup(id: type_id)
    return true if sender.nil? || sender.name != 'Customer' || type.nil? || type.name != 'email'

    ticket = Ticket.find(ticket_id)
    email = begin
      Mail::Address.new(self.from.to_s).address.to_s.strip.downcase
    rescue StandardError
      nil
    end
    return true if email.nil? || email.empty? || email.length > 320 || email.match?(/[\x00-\x1f\x7f]/)

    ticket.with_lock do
      if !ticket.wasalx_client_route_status.present?
        revision = ticket.wasalx_assignment_revision.to_i
        payload = {
          'tenant_id' => ENV.fetch('WASALX_TENANT_ID'),
          'instance_id' => ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'),
          'ticket_id' => ticket.id,
          'article_id' => id,
          'ticket_number' => ticket.number.to_s,
          'sender_email' => email,
          'admitted_at' => created_at.utc.iso8601(6),
          'expected_group_id' => ticket.group_id,
          'entry_group_id' => ticket.group_id,
          'expected_owner_id' => ticket.owner_id,
          'expected_assignment_revision' => revision
        }
        routing_preferences = (preferences || {}).deep_dup
        routing_preferences['wasalx_email_routing_payload'] = payload
        routing_preferences['wasalx_email_routing_state'] = 'PENDING'
        routing_preferences.delete('wasalx_email_routing_error_code')
        update!(preferences: routing_preferences)
        ticket.update!(wasalx_client_route_status: 'PENDING')
        WasalxTicketRoutingJob.perform_later(payload)
      end
    end
    true
  end
end
