# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
class WasalxTicketRoutingJob < ApplicationJob
  retry_on Wasalx::Client::TemporaryRequestFailed, attempts: 8, wait: lambda { |executions|
    [executions * executions * 30.seconds, 15.minutes].min
  }

  def perform(payload)
    input = payload.to_h.transform_keys(&:to_sym)
    result = Wasalx::Client.post(
      '/internal/v1/zammad/routing',
      input.slice(:tenant_id, :instance_id, :ticket_id, :ticket_number, :sender_email),
      scope: 'zammad:routing'
    )
    raise Wasalx::Client::TemporaryRequestFailed, 'WasalX returned another ticket' if result['ticket_id'].to_s != input.fetch(:ticket_id).to_s

    ticket = Ticket.find(input.fetch(:ticket_id))
    ticket.with_lock do
      return if ticket.wasalx_client_route_status.present?

      status = result.fetch('status').to_s
      raise Wasalx::Client::PermanentRequestFailed, 'Routing status is invalid' if !%w[MATCHED FALLBACK UNCONFIGURED].include?(status)
      attributes = {
        wasalx_client_routing_version_id: result['routing_version_id'].to_s.presence,
        wasalx_client_id: result['client_id'].to_s.presence,
        wasalx_client_route_status: status,
        wasalx_client_route_matched_by: result['matched_by'].to_s.presence
      }
      if result['routed'] == true
        group_id = positive_id(result.fetch('zammad_group_id'), 'Zammad group')
        owner_id = result['owner_id'].nil? ? nil : positive_id(result['owner_id'], 'Zammad owner')
        expected = [input.fetch(:expected_group_id).to_i, input.fetch(:expected_owner_id).to_i]
        current = [ticket.group_id.to_i, ticket.owner_id.to_i]
        target = [group_id, owner_id.to_i]
        if current == expected || current == target
          attributes[:group_id] = group_id
          attributes[:owner_id] = owner_id if owner_id
        else
          attributes[:wasalx_client_route_status] = 'MANUAL_OVERRIDE'
        end
      end
      ticket.update!(attributes)
    end
  end

  private

  def positive_id(value, label)
    number = Integer(value, 10)
    raise Wasalx::Client::PermanentRequestFailed, "#{label} is invalid" if number <= 0

    number
  rescue ArgumentError, TypeError
    raise Wasalx::Client::PermanentRequestFailed, "#{label} is invalid"
  end
end
