# SPDX-License-Identifier: AGPL-3.0-only
require 'digest'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require_relative '../../../../lib/wasalx/reply_preview'
require_relative '../../../../lib/wasalx/portal_workspace_uploads'
require 'cgi'
require_relative '../../../../lib/wasalx/portal_groups'
require_relative '../../../../lib/wasalx/portal_team_administration'
require_relative '../../../../lib/wasalx/portal_mailbox_administration'
require_relative '../../../../lib/wasalx/portal_email_sender'
require_relative '../../../../lib/wasalx/portal_mail_delivery'

class Api::V1::WasalxPortalWorkspaceController < ApplicationController
  include Wasalx::PortalGroups
  include Wasalx::PortalWorkspaceUploads
  prepend_before_action :authentication_check
  class Conflict < StandardError; end
  class ReauthenticationRequired < StandardError; end
  Attachment = Struct.new(:data, :filename, :content_type, :disposition)
  ARTICLE_PREVIEW_LIMIT = 50_000
  class ArticleWriter
    include CreatesTicketArticles
    attr_reader :current_user
    def initialize(actor)
      @current_user = actor
    end
    def call(ticket, attributes)
      # Native notes and email require a body even with verified attachments.
      if %w[note email].include?(attributes[:type]) && attributes[:form_id].present? && attributes[:body].blank?
        attributes = attributes.merge(body: __('Attachment'))
      end
      article_create(ticket, attributes.with_indifferent_access)
    end
  end

  def create
    raise Exceptions::Forbidden unless Wasalx::ServiceIdentity.token_allowed?(current_user, @_token, 'runtime')
    @envelope = Wasalx::PortalDelegation.decode(request.raw_post, request.headers['X-Wasalx-Timestamp'].to_s,
      request.headers['X-Wasalx-Signature'].to_s, secret: ENV.fetch('WASALX_SERVICE_JWT_SECRET'),
      tenant: ENV.fetch('WASALX_TENANT_ID'), instance: ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'))
    @actor = resolve_actor!
    @input = @envelope.fetch('input')
    result = UserInfo.with_user_id(@actor.id) do
      case @envelope.fetch('operation')
      when 'PRIVACY_TARGET' then privacy_target
      when 'PREVIEW' then preview
      when 'CHECK' then keys!([]); { allowed: true }
      when 'LIST' then list
      when 'SHOW' then show
      when 'ARTICLES' then articles
      when 'ARTICLE_CONTENT' then article_content
      when 'SOURCE_CONTEXT' then source_context
      when 'CREATE_OPTIONS' then create_options
      when 'CREATE_TICKET' then create_ticket
      when 'CREATE_RECEIPT' then create_receipt
      when 'ATTACHMENT' then attachment
      when 'GROUP_MEDIA' then group_media
      when 'GROUP_REMOVE_UPLOAD', 'REMOVE_UPLOAD' then remove_workspace_upload
      when 'REPLY', 'UPDATE' then mutate
      when 'RECEIPT' then receipt
      when /^GROUP_/ then group_operation
      when /^TEAM_/ then Wasalx::PortalTeamAdministration.new(actor: @actor, envelope: @envelope, authorizer: -> { resolve_actor! }).call
      when /^MAILBOX_/ then Wasalx::PortalMailboxAdministration.new(actor: @actor, envelope: @envelope, authorizer: -> { resolve_actor! }).call
      end
    end
    response.headers['Cache-Control'] = 'private, no-store'
    if result.is_a?(Attachment)
      response.headers['X-Content-Type-Options'] = 'nosniff'
      response.headers['Content-Length'] = result.data.bytesize.to_s
      send_data result.data, filename: result.filename, type: result.content_type || 'application/octet-stream', disposition: result.disposition || 'attachment'
    else
      render json: result
    end
  rescue ReauthenticationRequired
    render json: { code: 'REAUTHENTICATION_REQUIRED' }, status: :forbidden
  rescue Wasalx::PortalGroups::GroupUnavailable => error
    render json: { code: 'GROUP_ACCESS_DENIED', group_id: error.group_id }, status: :forbidden
  rescue Wasalx::GroupWorkspace::Rejected, Wasalx::GroupWorkspace::RejectedMissing => error
    render json: error.result, status: error.status
  rescue Wasalx::PortalDelegation::Invalid, ArgumentError
    render json: { code: 'INVALID_WORKSPACE_REQUEST' }, status: :bad_request
  rescue Conflict, Wasalx::GroupWorkspace::Conflict, Wasalx::PortalTeamAdministration::Conflict, Wasalx::PortalMailboxAdministration::Conflict
    render json: { code: 'WORKSPACE_CONFLICT' }, status: :conflict
  rescue Wasalx::Client::RequestFailed, Wasalx::PortalMailboxAdministration::StorageError
    render json: { code: 'WORKSPACE_UNAVAILABLE' }, status: :service_unavailable
  end

  private

  def resolve_actor!
    identity = @envelope.fetch('actor')
    row = WasalxMembership.find_by(portal_user_id: identity.fetch('user_id'))
    valid = row && row.tenant_id == @envelope['tenant_id'] && row.instance_id == @envelope['instance_id'] &&
      row.subject == identity['subject'] && row.revision == identity['revision'] &&
      row.user_id.to_s == identity['native_user_id'] && row.member_state == 'ACTIVE' && row.portal_role != 'auditor'
    raise Exceptions::Forbidden unless valid
    actor = User.find_by(id: row.user_id)
    raise Exceptions::Forbidden unless actor && actor.active && actor.permissions?('ticket.agent') &&
      !Wasalx::ServiceIdentity.automation?(actor) &&
      Wasalx::MembershipProjection.native_access_matches?(actor, row.portal_role, row.member_state) &&
      Authorization.where(provider: 'openid_connect', uid: row.subject).pluck(:user_id) == [actor.id]
    privileged = Wasalx::PortalTeamAdministration::WRITES.include?(@envelope['operation']) ||
      Wasalx::PortalMailboxAdministration::WRITES.include?(@envelope['operation']) ||
      (%w[TEAM_RECEIPT MAILBOX_RECEIPT].include?(@envelope['operation']) && @envelope['input']['cancel_if_missing'] == true)
    check = { user_id: row.portal_user_id, native_user_id: actor.id.to_s, revision: row.revision }
    check[:privileged] = true if privileged
    result = Wasalx::Client.post('/internal/v1/zammad/membership/check', check, scope: 'zammad:membership')
    policy = result.is_a?(Hash) && Wasalx::SessionAssurance.policy(result['authentication_policy'])
    assurance = @envelope.fetch('assurance')
    raise Exceptions::Forbidden unless result.is_a?(Hash) && result['allowed'] == true && policy &&
      policy['subject'] == row.subject && result['portal_source'] == @envelope['source'] &&
      Wasalx::SessionAssurance.recent?(assurance['auth_time'], policy) &&
      (!policy['mfa_required'] || Wasalx::SessionAssurance.authoritative_mfa?(assurance, policy))
    if privileged
      minutes = result['privileged_reauth_minutes']
      raise Exceptions::Forbidden unless minutes.is_a?(Integer) && (5..120).cover?(minutes) &&
        Wasalx::SessionAssurance.authoritative_mfa?(assurance, policy)
      raise ReauthenticationRequired if Time.now.to_i - assurance['auth_time'] > minutes * 60
    end
    actor
  end

  def ticket_groups
    Group.where(id: @actor.group_ids_access('create'), active: true).order(:name)
  end

  def ticket_owners(group_id)
    User.where(active: true).joins(roles: :permissions).where(permissions: { name: 'ticket.agent' }).distinct.order(:id).select do |user|
      !Wasalx::ServiceIdentity.automation?(user) && user.group_access?(group_id, 'full')
    end.tap { |rows| raise ArgumentError if rows.length > 1000 }
  end

  def ticket_states
    %w[open closed].filter_map do |name|
      state = Ticket::State.find_by(name: name, active: true)
      { id: state.id.to_s, name: state.name, closed: state.state_type.name == 'closed' } if state
    end
  end

  def privacy_target
    keys!(%w[scope_type reference expected_sha256])
    type = @input['scope_type']
    reference = @input['reference']
    raise ArgumentError unless reference.is_a?(String) && reference.bytesize <= 320 && !reference.match?(/[[:cntrl:]]/)
    if type == 'ZAMMAD_TICKET'
      raise ArgumentError unless reference.match?(/\A[0-9]{1,32}\z/)
      # Same exact friendly-number read scope as Inbox LIST; never interpret as ID.
      candidates = TicketPolicy::ReadScope.new(@actor).resolve.where(group_id: @actor.group_ids_access('read'), number: reference).limit(2).to_a
      raise Exceptions::Forbidden unless candidates.length == 1 && TicketPolicy.new(@actor, candidates.first).show?
      target = candidates.first
      display = "##{target.number}"
    elsif type == 'ZAMMAD_USER'
      reference = EmailHelper::Idn.to_unicode(reference).downcase.strip
      raise ArgumentError unless EmailAddressValidation.new(reference).valid?
      # Exact identity only. Multiple identities or staff/service overlap fail closed.
      candidates = User.where('LOWER(email) = ?', reference).order(:id).limit(2).to_a
      raise Exceptions::Forbidden unless candidates.length == 1
      target = inline_customer_allowed!(candidates.first)
      display = [target.fullname, target.email].compact.join(' -+ ')
    else
      raise ArgumentError
    end
    snapshot = [@envelope['tenant_id'], @envelope['instance_id'], @envelope['actor'], type, reference,
      target.id.to_s, target.created_at.utc.iso8601(6)]
    digest = Digest::SHA256.hexdigest(JSON.generate(snapshot))
    if @input.key?('expected_sha256')
      raise Conflict unless @input['expected_sha256'].is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(digest, @input['expected_sha256'])
    end
    { scope_type: type, scope_value: target.id.to_s, display: display, selection_sha256: digest }
  end

  def create_options
    keys!(%w[group_id query])
    groups = ticket_groups.to_a
    selected = @input['group_id'] ? groups.find { |group| group.id == positive!(@input['group_id']) } : groups.first
    raise Exceptions::Forbidden if @input['group_id'] && !selected
    query = @input.fetch('query', '')
    raise ArgumentError unless query.is_a?(String) && query.length <= 160 && !query.match?(/[[:cntrl:]]/)
    customers = []
    if groups.any? && query.strip.length >= 2
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query.strip)}%"
      candidates = User.where(active: true).joins(roles: :permissions).where(permissions: { name: 'ticket.customer' })
        .where('users.firstname ILIKE :q OR users.lastname ILIKE :q OR users.email ILIKE :q', q: pattern).distinct.order(:id).limit(25)
      customers = candidates.filter_map do |user|
        next unless UserPolicy.new(@actor, user).show? && !Wasalx::ServiceIdentity.automation?(user)
        { id: user.id.to_s, name: user.fullname, email: user.email }
      end
    end
    { can_create: groups.any?, groups: groups.map { |group| { id: group.id.to_s, name: group.name } },
      owners: selected ? ticket_owners(selected.id).map { |user| { id: user.id.to_s, name: user.fullname } } : [],
      states: ticket_states, customers: customers,
      upload_constraints: ticket_upload_constraints,
      channels: { note: groups.any?, email: Wasalx::PortalEmailSender.available?(selected) } }
  end

  def article_text(article)
    return '' if Wasalx::PortalMailDelivery.notice?(article)
    body = article.body.to_s
    article.content_type == 'text/html' ? CGI.unescapeHTML(ActionController::Base.helpers.strip_tags(body)) : body
  end

  def article_preview(body)
    return body if body.length <= ARTICLE_PREVIEW_LIMIT

    length = 0
    body.each_grapheme_cluster do |cluster|
      break if length + cluster.length > ARTICLE_PREVIEW_LIMIT

      length += cluster.length
    end
    body[0, length]
  end

  def source_context
    keys!(%w[ticket_id article_id])
    values = group_workspace.ticket_sources(ticket_id: @input['ticket_id'], article_ids: [@input['article_id']])
    raise ActiveRecord::RecordNotFound if values.empty?
    raise Conflict unless values.length == 1
    @actor = resolve_actor!
    article = Ticket::Article.find(positive!(@input['article_id']))
    raise Exceptions::Forbidden unless article.ticket_id.to_s == @input['ticket_id'] &&
      TicketPolicy.new(@actor, article.ticket).agent_read_access? && Ticket::ArticlePolicy.new(@actor, article).show?
    values.first.slice('group_id', 'message_id')
  end

  def article_content
    keys!(%w[ticket_id article_id offset limit expected_sha256])
    ticket = ticket!
    article = Ticket::Article.find(positive!(@input['article_id']))
    raise Exceptions::Forbidden unless article.ticket_id == ticket.id && Ticket::ArticlePolicy.new(@actor, article).show?
    offset = @input.fetch('offset', 0)
    limit = @input.fetch('limit', 50_000)
    raise ArgumentError unless offset.is_a?(Integer) && offset >= 0 && limit.is_a?(Integer) && (1..50_000).cover?(limit)
    body = article_text(article)
    raise ArgumentError if offset > body.length
    digest = Digest::SHA256.hexdigest(body)
    expected = @input['expected_sha256']
    raise ArgumentError if offset > 0 && expected.nil?
    raise ArgumentError if expected && (!expected.is_a?(String) || !expected.match?(/\A[a-f0-9]{64}\z/))
    raise Conflict if expected && expected != digest
    text = body[offset, limit] || ''
    following = offset + text.length
    { article_id: article.id.to_s, body: text, body_sha256: digest, total_characters: body.length,
      next_offset: following < body.length ? following : nil }
  end

  def ticket_uploads!
    limits = ticket_upload_constraints
    ids = @input.fetch('attachment_ids', [])
    raise ArgumentError unless ids.is_a?(Array) && ids.length <= limits.fetch(:maximum_files) && ids.uniq.length == ids.length
    ids = ids.map { |id| positive!(id).to_s }
    form = @input['form_id']
    raise ArgumentError if ids.any? && form.nil?
    return {} if form.nil?
    raise ArgumentError unless form.is_a?(String) && Wasalx::PortalDelegation::UUID.match?(form)
    Wasalx::PortalUploadExpiry.lock!(@actor.id, form)
    files = UploadCache.new(form).attachments(created_by_id: @actor.id)
    raise ArgumentError unless files.all? { |file| Wasalx::PortalUploadExpiry.fresh?(file) }
    raise Exceptions::Forbidden unless files.map { |file| file.id.to_s }.sort == ids.sort
    target = @envelope['operation'] == 'CREATE_TICKET' ?
      { 'kind' => 'CREATE_GROUP', 'id' => positive!(@input['group_id']).to_s } :
      { 'kind' => 'TICKET', 'id' => positive!(@input['ticket_id']).to_s }
    raise Exceptions::Forbidden unless files.all? { |file| file.preferences['Wasalx-Portal-Target'] == target }
    sizes = files.map { |file| attachment_size(file) }
    raise ArgumentError if sizes.any? { |size| size > limits.fetch(:maximum_file_bytes) } || sizes.sum > limits.fetch(:maximum_total_bytes)
    { form_id: form }
  end

  def lock_operation!(operation)
    Ticket.connection.execute("SELECT pg_advisory_xact_lock(#{Digest::SHA256.hexdigest(operation)[0, 15].to_i(16)})")
  end

  def creation_binding
    { tenant_id: @envelope.fetch('tenant_id'), instance_id: @envelope.fetch('instance_id'), operation_id: operation_id! }
  end

  def bound_creation!(row)
    raise Conflict unless %w[CREATE_TICKET CANCELLED_CREATE_TICKET].include?(row.kind) &&
      row.portal_user_id == @envelope['actor']['user_id'] && row.native_user_id == @actor.id &&
      creation_binding.all? { |key, value| row.result[key.to_s] == value }
  end

  def create_receipt
    keys!(%w[operation_id action])
    action = @input.fetch('action', 'LOOKUP')
    raise ArgumentError unless %w[LOOKUP CANCEL_IF_UNADMITTED].include?(action)
    operation = operation_id!
    Ticket.transaction do
      lock_operation!(operation)
      row = WasalxTicketOperation.find_by(operation_id: operation)
      if row
        bound_creation!(row)
        if row.kind == 'CREATE_TICKET'
          ticket = Ticket.find(row.ticket_id)
          raise Exceptions::Forbidden unless TicketPolicy.new(@actor, ticket).agent_read_access?
          article = Ticket::Article.find(row.result.fetch('article_id'))
          raise Conflict unless article.ticket_id == ticket.id
        end
        next row.result
      end
      next creation_binding.merge(state: 'UNKNOWN') if action == 'LOOKUP'
      raise Exceptions::Forbidden unless ticket_groups.exists?
      result = creation_binding.merge(state: 'NOT_APPLIED', effect: 'NONE', terminal: true)
      WasalxTicketOperation.create!(operation_id: operation, portal_user_id: @envelope['actor']['user_id'],
        native_user_id: @actor.id, ticket_id: nil, kind: 'CANCELLED_CREATE_TICKET',
        request_sha256: Wasalx::ServiceIdentity.digest(result), result: result)
      result
    end
  end

  def inline_customer_allowed!(customer)
    policy = UserPolicy.new(@actor, customer)
    raise Conflict unless customer.active && customer.id != 1 && customer.permissions?('ticket.customer') &&
      !customer.permissions?(['ticket.agent', 'admin.*']) && !Wasalx::ServiceIdentity.automation?(customer) &&
      policy.show? && policy.update?
    customer
  end

  def ticket_customer!
    raise ArgumentError if @input.key?('customer_id') == @input.key?('customer')
    return User.find(positive!(@input['customer_id'])).lock! if @input.key?('customer_id')
    input = @input['customer']
    raise ArgumentError unless input.is_a?(Hash) && (input.keys - %w[email name]).empty?
    address = input['email']
    name = input.fetch('name', '')
    raise ArgumentError unless address.is_a?(String) && address.bytesize <= 320 && !address.match?(/[[:cntrl:]]/) &&
      name.is_a?(String) && name.length <= 100 && !name.match?(/[[:cntrl:]]/)
    email = EmailHelper::Idn.to_unicode(address).downcase.strip
    raise ArgumentError unless email.bytesize <= 320 && EmailAddressValidation.new(email).valid?
    raise Conflict if EmailAddress.where('LOWER(email) = ?', email).exists?
    lock_operation!("wasalx:customer-email:#{@envelope.fetch('tenant_id')}:#{email}")
    matches = User.where('LOWER(email) = ?', email).order(:id).limit(2).lock('FOR SHARE').to_a
    raise Conflict if matches.length > 1
    return inline_customer_allowed!(matches.first) if matches.any?
    role_ids = Role.signup_role_ids
    roles = Role.where(id: role_ids, active: true).to_a
    raise Conflict unless roles.length == role_ids.uniq.length && roles.any? { |role| role.with_permission?('ticket.customer') } &&
      roles.none? { |role| role.with_permission?(['admin', 'ticket.agent', 'wasalx_service']) }
    customer = User.new(login: email, email: email, firstname: name.strip, lastname: '', active: true,
      password: '', role_ids: role_ids, created_by_id: @actor.id, updated_by_id: @actor.id)
    customer.screen = 'create'
    begin
      User.transaction(requires_new: true) { customer.save! }
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      # Native ingestion can win without the portal email lock; recover outside its savepoint.
      matches = User.where('LOWER(email) = ?', email).order(:id).limit(2).lock('FOR SHARE').to_a
      raise Conflict unless matches.length == 1
      customer = matches.first
    end
    matches = User.where('LOWER(email) = ?', email).order(:id).limit(2).lock('FOR SHARE').to_a
    raise Conflict unless matches.length == 1 && matches.first.id == customer.id && customer.email == email
    inline_customer_allowed!(customer)
  end

  def create_ticket
    keys!(%w[operation_id title group_id customer_id customer owner_id state_id body internal form_id attachment_ids])
    operation = operation_id!
    digest = Wasalx::ServiceIdentity.digest({ operation: 'CREATE_TICKET', input: @input })
    Transaction.execute do
      lock_operation!(operation)
      row = WasalxTicketOperation.find_by(operation_id: operation)
      if row
        bound_creation!(row)
        next row.result if row.kind == 'CANCELLED_CREATE_TICKET'
        raise Conflict unless row.request_sha256 == digest
        existing = Ticket.find(row.ticket_id)
        raise Exceptions::Forbidden unless TicketPolicy.new(@actor, existing).agent_read_access?
        next row.result
      end
      title = @input['title']
      body = @input['body']
      internal = @input['internal']
      raise ArgumentError unless title.is_a?(String) && title.strip.length.between?(1, 200) &&
        !title.match?(/[[:cntrl:]]/) && body.is_a?(String) && body.length <= 4096 &&
        (!body.strip.empty? || Array(@input['attachment_ids']).any?) && !body.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/) && [true, false].include?(internal)
      group = Group.find(positive!(@input['group_id']))
      raise Exceptions::Forbidden unless group.active && TicketPolicy.new(@actor, Ticket.new(group_id: group.id)).create?
      email_sender = Wasalx::PortalEmailSender.lock!(group) unless internal
      group = email_sender.group if email_sender
      customer = ticket_customer!
      raise Exceptions::Forbidden unless group.active && customer.active && customer.permissions?('ticket.customer') &&
        !Wasalx::ServiceIdentity.automation?(customer) && UserPolicy.new(@actor, customer).show?
      state = Ticket::State.find(positive!(@input['state_id']))
      raise ArgumentError unless state.active && %w[open closed].include?(state.state_type.name)
      attributes = { title: title.strip, group_id: group.id, customer_id: customer.id, state_id: state.id,
        created_by_id: @actor.id, updated_by_id: @actor.id }
      owner = @input['owner_id'] ? positive!(@input['owner_id']) : 1
      attributes[:owner_id] = owner
      if owner != 1
        selected = User.find(owner)
        raise Exceptions::Forbidden unless selected.active && selected.permissions?('ticket.agent') &&
          !Wasalx::ServiceIdentity.automation?(selected) && selected.group_access?(group.id, 'full')
      end
      ticket = Ticket.new(attributes)
      ticket.screen = 'create_middle'
      raise Exceptions::Forbidden unless TicketPolicy.new(@actor, ticket).create?
      article_attributes = { body: body, content_type: 'text/plain', internal: internal, sender: 'Agent',
        type: internal ? 'note' : 'email' }.merge(ticket_uploads!)
      unless internal
        raise ArgumentError unless EmailAddressValidation.new(customer.email).valid? &&
          !EmailAddress.where('lower(email) = ?', customer.email.downcase).exists?
        article_attributes.merge!(to: customer.email, subject: ticket.title)
      end
      ticket.save!
      article = ArticleWriter.new(@actor).call(ticket, article_attributes)
      Wasalx::PortalEmailSender.assert_native_binding!(article, email_sender) if email_sender
      result = creation_binding.merge(state: 'APPLIED', ticket_id: ticket.id.to_s,
        ticket_number: ticket.number.to_s, article_id: article.id.to_s)
      WasalxTicketOperation.create!(operation_id: operation, portal_user_id: @envelope['actor']['user_id'],
        native_user_id: @actor.id, ticket_id: ticket.id, kind: 'CREATE_TICKET', request_sha256: digest, result: result)
      result
    end
  end

  def reply_draft!
    body = @input['body']
    internal = @input['internal']
    raise ArgumentError unless [true, false].include?(internal) && body.is_a?(String) &&
      body.length <= 4096 && (!body.strip.empty? || Array(@input['attachment_ids']).any?) && !body.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)
    [body, internal]
  end

  def preview
    keys!(%w[ticket_id expected_updated_at body internal form_id attachment_ids])
    ticket = ticket!(write: true)
    version = ticket.updated_at.utc.iso8601(6)
    raise Conflict unless @input['expected_updated_at'] == version
    body, internal = reply_draft!
    uploads = ticket_uploads!
    raise Exceptions::Forbidden unless TicketPolicy.new(@actor, ticket).follow_up?
    attachment_binding = uploads.empty? ? [] : UploadCache.new(uploads.fetch(:form_id)).attachments(created_by_id: @actor.id).map do |file|
      { id: file.id.to_s, name: file.filename, size: attachment_size(file), mime_type: file.preferences['Content-Type'],
        sha256: file.preferences['Wasalx-Portal-SHA256'] }
    end
    snapshot = { ticket_id: ticket.id.to_s, ticket_updated_at: version, body: body, internal: internal,
      form_id: @input['form_id'], attachment_ids: @input.fetch('attachment_ids', []), attachments: attachment_binding }
    channel_name = internal ? 'internal_note' : channel(ticket)
    handover = !internal && channel_name == 'whatsapp' && !reply_allowed?(ticket)
    output = { draft_sha256: Wasalx::ServiceIdentity.digest(snapshot), ticket_updated_at: version,
      channel: channel_name, text: nil, recipient: nil, team: ticket.group.name,
      quoted: false, can_send: false, handover_required: handover, routing_notice: 'UNAVAILABLE' }
    if internal
      output.merge!(text: body, can_send: true, routing_notice: 'INTERNAL_ONLY')
    elsif handover
      output[:routing_notice] = 'HANDOVER_REQUIRED'
    elsif channel_name == 'email' && reply_allowed?(ticket)
      attributes = email_reply_attributes(ticket)
      output.merge!(text: body, recipient: attributes.fetch(:to), quoted: attributes[:in_reply_to].present?,
        can_send: true, routing_notice: 'EMAIL')
    elsif channel_name == 'whatsapp'
      prepared = Wasalx::ReplyPreview.new(actor: @actor).call(ticket_id: ticket.id.to_s, body: body,
        internal: false, has_attachments: attachment_binding.any?)
      raise ArgumentError unless prepared.is_a?(Hash) && prepared['text'].is_a?(String) && prepared['text'].length <= 65_536
      direct = ticket.wasalx_bot_conversation.to_s == 'true' || ticket.wasalx_bot_state.present?
      recipient = direct ? ticket.customer&.fullname : ticket.wasalx_group_name.presence || ticket.customer&.fullname
      output.merge!(text: prepared['text'], recipient: recipient, quoted: prepared['replyToMessageId'].present?,
        can_send: true, routing_notice: 'WHATSAPP')
    end
    ticket.reload
    current = User.find(@actor.id)
    Wasalx::MembershipAccess.check!(current)
    raise Exceptions::Forbidden unless current.active && TicketPolicy.new(current, ticket).agent_update_access?
    raise Conflict unless ticket.updated_at.utc.iso8601(6) == version
    current_files = uploads.empty? ? [] : UploadCache.new(uploads.fetch(:form_id)).attachments(created_by_id: @actor.id).map do |file|
      { id: file.id.to_s, name: file.filename, size: attachment_size(file), mime_type: file.preferences['Content-Type'],
        sha256: file.preferences['Wasalx-Portal-SHA256'] }
    end
    raise Conflict unless current_files == attachment_binding
    if !internal && channel_name == 'email' && !Wasalx::PortalEmailSender.available?(ticket.group)
      output.merge!(text: nil, recipient: nil, quoted: false, can_send: false, routing_notice: 'UNAVAILABLE')
    end
    output
  end

  def keys!(allowed)
    raise ArgumentError unless (@input.keys - allowed).empty?
  end

  def positive!(value)
    raise ArgumentError unless value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,15}\z/)
    value.to_i
  end

  def ticket!(write: false)
    ticket = Ticket.find(positive!(@input['ticket_id']))
    policy = TicketPolicy.new(@actor, ticket)
    allowed = write ? policy.agent_update_access? : policy.agent_read_access?
    raise Exceptions::Forbidden unless allowed
    ticket
  end

  def page_limit
    value = @input.fetch('limit', 50)
    raise ArgumentError unless value.is_a?(Integer) && (1..100).cover?(value)
    value
  end

  def list
    keys!(%w[before limit query state ticket_number])
    # ReadScope can include customer tickets for mixed native roles; keep staff queues explicit.
    scope = TicketPolicy::ReadScope.new(@actor).resolve.where(group_id: @actor.group_ids_access('read'))
    if @input['ticket_number']
      raise ArgumentError unless @input['ticket_number'].is_a?(String) && @input['ticket_number'].match?(/\A[0-9]{1,32}\z/)
      scope = scope.where(number: @input['ticket_number'])
    end
    if @input['query']
      query = @input['query']
      raise ArgumentError unless query.is_a?(String) && query.length <= 160
      escaped = ActiveRecord::Base.sanitize_sql_like(query)
      scope = scope.where('tickets.title ILIKE ? OR tickets.number ILIKE ?', "%#{escaped}%", "%#{escaped}%")
    end
    if @input['state']
      raise ArgumentError unless %w[open closed].include?(@input['state'])
      types = @input['state'] == 'closed' ? ['closed'] : ['new', 'open', 'pending reminder', 'pending action']
      scope = scope.where(state_id: Ticket::State.where(state_type_id: Ticket::StateType.where(name: types).select(:id)).select(:id))
    end
    scope = scope.where('tickets.id < ?', positive!(@input['before'])) if @input['before']
    rows = scope.order(id: :desc).limit(page_limit + 1).to_a
    { items: rows.first(page_limit).map { |ticket| ticket_summary(ticket) },
      next_cursor: rows.length > page_limit ? rows[page_limit - 1].id.to_s : nil }
  end

  def ticket_summary(ticket)
    { id: ticket.id.to_s, number: ticket.number, title: ticket.title, updated_at: ticket.updated_at.utc.iso8601(6),
      state: ticket.state.name, closed: ticket.state.state_type.name == 'closed',
      team: ticket.group.name, team_id: ticket.group_id.to_s, owner: ticket.owner&.fullname,
      owner_id: ticket.owner_id.to_s, customer: ticket.customer&.fullname,
      channel: channel(ticket) }
  end

  def show
    keys!(%w[ticket_id group_id])
    ticket = ticket!
    writable = TicketPolicy.new(@actor, ticket).agent_update_access?
    group_id = @input['group_id'] ? positive!(@input['group_id']) : ticket.group_id
    if group_id != ticket.group_id
      target = Group.find(group_id)
      raise Exceptions::Forbidden unless writable && target.active && TicketPolicy.new(@actor, Ticket.new(group_id: group_id)).create?
    end
    owners = writable ? ticket_owners(group_id) : []
    ticket_summary(ticket).merge(can_update: writable, can_reply: writable && reply_allowed?(ticket),
      owner_team_id: group_id.to_s, owners: owners.map { |user| { id: user.id.to_s, name: user.fullname } },
      teams: writable ? ticket_groups.map { |group| { id: group.id.to_s, name: group.name } } : [],
      states: ticket_states, upload_constraints: ticket_upload_constraints,
      recipient_delivery: channel(ticket) == 'email' ? Wasalx::PortalMailDelivery.recipient(ticket.customer) : nil)
  end

  def articles
    keys!(%w[ticket_id before limit])
    ticket = ticket!
    scope = Ticket::Article.where(ticket_id: ticket.id)
    scope = scope.where('id < ?', positive!(@input['before'])) if @input['before']
    rows = scope.order(id: :desc).limit([page_limit, 20].min + 1).to_a
    # Bound UTF-8 bytes as well as characters so Arabic pages fit the bridge limit.
    count = [page_limit, 20].min
    visible = rows.first(count).select { |article| Ticket::ArticlePolicy.new(@actor, article).show? }
    sources = if visible.any? && ticket.wasalx_connection_id.present? && ticket.wasalx_group_id.present?
                group_workspace.ticket_sources(ticket_id: ticket.id.to_s, article_ids: visible.map { |article| article.id.to_s }, optional: true) { |current| visible = current }
              else
                []
              end
    { items: visible.map do |article|
        body = article_text(article)
        preview = article_preview(body)
        { id: article.id.to_s, **(sources ? { has_source: sources.any? { |source| source['article_id'] == article.id.to_s } } : {}), body: preview, body_complete: preview.length == body.length,
          total_characters: body.length, body_sha256: Digest::SHA256.hexdigest(body), internal: article.internal,
          author: article.from.presence || article.created_by&.fullname, sender: article.sender.name,
          delivery: Wasalx::PortalMailDelivery.article(article),
          created_at: article.created_at.utc.iso8601(6), attachments: article.attachments.map do |attachment|
            { id: attachment.id.to_s, filename: attachment.filename, size: attachment_size(attachment) }
          end }
      end,
      next_cursor: rows.length > count ? rows[count - 1].id.to_s : nil }
  end

  def reply_allowed?(ticket)
    return channel(ticket) == 'email' && Wasalx::PortalEmailSender.available?(ticket.group) unless ticket.wasalx_connection_id.present?
    direct = ticket.wasalx_bot_conversation.to_s == 'true' || ticket.wasalx_bot_state.present?
    !direct || ticket.wasalx_bot_state == 'HUMAN' ||
      (ticket.wasalx_bot_state == 'BOT' && ticket.wasalx_bot_keep_open == 'true')
  end

  def attachment
    keys!(%w[ticket_id article_id attachment_id])
    ticket = ticket!
    article = Ticket::Article.find(positive!(@input['article_id']))
    raise Exceptions::Forbidden unless article.ticket_id == ticket.id && Ticket::ArticlePolicy.new(@actor, article).show?
    file = article.attachments.find { |item| item.id == positive!(@input['attachment_id']) }
    raise ActiveRecord::RecordNotFound unless file
    size = attachment_size(file)
    raise ArgumentError if size > 50_000_000
    content = file.content
    raise ArgumentError unless content.bytesize == size
    @actor = resolve_actor!
    raise Exceptions::Forbidden unless TicketPolicy.new(@actor, ticket.reload).agent_read_access? && Ticket::ArticlePolicy.new(@actor, article.reload).show?
    Attachment.new(content, file.filename)
  end

  def attachment_size(file)
    value = file.size.to_s
    raise ArgumentError unless value.match?(/\A[0-9]+\z/)
    size = Integer(value, 10)
    size
  end

  def channel(ticket)
    return 'whatsapp' if ticket.wasalx_connection_id.present?
    first = Ticket::Article.where(ticket_id: ticket.id, internal: false).order(:id).first
    first&.type&.name == 'email' ? 'email' : 'other'
  end

  def operation_id!
    id = @input['operation_id']
    raise ArgumentError unless id.is_a?(String) && Wasalx::PortalDelegation::UUID.match?(id)
    id.downcase
  end

  def receipt
    keys!(%w[ticket_id operation_id action])
    action = @input.fetch('action', 'LOOKUP')
    raise ArgumentError unless %w[LOOKUP CANCEL_IF_UNADMITTED].include?(action)
    ticket = ticket!(write: action == 'CANCEL_IF_UNADMITTED')
    operation = operation_id!
    Ticket.transaction do
      lock_operation!(operation)
      row = WasalxTicketOperation.find_by(operation_id: operation)
      if row
        raise Conflict unless %w[REPLY UPDATE CANCELLED].include?(row.kind) && row.portal_user_id == @envelope['actor']['user_id'] &&
          row.native_user_id == @actor.id && row.ticket_id == ticket.id
        next row.result
      end
      next({ state: 'UNKNOWN', ticket_id: ticket.id.to_s, operation_id: operation }) if action == 'LOOKUP'
      # A terminal tombstone fences a delayed original request after a crash-before-send.
      result = { state: 'NOT_APPLIED', ticket_id: ticket.id.to_s, operation_id: operation, terminal: true }
      WasalxTicketOperation.create!(operation_id: operation, portal_user_id: @envelope['actor']['user_id'],
        native_user_id: @actor.id, ticket_id: ticket.id, kind: 'CANCELLED',
        request_sha256: Wasalx::ServiceIdentity.digest(result), result: result)
      result
    end
  end

  def mutate
    kind = @envelope.fetch('operation')
    keys!(kind == 'REPLY' ? %w[ticket_id operation_id expected_updated_at body internal form_id attachment_ids] :
      %w[ticket_id operation_id expected_updated_at state_id owner_id group_id])
    ticket = ticket!(write: true)
    operation = operation_id!
    digest = Wasalx::ServiceIdentity.digest({ operation: kind, input: @input })
    Transaction.execute do
      lock_operation!(operation)
      existing = WasalxTicketOperation.find_by(operation_id: operation)
      if existing
        raise Conflict unless existing.portal_user_id == @envelope['actor']['user_id'] &&
          existing.native_user_id == @actor.id && existing.ticket_id == ticket.id &&
          existing.kind == kind && existing.request_sha256 == digest
        next existing.result
      end
      ticket.lock!
      raise Exceptions::Forbidden unless TicketPolicy.new(@actor, ticket).agent_update_access?
      raise Conflict unless @input['expected_updated_at'] == ticket.updated_at.utc.iso8601(6)
      result = (kind == 'REPLY' ? reply(ticket) : update_ticket(ticket)).merge(state: 'APPLIED')
      WasalxTicketOperation.create!(operation_id: operation, portal_user_id: @envelope['actor']['user_id'],
        native_user_id: @actor.id, ticket_id: ticket.id, kind: kind, request_sha256: digest, result: result)
      result
    end
  end

  def email_reply_attributes(ticket)
    incoming = ticket.articles.where(internal: false,
      type_id: Ticket::Article::Type.find_by!(name: 'email').id,
      sender_id: Ticket::Article::Sender.find_by!(name: 'Customer').id).reorder(created_at: :desc, id: :desc).first
    reference = incoming || ticket.articles.where(internal: false,
      type_id: Ticket::Article::Type.find_by!(name: 'email').id,
      sender_id: Ticket::Article::Sender.find_by!(name: 'Agent').id).reorder(created_at: :desc, id: :desc).first
    raise ArgumentError unless reference
    recipient_header = incoming ? incoming.reply_to.presence || incoming.from : reference.to
    recipients = Mail::AddressList.new(recipient_header).addresses.map(&:address)
    system_addresses = EmailAddress.pluck(:email).map(&:downcase)
    recipients.reject! { |address| system_addresses.include?(address.downcase) }
    raise ArgumentError if recipients.empty? || recipients.any? { |address| !EmailAddressValidation.new(address).valid? }
    message_id = reference.message_id.to_s
    raise ArgumentError if message_id.bytesize > 998 || message_id.match?(/[\r\n\x00]/)
    { to: recipients.join(', '), subject: reference.subject.presence || ticket.title,
      in_reply_to: message_id.presence }
  rescue Mail::Field::ParseError
    raise ArgumentError
  end

  def reply(ticket)
    body, internal = reply_draft!
    raise Exceptions::Forbidden unless internal || reply_allowed?(ticket)
    raise Exceptions::Forbidden unless TicketPolicy.new(@actor, ticket).follow_up?
    email_sender = Wasalx::PortalEmailSender.lock!(ticket.group) if !internal && channel(ticket) == 'email'
    ticket.association(:group).target = email_sender.group if email_sender
    attributes = { body: body, content_type: 'text/plain', internal: internal, sender: 'Agent',
      type: internal ? 'note' : ticket.wasalx_connection_id.present? ? 'wasalx group message' : 'email' }.merge(ticket_uploads!)
    attributes.merge!(email_reply_attributes(ticket)) if attributes[:type] == 'email'
    article = ArticleWriter.new(@actor).call(ticket, attributes)
    Wasalx::PortalEmailSender.assert_native_binding!(article, email_sender) if email_sender
    { ticket_id: ticket.id.to_s, article_id: article.id.to_s, operation_id: @input['operation_id'] }
  rescue Mail::Field::ParseError
    raise ArgumentError
  end

  def update_ticket(ticket)
    raise ArgumentError unless %w[owner_id state_id group_id].any? { |key| @input.key?(key) }
    changes = { updated_by_id: @actor.id }
    group_id = @input['group_id'] ? positive!(@input['group_id']) : ticket.group_id
    if group_id != ticket.group_id
      target = Group.find(group_id)
      raise Exceptions::Forbidden unless target.active && TicketPolicy.new(@actor, Ticket.new(group_id: group_id)).create?
      changes[:group_id] = group_id
      changes[:owner_id] = 1 unless @input.key?('owner_id')
    end
    if @input['owner_id']
      owner_id = positive!(@input['owner_id'])
      if owner_id != 1
        owner = User.find(owner_id)
        raise Exceptions::Forbidden unless owner.active && owner.permissions?('ticket.agent') &&
          !Wasalx::ServiceIdentity.automation?(owner) && owner.group_access?(group_id, 'full')
      end
      changes[:owner_id] = owner_id
    end
    if @input['state_id']
      state = Ticket::State.find(positive!(@input['state_id']))
      raise ArgumentError unless state.active && %w[open closed].include?(state.state_type.name)
      changes[:state_id] = state.id
    end
    ticket.screen = 'edit'
    ticket.update!(changes)
    raise Conflict if changes.key?(:owner_id) && ticket.owner_id != changes[:owner_id]
    { ticket_id: ticket.id.to_s, operation_id: @input['operation_id'], updated_at: ticket.updated_at.utc.iso8601(6) }
  end
end
