# SPDX-License-Identifier: AGPL-3.0-only
require 'digest'
# Copyright (c) 2026 WasalX

class Api::V1::WasalxController < ApplicationController
  # Authenticate the caller here, then authorize the concrete ticket in each
  # action below. `authenticate_and_authorize!` also asks Pundit for a
  # controller policy; package controllers do not own one and that would turn
  # an otherwise authorized agent request into a 500 before ticket checks run.
  prepend_before_action :authentication_check

  def panel
    ticket = Ticket.find(params[:ticket_id])
    authorize!(ticket, :agent_read_access?)

    render json: Service::Ticket::WasalxPanel.new(ticket: ticket, current_user: current_user).execute
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

  def group_workspace_participants
    ensure_group_agent!
    group_id = uuid!(params[:group_id], 'group')
    query = { q: params[:q].to_s }.to_query
    render json: Wasalx::Client.get("/internal/v1/zammad/group-workspace/groups/#{group_id}/participants?#{query}", scope: 'zammad:groups', actor: group_actor)
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
    limit = bounded_limit!(params[:limit])
    before = params[:before].present? ? uuid!(params[:before], 'ticket cursor') : nil
    query = { limit: limit, before: before }.compact.to_query
    page = Wasalx::Client.get("/internal/v1/zammad/group-workspace/groups/#{group_id}/tickets?#{query}", scope: 'zammad:groups', actor: group_actor)
    candidates = page.fetch('items')
    grouped = candidates.group_by { |candidate| positive_identifier!(candidate['ticket_id'], 'ticket') }
    ticket_by_id = Ticket.where(id: grouped.keys).index_by { |ticket| ticket.id.to_s }
    open_state_ids = Ticket::State.by_category(:open).pluck(:id)
    closed_state_ids = Ticket::State.by_category(:closed).pluck(:id)
    visible = grouped.filter_map do |ticket_id, links|
      ticket = ticket_by_id[ticket_id]
      next if !ticket
      next if !TicketPolicy.new(current_user, ticket).agent_read_access?
      state_category = if open_state_ids.include?(ticket.state_id)
                         'OPEN'
                       elsif closed_state_ids.include?(ticket.state_id)
                         'CLOSED'
                       end
      next if !state_category

      {
        ticket_id: ticket.id.to_s, ticket_number: ticket.number.to_s, reference: ticket.title.to_s,
        state_category: state_category,
        links: links.filter_map do |link|
          next if link['message_id'].blank?

          { message_id: uuid!(link['message_id'], 'linked message'),
            article_id: link['article_id'].present? ? positive_identifier!(link['article_id'], 'linked article') : nil }
        end.uniq
      }
    end
    render json: { items: visible, next_cursor: page['next_cursor'] }
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
    raise ActionController::BadRequest, __('This message cannot create a ticket.') if source['from_me']
    ensure_group_message_actionable!(source)
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
    raise ActionController::BadRequest, __('Outbound group messages cannot be linked to a customer ticket article.') if source['from_me']
    ensure_group_message_actionable!(source)
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
    raise ActionController::BadRequest, __('Invalid message') if message.each_char.count > 4096 || message.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)
    mentions = group_mentions!(params[:mentions], message)

    uploads = []
    begin
      uploads = stage_group_workspace_uploads(request_token)
      raise ActionController::BadRequest, __('Invalid message') if message.empty? && uploads.empty?
      result = Wasalx::Client.post(
        "/internal/v1/zammad/group-workspace/groups/#{group_id}/send",
        { message: message, replyToMessageId: reply_to_message_id, agentDisplayName: current_user.fullname,
          attachments: uploads.map { |upload| upload.fetch(:descriptor) },
          mentions: mentions,
          idempotency_key: "group-workspace:#{current_user.id}:#{request_token}" },
        scope: 'zammad:groups', actor: group_actor
      )
      remove_created_workspace_uploads(uploads) if result['duplicate']
      render json: result, status: :accepted
    rescue Wasalx::Client::TemporaryRequestFailed
      # The request may already be queued. Keep its stable staged files so an
      # exact replay can retrieve the existing delivery without duplicating it.
      raise
    rescue Wasalx::Client::PermanentRequestFailed
      remove_created_workspace_uploads(uploads)
      raise
    end
  end

  def group_workspace_upload
    data, filename, content_type = Store.transaction do
      store = group_workspace_upload_store(lock: true)
      store.touch
      [store.content, store.filename, store.preferences['Content-Type']]
    end
    send_data data, filename: filename, type: content_type, disposition: 'attachment'
  end

  def group_workspace_message_media
    ensure_group_agent!
    group_id = uuid!(params[:group_id], 'group')
    message_id = uuid!(params[:message_id], 'message')
    metadata = Wasalx::Client.get("/internal/v1/zammad/group-workspace/groups/#{group_id}/messages/#{message_id}/media", scope: 'zammad:groups', actor: group_actor)
    maximum = Integer(positive_identifier!(metadata.fetch('byte_size'), 'media size'))
    raise ActionController::BadRequest, __('Invalid media size') if maximum > 50_000_000
    media = Wasalx::Client.download(metadata.fetch('url'), maximum)
    send_data media.fetch(:data), filename: metadata.fetch('filename'), type: media.fetch(:content_type), disposition: media.fetch(:content_type).start_with?('image/', 'audio/', 'video/') ? 'inline' : 'attachment'
  end

  def group_workspace_upload_destroy
    Store.remove_item(group_workspace_upload_store.id)
    head :no_content
  end

  private

  def ensure_group_agent!
    raise Exceptions::Forbidden, __('Not authorized') if !current_user.permissions?('ticket.agent')
  end

  def ensure_group_service!
    raise Exceptions::Forbidden, __('Not authorized') if !current_user.permissions?('admin.system')
  end

  def stage_group_workspace_uploads(request_token)
    values = Array(params[:upload_store_ids])
    return [] if values.empty? && params[:upload_cache_id].blank?
    cache_id = uuid!(params[:upload_cache_id], 'upload')
    store_ids = values.map { |value| positive_identifier!(value, 'upload item') }.uniq
    raise ActionController::BadRequest, __('Invalid attachments') if store_ids.empty? || store_ids.length > 10 || store_ids.length != values.length
    source = UploadCache.new(cache_id).attachments.index_by { |item| item.id.to_s }
    raise ActionController::BadRequest, __('Invalid attachments') if store_ids.any? { |id| !source.key?(id) }

    existing_items = Store.list(object: 'Wasalx::GroupWorkspaceUpload', o_id: request_token,
                                created_by_id: current_user.id).to_a
    existing = existing_items.index_by { |item| item.preferences['Wasalx-Upload-Store-Id'].to_s }
    raise ActionController::BadRequest, __('Invalid attachments') if existing.length != existing_items.length || existing.keys.any? { |id| !store_ids.include?(id) }

    created = []
    store_ids.map do |id|
      item = source.fetch(id)
      stored = existing[id]
      was_created = false
      if stored
        valid = stored.preferences['Wasalx-Upload-Cache-Id'] == cache_id && stored.filename == item.filename &&
          stored.size == item.size && stored.preferences['Content-Type'] == item.preferences['Content-Type']
        raise ActionController::BadRequest, __('Invalid attachments') if !valid
        stored.touch
      else
        stored = Store.create!(object: 'Wasalx::GroupWorkspaceUpload', o_id: request_token, filename: item.filename,
                               data: item.content, preferences: { 'Content-Type' => item.preferences['Content-Type'],
                                                                  'Wasalx-Upload-Cache-Id' => cache_id,
                                                                  'Wasalx-Upload-Store-Id' => id },
                               created_by_id: current_user.id)
        created << stored
        was_created = true
      end
      { store: stored, created: was_created,
        descriptor: { upload_id: request_token, store_id: stored.id, uploadCacheId: cache_id,
                      sourceStoreId: id.to_i, filename: stored.filename,
                      mimeType: stored.preferences['Content-Type'], byteSize: stored.size } }
    end
  rescue StandardError
    created&.each { |store| Store.remove_item(store.id) }
    raise
  end

  def remove_created_workspace_uploads(uploads)
    uploads.each { |upload| Store.remove_item(upload.fetch(:store).id) if upload[:created] }
  end

  def group_workspace_upload_store(lock: false)
    ensure_group_service!
    upload_id = uuid!(params[:upload_id], 'upload')
    store_id = positive_identifier!(params[:store_id], 'upload item')
    scope = Store.list(object: 'Wasalx::GroupWorkspaceUpload', o_id: upload_id, created_by_id: nil)
    scope = scope.lock if lock
    store = scope.find_by(id: store_id)
    raise ActiveRecord::RecordNotFound, __('Attachment not found') if !store

    store
  end

  def group_mentions!(values, message)
    mentions = values.nil? ? [] : values
    raise ActionController::BadRequest, __('Invalid mentions') if !mentions.is_a?(Array)
    raise ActionController::BadRequest, __('Invalid mentions') if mentions.length > 20 || mentions.uniq.length != mentions.length
    mentions.each do |mention|
      raise ActionController::BadRequest, __('Invalid mentions') if !mention.is_a?(String) || !mention.match?(/\A[1-9][0-9]{5,19}@(c\.us|s\.whatsapp\.net|lid)\z/)
      number = mention.split('@', 2).first
      raise ActionController::BadRequest, __('Invalid mentions') if !message.match?(/(?:\A|[^0-9])@#{Regexp.escape(number)}(?![0-9])/)
    end
    mentions
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
    ticket = Ticket.new(
      title: title, group_id: group.id,
      wasalx_connection_id: source.fetch('connection_id'), wasalx_group_id: source.fetch('external_group_id'),
      wasalx_group_name: source.fetch('group_name'), wasalx_provider: source.fetch('provider'),
      wasalx_source_message_id: source.fetch('external_message_id'),
      wasalx_latest_external_message_id: source.fetch('external_message_id'),
      created_by_id: current_user.id, updated_by_id: current_user.id
    )
    authorize!(ticket, :create?)
    attachment = group_message_attachment(source)
    Transaction.execute do
      customer = group_message_customer(source)
      ticket.customer_id = customer.id
      authorize!(ticket, :create?)
      ticket.save!
      create_group_message_article(ticket, source, operation_key, customer, attachment)
    end
  rescue ActiveRecord::RecordNotUnique
    existing = Ticket::Article.find_by!(wasalx_operation_key: operation_key)
    authorize!(existing.ticket, :agent_read_access?)
    existing
  end

  def group_message_customer(source)
    mobile = group_message_mobile(source)
    if source['zammad_customer_id'].present?
      return add_group_message_mobile(User.find(positive_identifier!(source['zammad_customer_id'], 'customer')), mobile)
    end

    participant = source.fetch('external_participant_id').to_s
    raise ActionController::BadRequest, __('This message cannot create a ticket.') if participant.empty? || participant.each_char.count > 512

    login = "wasalx-#{Digest::SHA256.hexdigest([ENV.fetch('WASALX_TENANT_ID'), source.fetch('connection_id'), participant].join("\u001f"))}"
    existing = User.find_by(login: login)
    return add_group_message_mobile(existing, mobile) if existing

    name = source['participant_name'].to_s.unicode_normalize(:nfc).gsub(/[\p{Cc}\p{Cf}]/, ' ').squeeze(' ').strip.each_char.take(100).join
    User.create!(login: login, firstname: name.presence || __('WhatsApp participant'), mobile: mobile, active: true,
                 created_by_id: current_user.id, updated_by_id: current_user.id)
  rescue ActiveRecord::RecordNotUnique
    add_group_message_mobile(User.find_by!(login: login), mobile)
  end

  def find_or_create_link_article(source, ticket)
    operation_key = operation_key("link:#{ticket.id}", source['id'])
    existing = Ticket::Article.find_by(wasalx_operation_key: operation_key)
    return existing if existing

    customer = group_message_customer(source)
    attachment = group_message_attachment(source)
    Transaction.execute { create_group_message_article(ticket, source, operation_key, customer, attachment) }
  rescue ActiveRecord::RecordNotUnique
    Ticket::Article.find_by!(wasalx_operation_key: operation_key)
  end

  def create_group_message_article(ticket, source, operation_key, customer, attachment = nil)
    article = Ticket::Article.create!(
      ticket_id: ticket.id, content_type: 'text/plain', body: source['message_text'].presence || group_message_media_label(source),
      internal: false, sender: Ticket::Article::Sender.find_by!(name: 'Customer'),
      type: Ticket::Article::Type.find_by!(name: 'wasalx group message'),
      preferences: { wasalx_origin: 'provider', wasalx_external_message_id: source.fetch('external_message_id') },
      wasalx_operation_key: operation_key, origin_by_id: customer.id,
      created_by_id: current_user.id, updated_by_id: current_user.id
    )
    if attachment
      Store.create!(object: 'Ticket::Article', o_id: article.id, data: attachment.fetch(:data),
                    filename: attachment.fetch(:filename), preferences: { 'Mime-Type' => attachment.fetch(:mime_type) })
    end
    article
  end

  def ensure_group_message_actionable!(source)
    raise ActionController::BadRequest, __('Deleted messages cannot be added to a ticket.') if source['latest_mutation'] == 'REVOKED'
  end

  def group_message_attachment(source)
    return if source['media_available'] != true

    group_id = uuid!(source.fetch('group_id'), 'group')
    message_id = uuid!(source.fetch('id'), 'message')
    metadata = Wasalx::Client.get(
      "/internal/v1/zammad/group-workspace/groups/#{group_id}/messages/#{message_id}/media",
      scope: 'zammad:groups', actor: group_actor
    )
    maximum = Integer(positive_identifier!(metadata.fetch('byte_size'), 'media size'))
    raise ActionController::BadRequest, __('Invalid media size') if maximum > 50_000_000

    media = Wasalx::Client.download(metadata.fetch('url'), maximum)
    raise Wasalx::Client::PermanentRequestFailed, 'WasalX media size changed' if media.fetch(:data).bytesize != maximum

    { data: media.fetch(:data), filename: metadata.fetch('filename'), mime_type: metadata.fetch('mime_type') }
  end

  def group_message_media_label(source)
    label = case source['media_kind']
            when 'image' then __('Image')
            when 'video' then __('Video')
            when 'audio' then __('Audio')
            when 'document' then __('Document')
            else __('Unsupported message')
            end
    source['media_filename'].present? ? "#{label}: #{source['media_filename']}" : label
  end

  def group_message_mobile(source)
    participant = source.fetch('external_participant_id').to_s
    jid = participant.match(/\A([1-9][0-9]{5,14})@(c\.us|s\.whatsapp\.net)\z/)
    digits = jid&.[](1)
    digits ||= participant if source['provider'].to_s.casecmp('META').zero? && participant.match?(/\A[1-9][0-9]{5,14}\z/)
    digits ? "+#{digits}" : nil
  end

  def add_group_message_mobile(customer, mobile)
    return customer if mobile.blank? || customer.mobile.present?

    customer.update!(mobile: mobile, updated_by_id: current_user.id)
    customer
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
