# SPDX-License-Identifier: AGPL-3.0-only

class WasalxDirectTicketReadJob < ApplicationJob
  retry_on Wasalx::Client::TemporaryRequestFailed, attempts: 3, wait: ->(executions) { 2**executions } do |job, error|
    Rails.logger.warn({ event: 'wasalx.direct_ticket_read_unavailable', ticket_id: job.arguments.first,
                        error_class: error.class.name }.to_json)
  end

  def self.enqueue(ticket, actor)
    return unless direct?(ticket) && actor.active && !Wasalx::ServiceIdentity.automation?(actor)

    perform_later(ticket.id, actor.id, ticket.group_id, ticket.customer_id, ticket.wasalx_connection_id,
                  (Time.now.to_r * 1000).to_i)
  rescue StandardError => error
    Rails.logger.warn({ event: 'wasalx.direct_ticket_read_enqueue_failed', ticket_id: ticket.id,
                        error_class: error.class.name }.to_json)
  end

  def self.direct?(ticket)
    ticket.wasalx_bot_conversation.to_s == 'true' || ticket.wasalx_bot_state.present?
  end

  def perform(ticket_id, actor_id, group_id, customer_id, connection_id, opened_at)
    ticket = Ticket.find_by(id: ticket_id)
    actor = User.find_by(id: actor_id)
    return unless ticket && self.class.direct?(ticket) && ticket.group_id == group_id &&
                  ticket.customer_id == customer_id && ticket.wasalx_connection_id == connection_id
    return unless actor&.active && actor.permissions?('ticket.agent') && !Wasalx::ServiceIdentity.automation?(actor) &&
                  TicketPolicy.new(actor, ticket).agent_read_access?

    Wasalx::Client.post("/internal/v1/zammad/tickets/#{Integer(ticket.id)}/read-signal",
                        { connection_id: connection_id, group_id: group_id.to_s, customer_id: customer_id.to_s,
                          opened_at: opened_at },
                        scope: 'zammad:ticket-read', actor: Wasalx::GroupWorkspace.actor_claims(actor))
  rescue Wasalx::Client::PermanentRequestFailed => error
    Rails.logger.info({ event: 'wasalx.direct_ticket_read_refused', ticket_id: ticket_id,
                        status: error.http_status }.to_json)
  end
end
