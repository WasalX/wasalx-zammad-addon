# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'time'

# Projects committed Zammad state transitions back to WasalX without modifying
# Zammad's Ticket model. The job payload is captured at commit time so retries
# cannot accidentally report a newer state after the ticket changes again.
module Ticket::EnqueueWasalxTicketStateJob
  extend ActiveSupport::Concern

  included do
    after_update_commit :ticket_enqueue_wasalx_ticket_state_job
  end

  private

  def ticket_enqueue_wasalx_ticket_state_job
    return true if Setting.get('import_mode')
    return true if !previous_changes.key?('state_id')

    state = Ticket::State.lookup(id: state_id)
    return true if state.nil?

    state_type = Ticket::StateType.lookup(id: state.state_type_id)
    return true if state_type.nil?

    transition_time = updated_at.utc.iso8601(6)
    idempotency_key = "ticket-state:#{id}:#{state_id}:#{transition_time}"
    WasalxTicketStateJob.perform_later(
      'tenant_id' => ENV.fetch('WASALX_TENANT_ID'),
      'ticket_id' => id,
      'ticket_number' => number.to_s,
      'state_id' => state.id,
      'state_name' => state.name.to_s,
      'state_type_name' => state_type.name.to_s,
      'transitioned_at' => transition_time,
      'idempotency_key' => idempotency_key
    )
    true
  end
end
