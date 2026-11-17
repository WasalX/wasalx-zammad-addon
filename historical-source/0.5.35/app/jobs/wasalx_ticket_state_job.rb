# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
class WasalxTicketStateJob < ApplicationJob
  retry_on Wasalx::Client::TemporaryRequestFailed, attempts: 8, wait: lambda { |executions|
    [executions * executions * 30.seconds, 15.minutes].min
  }

  def perform(payload)
    normalized = payload.to_h.transform_keys(&:to_sym)
    Wasalx::Client.post(
      '/internal/v1/zammad/ticket-state',
      normalized,
      scope: 'zammad:ticket-state'
    )
  end
end
