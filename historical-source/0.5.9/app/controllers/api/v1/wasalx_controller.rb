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

  def group_workspace_groups
    ensure_group_agent!
    render json: Wasalx::Client.get('/internal/v1/zammad/group-workspace/groups', scope: 'zammad:groups', actor: group_actor)
  end

  def group_workspace_messages
    ensure_group_agent!
    group_id = uuid!(params[:group_id], 'group')
    limit = bounded_limit!(params[:limit])
    before = params[:before].present? ? uuid!(params[:before], 'message cursor') : nil
    query = { limit: limit, before: before }.compact.to_query
    render json: Wasalx::Client.get("/internal/v1/zammad/group-workspace/groups/#{group_id}/messages?#{query}", scope: 'zammad:groups', actor: group_actor)
  end

  def group_workspace_context
    ensure_group_agent!
    group_id = uuid!(params[:group_id], 'group')
    message_id = uuid!(params[:message_id], 'message')
    render json: Wasalx::Client.get("/internal/v1/zammad/group-workspace/groups/#{group_id}/messages/#{message_id}/context", scope: 'zammad:groups', actor: group_actor)
  end

  def group_workspace_tickets
    ensure_group_agent!
    group_id = uuid!(params[:group_id], 'group')
    candidates = Wasalx::Client.get("/internal/v1/zammad/group-workspace/groups/#{group_id}/tickets", scope: 'zammad:groups', actor: group_actor)
    visible = candidates.filter_map do |candidate|
      ticket_id = positive_identifier!(candidate['ticket_id'], 'ticket')
      ticket = Ticket.find_by(id: ticket_id)
      candidate if ticket && TicketPolicy.new(current_user, ticket).agent_read_access?
    end
    render json: visible
  end

  def group_workspace_read
    ensure_group_agent!
    group_id = uuid!(params[:group_id], 'group')
    message_id = uuid!(params[:message_id], 'message')
    render json: Wasalx::Client.post(
      "/internal/v1/zammad/group-workspace/groups/#{group_id}/read",
      { messageId: message_id }, scope: 'zammad:groups', actor: group_actor
    )
  end

  def group_workspace_send
    ensure_group_agent!
    group_id = uuid!(params[:group_id], 'group')
    request_token = uuid!(params[:request_token], 'send request')
    reply_to_message_id = params[:reply_to_message_id].present? ? uuid!(params[:reply_to_message_id], 'quoted message') : nil
    message = params[:message].to_s.gsub(/\r\n?/, "\n").strip
    raise ActionController::BadRequest, __('Invalid message') if message.empty? || message.each_char.count > 4096 || message.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)

    render json: Wasalx::Client.post(
      "/internal/v1/zammad/group-workspace/groups/#{group_id}/send",
      { message: message, replyToMessageId: reply_to_message_id, agentDisplayName: current_user.fullname,
        idempotency_key: "group-workspace:#{current_user.id}:#{request_token}" },
      scope: 'zammad:groups', actor: group_actor
    ), status: :accepted
  end

  private

  def ensure_group_agent!
    raise Exceptions::Forbidden, __('Not authorized') if !current_user.permissions?('ticket.agent')
  end

  def group_actor
    {
      user_id: current_user.id,
      group_ids: current_user.group_ids_access('read'),
      group_admin: current_user.permissions?('admin') || current_user.permissions?('ticket.agent.wasalx_groups_admin')
    }
  end

  def bounded_limit!(value)
    return 50 if value.blank?

    limit = Integer(value, exception: false)
    raise ActionController::BadRequest, __('Invalid message limit') if !limit || limit < 1 || limit > 100

    limit
  end

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
