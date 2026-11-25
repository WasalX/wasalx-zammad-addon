# SPDX-License-Identifier: AGPL-3.0-only

module Taskbar::EnqueueWasalxDirectTicketReadJob
  def self.included(base)
    # shortcut: reopens that reuse a presence entry need a native navigation hook.
    base.after_create_commit :enqueue_wasalx_direct_ticket_read
  end

  private

  def enqueue_wasalx_direct_ticket_read
    # Native mobile creates a presence entry on open and updates it on editing.
    return unless app == 'mobile' && callback == 'TicketDetailView' && state[:editing] == false

    ticket_id = params[:ticket_id]
    return unless ticket_id.is_a?(Integer) && key == "Ticket-#{ticket_id}"

    actor = user
    return unless actor&.active && actor.permissions?('ticket.agent')

    ticket = Ticket.find_by(id: ticket_id)
    return unless ticket && TicketPolicy.new(actor, ticket).agent_read_access?

    WasalxDirectTicketReadJob.enqueue(ticket, actor)
  rescue StandardError => error
    Rails.logger.warn({ event: 'wasalx.mobile_ticket_read_enqueue_failed', taskbar_id: id,
                        error_class: error.class.name }.to_json)
  end
end
