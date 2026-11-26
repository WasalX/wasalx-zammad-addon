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
    grouped = candidates.group_by { |candidate| positive_identifier!(candidate['ticket_id'], 'ticket') }
    visible = grouped.filter_map do |ticket_id, links|
      ticket = Ticket.find_by(id: ticket_id)
      next if !ticket || !Ticket::State.by_category(:open).where(id: ticket.state_id).exists?
      next if !TicketPolicy.new(current_user, ticket).agent_read_access?

      {
        ticket_id: ticket.id.to_s, ticket_number: ticket.number.to_s, reference: ticket.title.to_s,
        links: links.filter_map do |link|
          next if link['message_id'].blank?

          { message_id: uuid!(link['message_id'], 'linked message'),
            article_id: link['article_id'].present? ? positive_identifier!(link['article_id'], 'linked article') : nil }
        end.uniq
      }
    end
    render json: visible
  end

  def group_workspace_ticket_groups
    ensure_group_agent!
    groups = Group.where(id: current_user.group_ids_access('create'), active: true).order(:name)
    render json: groups.map { |group| { id: group.id.to_s, name: group.name.to_s } }
  end

  def group_workspace_create_ticket
    ensure_group_agent!
    group_id = uuid!(params[:group_id], 'group')
    message_id = uuid!(params[:message_id], 'message')
    target_group_id = positive_identifier!(params[:target_group_id], 'ticket group')
    uuid!(params[:request_token], 'ticket request')
    existing = Ticket::Article.find_by(wasalx_operation_key: operation_key('create', message_id))
    if existing
      authorize!(existing.ticket, :agent_read_access?)
      link_group_message(group_id, message_id, existing)
      render json: ticket_result(existing)
      return
    end
    source = group_message_source(group_id, message_id)
    raise ActionController::BadRequest, __('This message cannot create a ticket.') if source['from_me'] || source['zammad_customer_id'].blank?
    raise ActionController::BadRequest, __('This message is already linked to a ticket.') if source.fetch('links', []).any?

    article = find_or_create_group_ticket_article(source, target_group_id, ticket_title(params[:title], source['group_name']))
    link_group_message(group_id, message_id, article)
    render json: ticket_result(article), status: :created
  end

  def group_workspace_link_ticket
    ensure_group_agent!
    group_id = uuid!(params[:group_id], 'group')
    message_id = uuid!(params[:message_id], 'message')
    ticket_number = positive_identifier!(params[:ticket_number], 'ticket number')
    uuid!(params[:request_token], 'ticket link request')
    ticket = Ticket.find_by(number: ticket_number)
    raise ActiveRecord::RecordNotFound, __('Ticket not found') if !ticket

    authorize!(ticket, :agent_update_access?)
    source = group_message_source(group_id, message_id)
    existing = source.fetch('links', []).find { |link| link['ticket_id'].to_s == ticket.id.to_s && link['article_id'].present? }
    article = if existing
                Ticket::Article.find_by!(id: positive_identifier!(existing['article_id'], 'linked article'), ticket_id: ticket.id)
              else
                find_or_create_link_article(source, ticket)
              end
    link_group_message(group_id, message_id, article)
    render json: ticket_result(article)
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

  def group_message_source(group_id, message_id)
    Wasalx::Client.get(
      "/internal/v1/zammad/group-workspace/groups/#{group_id}/messages/#{message_id}/source",
      scope: 'zammad:groups', actor: group_actor
    )
  end

  def find_or_create_group_ticket_article(source, target_group_id, title)
    operation_key = operation_key('create', source['id'])
    existing = Ticket::Article.find_by(wasalx_operation_key: operation_key)
    if existing
      authorize!(existing.ticket, :agent_read_access?)
      return existing
    end

    group = Group.find_by(id: target_group_id, active: true)
    raise ActiveRecord::RecordNotFound, __('Ticket group not found') if !group
    customer = User.find(source.fetch('zammad_customer_id'))
    ticket = Ticket.new(
      title: title, group_id: group.id, customer_id: customer.id,
      wasalx_connection_id: source.fetch('connection_id'), wasalx_group_id: source.fetch('external_group_id'),
      wasalx_group_name: source.fetch('group_name'), wasalx_provider: source.fetch('provider'),
      wasalx_source_message_id: source.fetch('external_message_id'),
      wasalx_latest_external_message_id: source.fetch('external_message_id'),
      created_by_id: current_user.id, updated_by_id: current_user.id
    )
    authorize!(ticket, :create?)
    Transaction.execute do
      ticket.save!
      create_group_message_article(ticket, source, operation_key)
    end
  rescue ActiveRecord::RecordNotUnique
    existing = Ticket::Article.find_by!(wasalx_operation_key: operation_key)
    authorize!(existing.ticket, :agent_read_access?)
    existing
  end

  def find_or_create_link_article(source, ticket)
    operation_key = operation_key("link:#{ticket.id}", source['id'])
    existing = Ticket::Article.find_by(wasalx_operation_key: operation_key)
    return existing if existing

    create_group_message_article(ticket, source, operation_key)
  rescue ActiveRecord::RecordNotUnique
    Ticket::Article.find_by!(wasalx_operation_key: operation_key)
  end

  def create_group_message_article(ticket, source, operation_key)
    Ticket::Article.create!(
      ticket_id: ticket.id, content_type: 'text/plain', body: source['message_text'].presence || __('Unsupported message'),
      internal: false, sender: Ticket::Article::Sender.find_by!(name: 'Customer'),
      type: Ticket::Article::Type.find_by!(name: 'wasalx group message'),
      preferences: { wasalx_origin: 'provider', wasalx_external_message_id: source.fetch('external_message_id') },
      wasalx_operation_key: operation_key, created_by_id: current_user.id, updated_by_id: current_user.id
    )
  end

  def link_group_message(group_id, message_id, article)
    Wasalx::Client.post(
      "/internal/v1/zammad/group-workspace/groups/#{group_id}/messages/#{message_id}/tickets",
      { ticketId: article.ticket_id, articleId: article.id,
        idempotency_key: "group-link:#{article.ticket_id}:#{message_id}" },
      scope: 'zammad:groups', actor: group_actor
    )
  end

  def ticket_result(article)
    ticket = article.ticket
    { ticket_id: ticket.id.to_s, ticket_number: ticket.number.to_s, article_id: article.id.to_s }
  end

  def operation_key(kind, message_id)
    "wasalx:group:#{ENV.fetch('WASALX_TENANT_ID')}:#{kind}:#{uuid!(message_id, 'message')}"
  end

  def ticket_title(value, group_name)
    title = value.to_s.unicode_normalize(:nfc).gsub(/[\p{Cc}\p{Cf}]/, ' ').squeeze(' ').strip
    title = "#{group_name.to_s.unicode_normalize(:nfc).gsub(/[\p{Cc}\p{Cf}]/, ' ').squeeze(' ').strip} — #{__('WhatsApp message')}" if title.empty?
    raise ActionController::BadRequest, __('Invalid ticket title') if title.empty? || title.each_char.count > 200

    title
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
