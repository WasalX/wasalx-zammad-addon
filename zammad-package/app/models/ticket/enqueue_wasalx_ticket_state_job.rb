# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
require 'time'

# Captures actual state transitions during their update and projects them only
# after commit. Original state/time/key survive later native contact saves; the
# committed article barrier is captured when the transaction finishes.
module Ticket::EnqueueWasalxTicketStateJob
  extend ActiveSupport::Concern

  included do
    after_update :ticket_enqueue_wasalx_ticket_state_job
  end

  private

  def ticket_enqueue_wasalx_ticket_state_job
    return true if Setting.get('import_mode')
    return true unless saved_change_to_state_id?

    state = Ticket::State.lookup(id: state_id)
    return true if state.nil?

    state_type = Ticket::StateType.lookup(id: state.state_type_id)
    return true if state_type.nil?

    customer_command_id = @wasalx_customer_close_command_id
    transition_time = updated_at.utc.iso8601(6)
    idempotency_key = "ticket-state:#{id}:#{state_id}:#{transition_time}"
    payload = {
      'tenant_id' => ENV.fetch('WASALX_TENANT_ID'),
      'ticket_id' => id,
      'ticket_number' => number.to_s,
      'state_id' => state.id,
      'state_name' => state.name.to_s,
      'state_type_name' => state_type.name.to_s,
      'transitioned_at' => transition_time,
      'idempotency_key' => idempotency_key
    }
    # A reply may save another instance of this Ticket in the same transaction.
    # Public transaction callbacks preserve this actual transition independently
    # of Active Record's final model-instance selection and discard it on rollback.
    transaction = self.class.current_transaction
    raise ArgumentError, 'WasalX ticket state requires an active transaction' unless transaction.open?

    transaction.after_commit do
      next unless self.class.exists?(id: payload['ticket_id'], state_id: payload['state_id'])

      WasalxTicketStateJob.perform_later(payload.merge(
        'pending_article_ids' => wasalx_pending_close_articles(state, state_type)
      ).merge(customer_command_id ? { 'customer_close_receipt' => wasalx_customer_close_receipt(customer_command_id, payload) } : {}))
    end
    true
  end

  def wasalx_customer_close_receipt(command_id, payload)
    article = Ticket::Article.find_by(wasalx_operation_key: "direct-customer-close:#{command_id}")
    p = article&.preferences || {}
    raise ArgumentError, 'Customer close receipt is unavailable' unless article && article.ticket_id == payload['ticket_id'] && article.internal == true &&
      Ticket::Article::Sender.lookup(id: article.sender_id)&.name == 'System' && p['wasalx_customer_close_command_id'] == command_id &&
      p['wasalx_customer_close_closed_at'] == payload['transitioned_at']
    { 'state' => 'SUCCEEDED', 'command_id' => command_id, 'ticket_id' => payload['ticket_id'].to_s, 'article_id' => article.id.to_s,
      'request_sha256' => p.fetch('wasalx_customer_close_request_sha256'), 'closed_at' => p.fetch('wasalx_customer_close_closed_at'),
      'customer_id' => p.fetch('wasalx_customer_close_customer_id'), 'human_ownership_epoch' => p.fetch('wasalx_customer_close_epoch'),
      'conversation_fencing_token' => p.fetch('wasalx_customer_close_fence') }
  end

  def wasalx_pending_close_articles(state, state_type)
    return [] unless state_type.name.to_s.downcase == 'closed' || %w[closed resolved].include?(state.name.to_s.downcase)

    # The native save creates its reply after updating the ticket, in the same
    # transaction. At transaction commit both are visible. Capture fixed IDs,
    # not a timestamp cutoff, so retries never absorb unrelated later replies.
    Ticket::Article.where(ticket_id: id, internal: false).find_each.filter_map do |article|
      next unless article.wasalx_agent_outbound?

      preferences = article.preferences || {}
      next if preferences['wasalx_imported'] == true

      delivery_id = preferences['wasalx_delivery_id'] || preferences[:wasalx_delivery_id]
      article.id if delivery_id.to_s.strip.empty?
    end
  end
end
