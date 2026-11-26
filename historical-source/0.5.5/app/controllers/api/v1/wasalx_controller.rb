# SPDX-License-Identifier: AGPL-3.0-only
class Api::V1::WasalxController < ApplicationController
# Copyright (c) 2026 WasalX
  # Authenticate the caller here, then authorize the concrete ticket in each
  # action below. `authenticate_and_authorize!` also asks Pundit for a
  # controller policy; package controllers do not own one and that would turn
  # an otherwise authorized agent request into a 500 before ticket checks run.
  prepend_before_action :authentication_check

  def panel
    ticket = Ticket.find(params[:ticket_id])
    authorize!(ticket, :agent_read_access?)

    render json: Service::Ticket::WasalxPanel.execute(ticket: ticket, current_user: current_user)
  end

  def retry_delivery
    allowed = current_user.permissions?('ticket.agent.wasalx_retry') || current_user.permissions?('admin')
    raise Exceptions::Forbidden, __('Not authorized') if !allowed

    ticket = Ticket.find(params[:ticket_id])
    authorize!(ticket, :agent_update_access?)
    article_id = positive_identifier!(params[:article_id], 'article')
    delivery_id = uuid!(params[:delivery_id], 'delivery')
    request_token = uuid!(params[:request_token], 'retry request')

    response = Wasalx::Client.post(
      '/internal/v1/zammad/retry',
      { tenant_id: ENV.fetch('WASALX_TENANT_ID'), instance_id: ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'),
        ticket_id: ticket.id, actor_id: current_user.id, article_id: article_id,
        delivery_id: delivery_id, confirm_outcome_unknown: params[:confirm_outcome_unknown] == true,
        idempotency_key: "retry:#{ticket.id}:#{article_id}:#{delivery_id}:#{request_token}" },
      scope: 'zammad:retry'
    )
    render json: response, status: :accepted
  end

  private

  def positive_identifier!(value, label)
    text = value.to_s
    raise ActionController::BadRequest, __("Invalid #{label} identifier") if !text.match?(/\A[1-9][0-9]{0,15}\z/)

    text
  end

  def uuid!(value, label)
    text = value.to_s
    pattern = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    raise ActionController::BadRequest, __("Invalid #{label} identifier") if !text.match?(pattern)

    text
  end
end
