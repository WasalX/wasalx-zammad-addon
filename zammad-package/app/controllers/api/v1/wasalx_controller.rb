# SPDX-License-Identifier: AGPL-3.0-only
require 'digest'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require_relative '../../../../lib/wasalx/reply_preview'
require_relative '../../../../lib/wasalx/group_workspace'

class Api::V1::WasalxController < ApplicationController
  include Wasalx::NativeIdentifiers
  # Authenticate the caller here, then authorize the concrete ticket in each
  # action below. `authenticate_and_authorize!` also asks Pundit for a
  # controller policy; package controllers do not own one and that would turn
  # an otherwise authorized agent request into a 500 before ticket checks run.
  prepend_before_action :authentication_check
  rescue_from Wasalx::Client::RequestFailed, with: :render_wasalx_request_failure

  def service_readiness
    ensure_group_service!
    proof = Wasalx::InstalledPackage.verify!
    credentials = Setting.get('auth_openid_connect_credentials').to_h.with_indifferent_access
    # Return only public configuration, never credentials or the handover subject.
    render json: { tenant_id: ENV.fetch('WASALX_TENANT_ID'), instance_id: ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'),
      package: { name: 'wasalx', version: proof.fetch('package_version'), state: 'installed', sha256: proof.fetch('native_package_sha256') },
      oidc: { issuer: credentials[:issuer], client_id: credentials[:identifier], pkce: credentials[:pkce], uid_field: credentials[:uid_field], scope: credentials[:scope],
        enabled: Setting.get('auth_openid_connect') == true, password_login_disabled: Setting.get('user_show_password_login') == false },
      mail: Wasalx::PortalMail.review,
      groups: Group.where(active: true).order(:id).map { |group| { id: group.id, name: group.name, active: group.active } } }
  end

  def service_catalog
    ensure_group_service!
    render json: { slas: Sla.order(:id).map { |sla| sla.attributes.slice('id', 'name', 'active', 'calendar_id') },
      calendars: Calendar.order(:id).map { |calendar| calendar.attributes.slice('id', 'name', 'active', 'timezone') } }
  end

  def privacy_operation
    Wasalx::ServiceIdentity.authorize!(current_user, @_token, 'privacy')
    input = params.permit(:job_id, :lease_id, :fencing_token, :target_id, :operation, :native_id, :attempt).to_h
    admission = Wasalx::Client.post('/internal/v1/zammad/privacy/admission', input, scope: 'zammad:privacy')
    valid = admission.is_a?(Hash) && admission['allowed'] == true && admission['tenant_id'] == ENV.fetch('WASALX_TENANT_ID') &&
      admission['instance_id'] == ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID') && %w[job_id operation native_id].all? { |key| admission[key] == input[key] } && (!input['target_id'] || admission['target_id'] == input['target_id'])
    raise Exceptions::Forbidden, 'Not authorized' unless valid
    id = positive_identifier!(input.fetch('native_id'), 'privacy target')
    case input.fetch('operation')
    when 'DELETE_TICKET'
      Ticket.find_by(id: id)&.destroy!
      head :no_content
    when 'READ_TICKET'
      ticket = Ticket.find_by(id: id)
      render json: ticket&.attributes_with_association_names
    when 'READ_ARTICLES'
      render json: Ticket::Article.where(ticket_id: id).order(:id).map { |article| article.attributes_with_association_names }
    when 'CREATE_USER_TASK'
      # The native task itself stores the source receipt. A lost HTTP response
      # cannot create a second destructive task with the same admitted target.
      task = DataPrivacyTask.transaction do
        DataPrivacyTask.connection.execute("SELECT pg_advisory_xact_lock(#{Digest::SHA256.hexdigest("privacy:#{input.fetch('target_id')}")[0, 15].to_i(16)})")
        existing = DataPrivacyTask.where(deletable_type: 'User', deletable_id: id).find do |item|
          item.preferences.to_h.with_indifferent_access[:wasalx_privacy_target] == input.fetch('target_id')
        end
        if existing
          raise Exceptions::Forbidden, 'Not authorized' unless existing.preferences.to_h.with_indifferent_access[:wasalx_privacy_job] == input.fetch('job_id')
          next existing
        end
        target = User.find(id)
        raise Exceptions::Forbidden, 'Not authorized' if Wasalx::ServiceIdentity.automation?(target) || target.id == current_user.id || target.roles.any? { |role| role.name == 'Admin' }
        DataPrivacyTask.create!(deletable_type: 'User', deletable_id: id, created_by_id: current_user.id, updated_by_id: current_user.id,
          preferences: { wasalx_privacy_job: input.fetch('job_id'), wasalx_privacy_target: input.fetch('target_id') })
      end
      render json: { id: task.id.to_s, state: task.state }
    when 'READ_USER_TASK'
      task = DataPrivacyTask.find(id)
      prefs = task.preferences.to_h.with_indifferent_access
      raise Exceptions::Forbidden, 'Not authorized' unless task.deletable_type == 'User' && task.deletable_id.to_s == admission['source_native_id'] &&
        prefs[:wasalx_privacy_job] == input['job_id'] && prefs[:wasalx_privacy_target] == input['target_id']
      render json: { id: task.id.to_s, state: task.state }
    else
      raise ActionController::BadRequest, 'Invalid privacy operation'
    end
  end

  def panel
    ticket = Ticket.find(params[:ticket_id])
    authorize!(ticket, :agent_read_access?)

    render json: Service::Ticket::WasalxPanel.new(ticket: ticket, current_user: current_user).execute
  end

  def reply_preview
    ensure_group_agent!
    ticket = Ticket.find(positive_identifier!(params[:ticket_id], 'ticket'))
    authorize!(ticket, :agent_update_access?)
    input = %i[ticket_id body internal has_attachments in_reply_to restored_draft].each_with_object({}) do |key, values|
      values[key] = params[key] if params.key?(key)
    end
    render json: Wasalx::ReplyPreview.new(actor: current_user).call(**input)
  end

def reconcile_direct_native_intent
  ensure_group_service!
  ticket = Ticket.find(params[:ticket_id])
  operation_id = uuid!(params[:operation_id], 'native reply intent')
  ticket.with_lock do
    # Reservation was made inside the same native ticket lock at before_create.
    # Acquiring it now proves that original article transaction has ended.
    found = Ticket::Article.where(ticket_id: ticket.id).any? { |article| (article.preferences || {})['wasalx_native_reply_intent_id'] == operation_id }
    raise ArgumentError, 'Native article is committed; do not cancel its intent' if found
    render json: Wasalx::Client.post("/internal/v1/zammad/direct-native-intents/#{operation_id}/absent",
      { ticket_id: ticket.id.to_s, native_ticket_locked: true, article_absent: true,
        native_updated_at: ticket.updated_at.utc.iso8601(6), last_article_id: (Ticket::Article.where(ticket_id: ticket.id).maximum(:id) || 0).to_s },scope: 'zammad:ticket-state')
  end
end

def customer_close_context
  ensure_group_service!
  ticket = Ticket.find(params[:ticket_id])
  ticket.with_lock do
    raise ArgumentError, 'Direct ticket is required' unless ticket.wasalx_bot_conversation.to_s == 'true'
    render json: { updated_at: ticket.updated_at.utc.iso8601(6), state_id: ticket.state_id.to_s,
      last_article_id: Ticket::Article.where(ticket_id: ticket.id).maximum(:id).to_s,
      native_group_id: ticket.group_id.to_s, connection_id: ticket.wasalx_connection_id.to_s,
      external_chat_id: ticket.wasalx_group_id.to_s, customer_id: ticket.customer_id.to_s,
      closed: Ticket::StateType.lookup(id: Ticket::State.lookup(id: ticket.state_id)&.state_type_id)&.name.to_s.downcase == 'closed' }
  end
end

def customer_close
  ensure_group_service!
  service = Service::Ticket::WasalxCustomerClose.new(ticket: Ticket.find(params[:ticket_id]),
    command_id: uuid!(params[:command_id], 'customer close command'), current_user: current_user)
  render json: request.get? ? service.reconcile : service.execute
end

def quoted_command_context
  ensure_group_service!
  ticket = Ticket.find(params[:ticket_id])
  email = params[:member_email].to_s
  raise ArgumentError, 'Invalid member identity' if email.length > 320 || email.match?(/[\p{Cc}\p{Cf}]/)
  ticket.with_lock do
    users = email.present? ? User.where('LOWER(email) = ?', email.downcase).where(active: true).limit(2).to_a : []
    agent = users.one? && users.first
    render json: {
      updated_at: ticket.updated_at.utc.iso8601(6), state_id: ticket.state_id.to_s,
      last_article_id: Ticket::Article.where(ticket_id: ticket.id).maximum(:id).to_s,
      native_group_id: ticket.group_id.to_s, connection_id: ticket.wasalx_connection_id.to_s,
      external_group_id: ticket.wasalx_group_id.to_s,
      denied_command_transcript: 'v1',
      active_agent: !!(agent && agent.permissions?('ticket.agent') && agent.group_ids_access('full').map(&:to_s).include?(ticket.group_id.to_s))
    }
  end
end

def quoted_command
  ensure_group_service!
  service = Service::Ticket::WasalxQuotedCommand.new(ticket: Ticket.find(params[:ticket_id]),
    execution_id: uuid!(params[:execution_id], 'command execution'), current_user: current_user)
  render json: request.get? ? service.reconcile : service.execute
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
      scope: 'zammad:retry', actor: group_actor
    )
    render json: response, status: :accepted
  end

  def retry_email_routing
    allowed = current_user.permissions?('ticket.agent.wasalx_retry') || current_user.permissions?('admin')
    raise Exceptions::Forbidden, __('Not authorized') if !allowed

    ticket = Ticket.find(params[:ticket_id])
    authorize!(ticket, :agent_update_access?)
    article = Ticket::Article.find(positive_identifier!(params[:article_id], 'article'))
    raise ActiveRecord::RecordNotFound, __('Article not found') if article.ticket_id != ticket.id

    render json: WasalxTicketRoutingJob.replay!(ticket: ticket, article: article), status: :accepted
  rescue Wasalx::Client::PermanentRequestFailed
    raise ActionController::BadRequest, __('Email routing cannot be retried.')
  end

  def group_workspace_groups
    render json: group_workspace_service.groups(limit: params[:limit], after: params[:after], selected: params[:selected], scope: params[:scope])
  end

  def group_workspace_messages
    render json: group_workspace_service.messages(group_id: params[:group_id], limit: params[:limit], before: params[:before])
  end

  def group_workspace_participants
    render json: group_workspace_service.participants(group_id: params[:group_id], q: params[:q])
  end

  def group_workspace_context
    render json: group_workspace_service.context(group_id: params[:group_id], message_id: params[:message_id])
  end

  def group_workspace_tickets
    render json: group_workspace_service.tickets(group_id: params[:group_id], limit: params[:limit], before: params[:before])
  end

  def group_workspace_ticket_groups
    render json: group_workspace_service.ticket_groups
  end

  def group_workspace_create_ticket
    result = group_workspace_service.create_ticket(group_id: params[:group_id], message_id: params[:message_id], target_group_id: params[:target_group_id], request_token: params[:request_token], title: params[:title])
    render json: result.data, status: result.created ? :created : :ok
  end

  def group_workspace_link_ticket
    render json: group_workspace_service.link_ticket(group_id: params[:group_id], message_id: params[:message_id], ticket_number: params[:ticket_number], request_token: params[:request_token])
  end

  def group_workspace_read
    render json: group_workspace_service.read(group_id: params[:group_id], message_id: params[:message_id])
  end

  def group_workspace_send
    render json: group_workspace_service.send_message(group_id: params[:group_id], request_token: params[:request_token], message: params[:message], reply_to_message_id: params[:reply_to_message_id], mentions: params[:mentions], upload_cache_id: params[:upload_cache_id], upload_store_ids: params[:upload_store_ids]), status: :accepted
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
    file = group_workspace_service.message_media(group_id: params[:group_id], message_id: params[:message_id])
    send_data file.data, filename: file.filename, type: file.content_type, disposition: file.disposition
  end

  def group_workspace_upload_destroy
    Store.remove_item(group_workspace_upload_store.id)
    head :no_content
  end

  def group_workspace_reaction
    render json: group_workspace_service.reaction(group_id: params[:group_id], message_id: params[:message_id], request_token: params[:request_token], emoji: params[:emoji], removed_value: params.key?(:removed) ? params[:removed] : Wasalx::GroupWorkspace::UNSET), status: :accepted
  end

  private

  def group_workspace_service
    Wasalx::GroupWorkspace.new(actor: current_user)
  end

  def render_wasalx_request_failure(error)
    raise error if error.http_status != 404

    render json: { error: __('Not found') }, status: :not_found
  end

  def ensure_group_agent!
    raise Exceptions::Forbidden, __('Not authorized') if !current_user.permissions?('ticket.agent')
  end

  def ensure_group_service!
    Wasalx::ServiceIdentity.authorize!(current_user, @_token)
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

  def group_actor
    Wasalx::GroupWorkspace.actor_claims(current_user)
  end

end
