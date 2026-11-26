# SPDX-License-Identifier: AGPL-3.0-only
class Api::V1::WasalxController < ApplicationController
# Copyright (c) 2026 WasalX
  prepend_before_action :authenticate_and_authorize!

  def panel
    ticket = Ticket.find(params[:ticket_id])
    authorize!(ticket, :agent_read_access?)

    render json: Service::Ticket::WasalxPanel.execute(ticket: ticket, current_user: current_user)
  end

  def retry_delivery
    authorization_check('ticket.agent.wasalx_retry')
    ticket = Ticket.find(params[:ticket_id])
    authorize!(ticket, :agent_update_access?)

    response = Wasalx::Client.post(
      '/internal/v1/zammad/retry',
      { tenant_id: ENV.fetch('WASALX_TENANT_ID'), ticket_id: ticket.id, actor_id: current_user.id,
        article_id: params[:article_id], idempotency_key: "retry:#{ticket.id}:#{params[:article_id]}" },
      scope: 'zammad:retry'
    )
    render json: response, status: :accepted
  end
end
