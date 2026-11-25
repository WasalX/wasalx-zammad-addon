# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
class WasalxTicketStateJob < ApplicationJob
  retry_on Wasalx::Client::TemporaryRequestFailed, attempts: 8, wait: lambda { |executions|
    [executions * executions * 30.seconds, 15.minutes].min
  }

  def perform(payload)
    normalized = payload.to_h.transform_keys(&:to_sym)
    # This native-only barrier is excluded from the stable API fingerprint.
    # Waiting never sends a message or changes the original close timestamp.
    Array(normalized.delete(:pending_article_ids)).each do |article_id|
      article = Ticket::Article.find_by(id: article_id)
      preferences = article&.preferences || {}
      delivery_id = preferences['wasalx_delivery_id'] || preferences[:wasalx_delivery_id]
      unless article && article.ticket_id.to_s == normalized[:ticket_id].to_s &&
             article.wasalx_agent_outbound? && !delivery_id.to_s.strip.empty?
        raise Wasalx::Client::TemporaryRequestFailed, 'WasalX reply admission is pending'
      end
    end
    response = Wasalx::Client.post(
      '/internal/v1/zammad/ticket-state',
      normalized,
      scope: 'zammad:ticket-state'
    )
    if response['state'] == 'BLOCKED_EFFECTS'
      raise Wasalx::Client::TemporaryRequestFailed, 'WasalX ticket closure is waiting for delivery settlement'
    end
    response
  end
end
