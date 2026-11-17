# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
# Schedules WasalX communication only for a committed, public article that an
# agent deliberately created with the WasalX article type. Inbound customer
# articles, system articles, notes, and imports are deliberately non-communicative.
module Ticket::Article::EnqueueCommunicateWasalxJob
  extend ActiveSupport::Concern

  included do
    after_create_commit :ticket_article_enqueue_communicate_wasalx_job
    after_create_commit :ticket_article_enqueue_wasalx_routing_job
  end

  private

  def ticket_article_enqueue_communicate_wasalx_job
    return true if Setting.get('import_mode')
    return true if internal != false
    return true if !sender_id || !type_id
    return true if wasalx_provider_origin?

    sender = Ticket::Article::Sender.lookup(id: sender_id)
    return true if sender.nil? || sender.name != 'Agent'

    type = Ticket::Article::Type.lookup(id: type_id)
    return true if type.nil? || type.name != 'wasalx group message'

    CommunicateWasalxJob.perform_later(id)
  end

  def wasalx_provider_origin?
    origin = (preferences || {})['wasalx_origin'] || (preferences || {})[:wasalx_origin]
    origin == 'provider' || subject == 'Sent from WhatsApp device'
  end

  def ticket_article_enqueue_wasalx_routing_job
    return true if Setting.get('import_mode') || internal != false || !sender_id || !type_id
    # Client routing belongs only to native inbound email processing. Zammad
    # preserves this postmaster context for after-commit callbacks and marks
    # bounces/automatic replies in the article preferences.
    return true if application_handle_info_postmaster != true
    return true if (preferences || {})['is-auto-response'] == true || (preferences || {})[:'is-auto-response'] == true

    sender = Ticket::Article::Sender.lookup(id: sender_id)
    type = Ticket::Article::Type.lookup(id: type_id)
    return true if sender.nil? || sender.name != 'Customer' || type.nil? || type.name != 'email'

    ticket = Ticket.find(ticket_id)
    return true if ticket.wasalx_client_route_status.present?

    email = begin
      Mail::Address.new(self.from.to_s).address.to_s.strip.downcase
    rescue StandardError
      nil
    end
    return true if email.nil? || email.empty? || email.length > 320 || email.match?(/[\x00-\x1f\x7f]/)

    WasalxTicketRoutingJob.perform_later(
      'tenant_id' => ENV.fetch('WASALX_TENANT_ID'),
      'instance_id' => ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'),
      'ticket_id' => ticket.id,
      'ticket_number' => ticket.number.to_s,
      'sender_email' => email,
      'expected_group_id' => ticket.group_id,
      'expected_owner_id' => ticket.owner_id
    )
    true
  end
end
