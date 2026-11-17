# SPDX-License-Identifier: AGPL-3.0-only
require 'digest'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require_relative 'native_identifiers'
require_relative 'portal_upload_expiry'

module Wasalx
  class GroupWorkspace
    include NativeIdentifiers
    UNSET = Object.new.freeze
    FileResult = Struct.new(:data, :filename, :content_type, :disposition, keyword_init: true)
    TicketResult = Struct.new(:data, :created, keyword_init: true)

    def initialize(actor:)
      @actor = User.find(actor.id)
    end

    def self.actor_claims(actor)
      { user_id: actor.id, group_ids: actor.group_ids_access('read'),
        group_admin: actor.permissions?('admin') }
    end

    def groups(limit: nil, after: nil, selected: nil, scope: nil)
      ensure_agent!
      limit = bounded_limit!(limit)
      after = after.present? ? uuid!(after, 'group cursor') : nil
      selected = selected.present? ? uuid!(selected, 'selected group') : nil
      scope = scope.to_s.upcase.presence || 'ALL'
      raise ActionController::BadRequest, __('Invalid group scope') if !%w[MY TEAM UNASSIGNED ALL].include?(scope)

      query = { limit: limit, after: after, selected: selected, scope: scope }.compact.to_query
      Wasalx::Client.get("/internal/v1/zammad/group-workspace/groups?#{query}", scope: 'zammad:groups', actor: group_actor)
    end

    def messages(group_id:, limit: nil, before: nil)
      ensure_agent!
      group_id = uuid!(group_id, 'group')
      limit = bounded_limit!(limit)
      before = before.present? ? uuid!(before, 'message cursor') : nil
      query = { limit: limit, before: before }.compact.to_query
      Wasalx::Client.get("/internal/v1/zammad/group-workspace/groups/#{group_id}/messages?#{query}", scope: 'zammad:groups', actor: group_actor)
    end

    def participants(group_id:, q: nil)
      ensure_agent!
      group_id = uuid!(group_id, 'group')
      query = { q: q.to_s }.to_query
      Wasalx::Client.get("/internal/v1/zammad/group-workspace/groups/#{group_id}/participants?#{query}", scope: 'zammad:groups', actor: group_actor)
    end

    def context(group_id:, message_id:)
      ensure_agent!
      group_id = uuid!(group_id, 'group')
      message_id = uuid!(message_id, 'message')
      Wasalx::Client.get("/internal/v1/zammad/group-workspace/groups/#{group_id}/messages/#{message_id}/context", scope: 'zammad:groups', actor: group_actor)
    end

    def ticket_sources(ticket_id:, article_ids:, optional: false)
      id = positive_identifier!(ticket_id, 'ticket')
      raise ActionController::BadRequest, __('Invalid source articles') unless article_ids.is_a?(Array) && article_ids.length.between?(1, 20)
      ids = article_ids.map { |value| positive_identifier!(value, 'article') }
      raise ActionController::BadRequest, __('Invalid source articles') unless ids.uniq.length == ids.length
      authorize_sources = lambda do
        @actor = User.find(@actor.id)
        ensure_agent!
        ticket = Ticket.find(id)
        raise Exceptions::Forbidden unless TicketPolicy.new(@actor, ticket).agent_read_access?
        rows = Ticket::Article.where(ticket_id: ticket.id, id: ids).to_a
        raise Exceptions::Forbidden unless rows.length == ids.length
        by_id = rows.to_h { |article| [article.id.to_s, article] }
        articles = ids.map { |article_id| by_id.fetch(article_id) }
        articles.each { |article| article.association(:ticket).target = ticket }
        raise Exceptions::Forbidden unless articles.all? { |article| Ticket::ArticlePolicy.new(@actor, article).show? }
        articles
      end
      authorize_sources.call
      unavailable = nil
      query = { article_ids: ids.join(',') }.to_query
      result = begin
        Wasalx::Client.get("/internal/v1/zammad/group-workspace/tickets/#{id}/message-context?#{query}",
          scope: 'zammad:groups', actor: group_actor)
      rescue Wasalx::Client::TemporaryRequestFailed => error
        unavailable = error
        nil
      end
      current_articles = authorize_sources.call
      yield current_articles if block_given?
      if unavailable || result.is_a?(Hash) && result['truncated'] == true
        return nil if optional
        raise(unavailable || Wasalx::Client::TemporaryRequestFailed.new('Source context is incomplete'))
      end
      raise ArgumentError, 'Source context is incomplete' unless result.is_a?(Hash) && result['items'].is_a?(Array) && result['truncated'] == false
      result.fetch('items').map do |value|
        article_id = positive_identifier!(value['article_id'], 'source article')
        raise ArgumentError, 'Source context changed' unless ids.include?(article_id)
        { 'article_id' => article_id, 'group_id' => uuid!(value['group_id'], 'source group'),
          'message_id' => uuid!(value['message_id'], 'source message') }
      end.uniq
    end

    def tickets(group_id:, limit: nil, before: nil)
      ensure_agent!
      group_id = uuid!(group_id, 'group')
      limit = bounded_limit!(limit)
      before = before.present? ? uuid!(before, 'ticket cursor') : nil
      query = { limit: limit, before: before }.compact.to_query
      page = Wasalx::Client.get("/internal/v1/zammad/group-workspace/groups/#{group_id}/tickets?#{query}", scope: 'zammad:groups', actor: group_actor)
      candidates = page.fetch('items')
      grouped = candidates.index_by { |candidate| positive_identifier!(candidate['ticket_id'], 'ticket') }
      ticket_by_id = Ticket.where(id: grouped.keys).index_by { |ticket| ticket.id.to_s }
      open_state_ids = Ticket::State.by_category(:open).pluck(:id)
      closed_state_ids = Ticket::State.by_category(:closed).pluck(:id)
      visible = grouped.filter_map do |ticket_id, candidate|
        ticket = ticket_by_id[ticket_id]
        next if !ticket
        next if !TicketPolicy.new(@actor, ticket).agent_read_access?
        state_category = if open_state_ids.include?(ticket.state_id)
                           'OPEN'
                         elsif closed_state_ids.include?(ticket.state_id)
                           'CLOSED'
                         end
        next if !state_category

        {
          ticket_id: ticket.id.to_s, ticket_number: ticket.number.to_s, reference: ticket.title.to_s,
          state_category: state_category,
          links: candidate.fetch('links', []).filter_map do |link|
            next if link['message_id'].blank?

            { message_id: uuid!(link['message_id'], 'linked message'),
              article_id: link['article_id'].present? ? positive_identifier!(link['article_id'], 'linked article') : nil }
          end.uniq
        }
      end
      { items: visible, next_cursor: page['next_cursor'] }
    end

    def ticket_groups
      ensure_agent!
      groups = Group.where(id: @actor.group_ids_access('create'), active: true).order(:name)
      groups.map { |group| { id: group.id.to_s, name: group.name.to_s } }
    end

    class Conflict < ActionController::BadRequest; end
    class Rejected < ActionController::BadRequest
      attr_reader :result, :status
      def initialize(error, result)
        @result = result
        @status = 400
        super(error.message)
      end
    end
    class RejectedMissing < ActiveRecord::RecordNotFound
      attr_reader :result, :status
      def initialize(error, result)
        @result = result
        @status = 404
        super(error.message)
      end
    end

    def create_ticket(group_id:, message_id:, target_group_id:, request_token:, title: nil)
      binding = group_operation_binding('GROUP_CREATE', group_id, message_id, request_token)
      intent = { 'target_group_id' => positive_identifier!(target_group_id, 'ticket group'),
        'title' => title.to_s.unicode_normalize(:nfc).gsub(/[\p{Cc}\p{Cf}]/, ' ').squeeze(' ').strip }
      data, created = admit_group_operation(binding, intent)
      TicketResult.new(data: data, created: created)
    end

    def link_ticket(group_id:, message_id:, ticket_number:, request_token:)
      binding = group_operation_binding('GROUP_LINK', group_id, message_id, request_token, ticket_number)
      admit_group_operation(binding, {}).first
    end

    def group_receipt(kind:, group_id:, message_id:, request_token:, ticket_number: nil, action: 'LOOKUP')
      raise ActionController::BadRequest, __('Invalid group operation action') unless %w[LOOKUP CANCEL_IF_UNADMITTED].include?(action)
      binding = group_operation_binding(kind, group_id, message_id, request_token, ticket_number)
      authorize_group_operation!(binding)
      source = nil
      row, legacy = Transaction.execute do
        group_operation_lock(binding['operation_id'])
        existing = WasalxTicketOperation.find_by(operation_id: binding['operation_id'])
        if existing
          assert_group_operation!(existing, binding)
          next [existing, nil]
        end
        group_source_lock(binding)
        source = recoverable_group_source(binding)
        found = legacy_group_article(binding, source)
        next [nil, found] if found
        next [nil, nil] if action == 'LOOKUP'
        [cancel_group_operation(binding, 'EXPLICIT_CANCELLATION'), nil]
      end
      return row.result if row && row.result['state'] == 'NOT_APPLIED'
      source ||= recoverable_group_source(binding)
      return project_group_operation(row.result, binding, source) if row
      return project_group_operation(group_native_result(binding, legacy), binding, source) if legacy
      binding.merge('state' => 'UNKNOWN', 'terminal' => false)
    end

    def repair_ticket_link(kind:, group_id:, message_id:, request_token:, ticket_number: nil)
      binding = group_operation_binding(kind, group_id, message_id, request_token, ticket_number)
      authorize_group_operation!(binding)
      source = nil
      result = Transaction.execute do
        group_operation_lock(binding['operation_id'])
        row = WasalxTicketOperation.find_by(operation_id: binding['operation_id'])
        if row
          assert_group_operation!(row, binding)
          next row.result
        end
        group_source_lock(binding)
        source = recoverable_group_source(binding)
        article = legacy_group_article(binding, source)
        article && group_native_result(binding, article)
      end
      return binding.merge('state' => 'UNKNOWN', 'terminal' => false) unless result
      return result if result['state'] == 'NOT_APPLIED'
      source ||= recoverable_group_source(binding)
      projection = project_group_operation(result, binding, source)
      return projection unless projection['state'] == 'PARTIAL' && source
      ticket = Ticket.find(result.fetch('ticket_id'))
      policy = TicketPolicy.new(@actor, ticket)
      allowed = policy.agent_update_access? || (binding['kind'] == 'GROUP_CREATE' && policy.create?)
      raise Exceptions::Forbidden, __('Not authorized') unless allowed
      article = Ticket::Article.find_by!(id: result.fetch('article_id').to_i, ticket_id: ticket.id)
      link_group_message(binding['group_id'], binding['message_id'], article)
      project_group_operation(result, binding, group_message_source(binding['group_id'], binding['message_id']))
    end

    def read(group_id:, message_id:)
      ensure_agent!
      group_id = uuid!(group_id, 'group')
      message_id = uuid!(message_id, 'message')
      Wasalx::Client.post(
        "/internal/v1/zammad/group-workspace/groups/#{group_id}/read",
        { messageId: message_id }, scope: 'zammad:groups', actor: group_actor
      )
    end

    def send_message(group_id:, request_token:, message: nil, reply_to_message_id: nil, mentions: nil, upload_cache_id: nil, upload_store_ids: nil)
      ensure_agent!
      group_id = uuid!(group_id, 'group')
      request_token = uuid!(request_token, 'send request')
      reply_to_message_id = reply_to_message_id.present? ? uuid!(reply_to_message_id, 'quoted message') : nil
      message = message.to_s.gsub(/\r\n?/, "\n").strip
      raise ActionController::BadRequest, __('Invalid message') if message.each_char.count > 4096 || message.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)
      mentions = group_mentions!(mentions)

      uploads = []
      begin
        uploads = stage_group_workspace_uploads(request_token, upload_cache_id: upload_cache_id, upload_store_ids: upload_store_ids, group_id: group_id)
        raise ActionController::BadRequest, __('Invalid message') if message.empty? && uploads.empty?
        result = Wasalx::Client.post(
          "/internal/v1/zammad/group-workspace/groups/#{group_id}/send",
          { message: message, replyToMessageId: reply_to_message_id, agentDisplayName: @actor.fullname,
            attachments: uploads.map { |upload| upload.fetch(:descriptor) },
            mentions: mentions,
            idempotency_key: "group-workspace:#{@actor.id}:#{request_token}" },
          scope: 'zammad:groups', actor: group_actor
        )
        remove_created_workspace_uploads(uploads) if result['duplicate']
        result
      rescue Wasalx::Client::TemporaryRequestFailed
        # The request may already be queued. Keep its stable staged files so an
        # exact replay can retrieve the existing delivery without duplicating it.
        raise
      rescue Wasalx::Client::PermanentRequestFailed
        remove_created_workspace_uploads(uploads)
        raise
      end
    end

    def message_media(group_id:, message_id:)
      ensure_agent!
      group_id = uuid!(group_id, 'group')
      message_id = uuid!(message_id, 'message')
      metadata = Wasalx::Client.get("/internal/v1/zammad/group-workspace/groups/#{group_id}/messages/#{message_id}/media", scope: 'zammad:groups', actor: group_actor)
      maximum = Integer(positive_identifier!(metadata.fetch('byte_size'), 'media size'))
      raise ActionController::BadRequest, __('Invalid media size') if maximum > 50_000_000
      media = Wasalx::Client.download(
        metadata.fetch('url'), maximum,
        expected_content_type: metadata.fetch('mime_type'), expected_sha256: metadata.fetch('sha256')
      )
      FileResult.new(data: media.fetch(:data), filename: metadata.fetch('filename'), content_type: metadata.fetch('mime_type'), disposition: metadata.fetch('mime_type').start_with?('image/', 'audio/', 'video/') ? 'inline' : 'attachment')
    end

    def operation_receipt(group_id:, kind:, request_token:, target_message_id: nil, action: 'LOOKUP')
      ensure_agent!
      group_id = uuid!(group_id, 'group')
      request_token = uuid!(request_token, 'operation request')
      raise ActionController::BadRequest, __('Invalid operation kind') if !%w[SEND REACTION].include?(kind)
      raise ActionController::BadRequest, __('Invalid receipt action') if !%w[LOOKUP CANCEL_IF_UNADMITTED].include?(action)
      if kind == 'REACTION'
        target_message_id = uuid!(target_message_id, 'target message')
      elsif !target_message_id.nil?
        raise ActionController::BadRequest, __('Invalid send target')
      end
      Wasalx::Client.post(
        "/internal/v1/zammad/group-workspace/groups/#{group_id}/operation-receipt",
        { kind: kind, requestId: request_token, targetMessageId: target_message_id, action: action }.compact,
        scope: 'zammad:groups', actor: group_actor
      )
    end

    def reaction(group_id:, message_id:, request_token:, emoji: nil, removed_value: UNSET)
      ensure_agent!
      group_id = uuid!(group_id, 'group')
      message_id = uuid!(message_id, 'message')
      request_token = uuid!(request_token, 'reaction request')
      removed = removed_value == true
      raise ActionController::BadRequest, __('Invalid reaction') if !removed_value.equal?(UNSET) && ![true, false].include?(removed_value)
      emoji = emoji.to_s.unicode_normalize(:nfc)
      raise ActionController::BadRequest, __('Invalid reaction') if removed ? !emoji.empty? : !%w[👍 ❤️ 😂 😮 😢 🙏 ✅].include?(emoji)

      Wasalx::Client.post(
        "/internal/v1/zammad/group-workspace/groups/#{group_id}/messages/#{message_id}/reactions",
        { emoji: emoji, removed: removed, idempotency_key: "group-workspace-reaction:#{@actor.id}:#{request_token}" },
        scope: 'zammad:groups', actor: group_actor
      )
    end

    private

    def group_operation_binding(kind, group_id, message_id, request_token, ticket_number = nil)
      ensure_agent!
      raise ActionController::BadRequest, __('Invalid group operation kind') unless %w[GROUP_CREATE GROUP_LINK].include?(kind)
      raise ActionController::BadRequest, __('Invalid group operation target') if kind == 'GROUP_CREATE' && ticket_number.present?
      membership = WasalxMembership.find_by(user_id: @actor.id)
      binding = { 'schema_version' => 1, 'tenant_id' => ENV.fetch('WASALX_TENANT_ID'),
        'instance_id' => ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'),
        'portal_user_id' => membership ? membership.portal_user_id : "native:#{@actor.id}",
        'native_user_id' => @actor.id.to_s, 'kind' => kind,
        'operation_id' => uuid!(request_token, 'group operation').downcase,
        'group_id' => uuid!(group_id, 'group').downcase,
        'message_id' => uuid!(message_id, 'message').downcase }
      binding['ticket_number'] = positive_identifier!(ticket_number, 'ticket number') if kind == 'GROUP_LINK'
      binding
    end

    def authorize_group_operation!(binding)
      page = groups(limit: 1, selected: binding['group_id'], scope: 'ALL')
      raise Exceptions::Forbidden, __('Not authorized') unless page.fetch('items').any? { |group| group['id'].to_s.downcase == binding['group_id'] }
    end

    def recoverable_group_source(binding)
      group_message_source(binding['group_id'], binding['message_id'])
    rescue Wasalx::Client::PermanentRequestFailed => error
      raise unless error.http_status == 404
      nil
    end

    def group_operation_lock(operation)
      Ticket.connection.execute("SELECT pg_advisory_xact_lock(#{Digest::SHA256.hexdigest(operation)[0, 15].to_i(16)})")
    end

    def group_source_lock(binding)
      target = binding['kind'] == 'GROUP_CREATE' ? 'create' : "link:#{binding.fetch('ticket_number')}"
      key = "wasalx:group-source:#{binding['tenant_id']}:#{target}:#{binding['message_id']}"
      group_operation_lock(key)
    end

    def assert_group_operation!(row, binding, fingerprint = nil)
      allowed = [binding['kind'], "CANCELLED_#{binding['kind']}"]
      raise Conflict, __('Group operation changed') unless allowed.include?(row.kind) &&
        row.portal_user_id == binding['portal_user_id'] && row.native_user_id.to_s == binding['native_user_id'] &&
        binding.all? { |key, value| row.result[key] == value }
      cancelled = row.kind.start_with?('CANCELLED_')
      valid = cancelled ? row.ticket_id.nil? && row.result['state'] == 'NOT_APPLIED' :
        row.ticket_id.present? && row.ticket_id.to_s == row.result['ticket_id'] && row.result['state'] == 'NATIVE_COMMITTED'
      raise Conflict, __('Group operation changed') unless valid
      raise Conflict, __('Group operation changed') if fingerprint && (cancelled || row.request_sha256 != fingerprint)
    end

    def group_native_result(binding, article)
      binding.merge('state' => 'NATIVE_COMMITTED', 'ticket_id' => article.ticket_id.to_s,
        'ticket_number' => article.ticket.number.to_s, 'article_id' => article.id.to_s)
    end

    def cancel_group_operation(binding, reason)
      result = binding.merge('state' => 'NOT_APPLIED', 'terminal' => true, 'effect' => 'NONE',
        'code' => reason == 'EXPLICIT_CANCELLATION' ? 'GROUP_OPERATION_NOT_APPLIED' : 'GROUP_OPERATION_REJECTED',
        'reason' => reason)
      WasalxTicketOperation.create!(operation_id: binding['operation_id'], portal_user_id: binding['portal_user_id'],
        native_user_id: @actor.id, ticket_id: nil, kind: "CANCELLED_#{binding['kind']}",
        request_sha256: Wasalx::ServiceIdentity.digest(binding), result: result)
    end

    def legacy_group_article(binding, source)
      if binding['kind'] == 'GROUP_CREATE'
        return Ticket::Article.find_by(wasalx_operation_key: operation_key('create', binding['message_id']))
      end
      ticket = Ticket.find_by(number: binding['ticket_number'])
      return nil unless ticket
      article = Ticket::Article.find_by(wasalx_operation_key: operation_key("link:#{ticket.id}", binding['message_id']))
      return article if article
      return nil unless source
      link = source.fetch('links', []).find { |item| item['ticket_id'].to_s == ticket.id.to_s && item['article_id'].present? }
      link && Ticket::Article.find_by(id: positive_identifier!(link['article_id'], 'article').to_i, ticket_id: ticket.id)
    end

    def project_group_operation(result, binding, source)
      return result if result['state'] == 'NOT_APPLIED'
      ticket = Ticket.find(result.fetch('ticket_id'))
      authorize_ticket!(ticket, :agent_read_access?)
      if source
        raise Conflict, __('Group operation changed') unless ticket.wasalx_connection_id.to_s == source.fetch('connection_id').to_s &&
          ticket.wasalx_group_id.to_s == source.fetch('external_group_id').to_s
      end
      article = Ticket::Article.find_by(id: positive_identifier!(result.fetch('article_id'), 'article').to_i, ticket_id: ticket.id)
      return result.merge('state' => 'UNKNOWN', 'terminal' => false) unless article
      expected_key = operation_key(binding['kind'] == 'GROUP_CREATE' ? 'create' : "link:#{ticket.id}", binding['message_id'])
      # Older explicit links may reference an existing article rather than a package-created one.
      links = source ? source.fetch('links', []) : []
      changed = links.any? { |link| link['ticket_id'].to_s == ticket.id.to_s && link['article_id'].present? && link['article_id'].to_s != article.id.to_s }
      raise Conflict, __('Group operation changed') if changed
      exact_link = links.any? do |link|
        link['ticket_id'].to_s == ticket.id.to_s && link['article_id'].to_s == article.id.to_s
      end
      valid = article.wasalx_operation_key == expected_key || exact_link
      return binding.merge('state' => 'UNKNOWN', 'terminal' => false) unless valid || source
      raise Conflict, __('Group operation changed') unless valid
      result.merge('state' => exact_link ? 'COMPLETE' : 'PARTIAL', 'terminal' => false,
        'ticket_number' => ticket.number.to_s)
    rescue ActiveRecord::RecordNotFound
      binding.merge('state' => 'UNKNOWN', 'terminal' => false)
    end

    def admit_group_operation(binding, intent)
      fingerprint = Wasalx::ServiceIdentity.digest({ 'binding' => binding, 'intent' => intent })
      authorize_group_operation!(binding)
      source = nil
      failure = nil
      created = false
      row = UserInfo.with_user_id(@actor.id) do
        Transaction.execute do
          group_operation_lock(binding['operation_id'])
          existing = WasalxTicketOperation.find_by(operation_id: binding['operation_id'])
          if existing
            assert_group_operation!(existing, binding, fingerprint)
            next existing
          end
          group_source_lock(binding)
          begin
            Ticket.transaction(requires_new: true) do
              source = recoverable_group_source(binding)
              article = legacy_group_article(binding, source)
              raise Conflict, __('Group operation cannot be verified') if article && !source
              raise ActiveRecord::RecordNotFound, __('Group message not found') unless source
              if article
                authorize_ticket!(article.ticket, :agent_read_access?)
                if binding['kind'] == 'GROUP_LINK'
                  begin
                    ensure_linked_ticket_destination!(article.ticket, source)
                  rescue ActionController::BadRequest
                    raise Conflict, __('Group operation changed')
                  end
                  if article.ticket.wasalx_connection_id.blank? && article.ticket.wasalx_group_id.blank?
                    authorize_ticket!(article.ticket, :agent_update_access?)
                    article = find_or_create_link_article(source, article.ticket, linked_article_id: article.id)
                  end
                end
                complete = source.fetch('links', []).any? do |link|
                  link['ticket_id'].to_s == article.ticket_id.to_s && link['article_id'].to_s == article.id.to_s
                end
                policy = TicketPolicy.new(@actor, article.ticket)
                unless complete || policy.agent_update_access? || (binding['kind'] == 'GROUP_CREATE' && policy.create?)
                  raise Exceptions::Forbidden, __('Not authorized')
                end
                if binding['kind'] == 'GROUP_CREATE'
                  requested_title = ticket_title(intent.fetch('title'), source['group_name'])
                  raise Conflict, __('Group operation changed') unless article.ticket.group_id.to_s == intent['target_group_id'] &&
                    article.ticket.title == requested_title
                end
              else
                ensure_group_message_actionable!(source)
                if binding['kind'] == 'GROUP_CREATE'
                  raise ActionController::BadRequest, __('This message cannot create a ticket.') if source['from_me']
                  raise ActionController::BadRequest, __('This message is already linked to a ticket.') if source.fetch('links', []).any?
                  article = find_or_create_group_ticket_article(source, intent.fetch('target_group_id'), ticket_title(intent.fetch('title'), source['group_name']))
                  created = true
                else
                  ticket = Ticket.find_by(number: binding['ticket_number'])
                  raise ActiveRecord::RecordNotFound, __('Ticket not found') unless ticket
                  authorize_ticket!(ticket, :agent_update_access?)
                  raise ActionController::BadRequest, __('Outbound group messages cannot be linked to a customer ticket article.') if source['from_me']
                  article = find_or_create_link_article(source, ticket)
                end
              end
              WasalxTicketOperation.create!(operation_id: binding['operation_id'], portal_user_id: binding['portal_user_id'],
                native_user_id: @actor.id, ticket_id: article.ticket_id, kind: binding['kind'],
                request_sha256: fingerprint, result: group_native_result(binding, article))
            end
          rescue Conflict
            raise
          rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, ActionController::BadRequest, Exceptions::ApplicationModel => error
            # The savepoint has rolled back every native mutation before the fence commits.
            failure = error
            cancel_group_operation(binding, 'NATIVE_VALIDATION_REJECTED')
          end
        end
      end
      if failure
        rejection = failure.is_a?(ActiveRecord::RecordNotFound) ? RejectedMissing : Rejected
        raise rejection.new(failure, row.result)
      end
      source ||= recoverable_group_source(binding)
      projection = project_group_operation(row.result, binding, source)
      raise Conflict, __('Group operation cannot be verified') if projection['state'] == 'UNKNOWN'
      if projection['state'] == 'PARTIAL'
        raise ActiveRecord::RecordNotFound, __('Group message not found') unless source
        ticket = Ticket.find(row.ticket_id)
        policy = TicketPolicy.new(@actor, ticket)
        allowed = policy.agent_update_access? || (binding['kind'] == 'GROUP_CREATE' && policy.create?)
        raise Exceptions::Forbidden, __('Not authorized') unless allowed
        article = Ticket::Article.find_by!(id: row.result.fetch('article_id').to_i, ticket_id: ticket.id)
        link_group_message(binding['group_id'], binding['message_id'], article)
      end
      data = { ticket_id: projection.fetch('ticket_id'), ticket_number: projection.fetch('ticket_number'),
        article_id: projection.fetch('article_id') }
      [data, created]
    end


    def ensure_agent!
      raise Exceptions::Forbidden, __('Not authorized') unless @actor.active &&
        @actor.permissions?('ticket.agent') && !Wasalx::ServiceIdentity.automation?(@actor)
      Wasalx::MembershipAccess.check!(@actor)
    end

    def group_actor
      self.class.actor_claims(@actor)
    end

    def authorize_ticket!(ticket, policy)
      raise Exceptions::Forbidden, __('Not authorized') unless TicketPolicy.new(@actor, ticket).public_send(policy)
    end

    def stage_group_workspace_uploads(request_token, upload_cache_id:, upload_store_ids:, group_id:)
      values = Array(upload_store_ids)
      return [] if values.empty? && upload_cache_id.blank?
      cache_id = uuid!(upload_cache_id, 'upload')
      created = []
      Store.transaction do
        Wasalx::PortalUploadExpiry.lock!(@actor.id, cache_id)
        store_ids = values.map { |value| positive_identifier!(value, 'upload item') }.uniq
        raise ActionController::BadRequest, __('Invalid attachments') if store_ids.empty? || store_ids.length > 10 || store_ids.length != values.length
        source = UploadCache.new(cache_id).attachments(created_by_id: @actor.id).index_by { |item| item.id.to_s }
        raise ActionController::BadRequest, __('Invalid attachments') if store_ids.any? { |id| !source.key?(id) }
        target = { 'kind' => 'GROUP', 'id' => group_id }
        raise ActionController::BadRequest, __('Invalid attachments') unless store_ids.all? do |id|
          item = source.fetch(id)
          (!Wasalx::PortalUploadExpiry.marked?(item) || item.preferences['Wasalx-Portal-Target'] == target) && Wasalx::PortalUploadExpiry.fresh?(item)
        end

        existing_items = Store.list(object: 'Wasalx::GroupWorkspaceUpload', o_id: request_token,
                                    created_by_id: @actor.id).to_a
        existing = existing_items.index_by { |item| item.preferences['Wasalx-Upload-Store-Id'].to_s }
        raise ActionController::BadRequest, __('Invalid attachments') if existing.length != existing_items.length || existing.keys.any? { |id| !store_ids.include?(id) }

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
                                   created_by_id: @actor.id)
            created << stored
            was_created = true
          end
          { store: stored, created: was_created,
            descriptor: { upload_id: request_token, store_id: stored.id, uploadCacheId: cache_id,
                          sourceStoreId: id.to_i, filename: stored.filename,
                          mimeType: stored.preferences['Content-Type'], byteSize: stored.size } }
        end
      end
    rescue StandardError
      created&.each { |store| Store.remove_item(store.id) if Store.exists?(store.id) }
      raise
    end

    def remove_created_workspace_uploads(uploads)
      uploads.each { |upload| Store.remove_item(upload.fetch(:store).id) if upload[:created] }
    end

    def group_mentions!(values)
      mentions = values.nil? ? [] : values
      raise ActionController::BadRequest, __('Invalid mentions') if !mentions.is_a?(Array)
      raise ActionController::BadRequest, __('Invalid mentions') if mentions.length > 20 || mentions.uniq.length != mentions.length
      mentions.each do |mention|
        raise ActionController::BadRequest, __('Invalid mentions') if !mention.is_a?(String) || !mention.match?(/\A[1-9][0-9]{5,19}@(c\.us|s\.whatsapp\.net|lid)\z/)
      end
      mentions
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
        authorize_ticket!(existing.ticket, :agent_read_access?)
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
        created_by_id: @actor.id, updated_by_id: @actor.id
      )
      ticket.screen = 'create_middle'
      authorize_ticket!(ticket, :create?)
      attachment = group_message_attachment(source)
      UserInfo.with_user_id(@actor.id) do
        Transaction.execute do
        customer = group_message_customer(source)
        ticket.customer_id = customer.id
        authorize_ticket!(ticket, :create?)
        ticket.save!
        create_group_message_article(ticket, source, operation_key, customer, attachment)
        end
      end
    end

    def group_message_customer(source)
      mobile = group_message_mobile(source)
      if source['zammad_customer_id'].present?
        return add_group_message_mobile(User.find(positive_identifier!(source['zammad_customer_id'], 'customer')), mobile)
      end

      identity_key = source['participant_identity_key'].to_s
      if identity_key.blank? && source['external_participant_id'].present?
        identity_key = Digest::SHA256.hexdigest([ENV.fetch('WASALX_TENANT_ID'), source.fetch('connection_id'), source['external_participant_id']].join("\u001f"))
      end
      raise ActionController::BadRequest, __('This message cannot create a ticket.') if !identity_key.match?(/\A[0-9a-f]{64}\z/)

      login = "wasalx-#{identity_key}"
      existing = User.find_by(login: login)
      return add_group_message_mobile(existing, mobile) if existing

      name = source['participant_name'].to_s.unicode_normalize(:nfc).gsub(/[\p{Cc}\p{Cf}]/, ' ').squeeze(' ').strip.each_char.take(100).join
      User.transaction(requires_new: true) do
        User.create!(login: login, firstname: name.presence || __('WhatsApp participant'), mobile: mobile, active: true,
                   created_by_id: @actor.id, updated_by_id: @actor.id)
      end
    rescue ActiveRecord::RecordNotUnique
      add_group_message_mobile(User.find_by!(login: login), mobile)
    end

    def find_or_create_link_article(source, ticket, linked_article_id: nil)
      operation_key = operation_key("link:#{ticket.id}", source['id'])
      existing = Ticket::Article.find_by(wasalx_operation_key: operation_key)
      attachment = group_message_attachment(source) if !existing && !linked_article_id
      UserInfo.with_user_id(@actor.id) do
        Transaction.execute do
          ticket.lock!
          authorize_ticket!(ticket, :agent_update_access?)
          ensure_linked_ticket_destination!(ticket, source)
          bind_linked_ticket_destination!(ticket, source)
          next Ticket::Article.find_by!(id: linked_article_id, ticket_id: ticket.id) if linked_article_id

          existing = Ticket::Article.find_by(wasalx_operation_key: operation_key)
          next existing if existing

          customer = group_message_customer(source)
          create_group_message_article(ticket, source, operation_key, customer, attachment)
        end
      end
    end

    def ensure_linked_ticket_destination!(ticket, source)
      connection_id = source.fetch('connection_id').to_s
      group_id = source.fetch('external_group_id').to_s
      current_connection_id = ticket.wasalx_connection_id.to_s.presence
      current_group_id = ticket.wasalx_group_id.to_s.presence
      return if current_connection_id.nil? && current_group_id.nil?
      if current_connection_id != connection_id || current_group_id != group_id
        raise ActionController::BadRequest, __('This ticket belongs to another WhatsApp conversation.')
      end
    end

    def bind_linked_ticket_destination!(ticket, source)
      attributes = {
        wasalx_latest_external_message_id: source.fetch('external_message_id'), updated_by_id: @actor.id
      }
      if ticket.wasalx_connection_id.to_s.presence.nil? && ticket.wasalx_group_id.to_s.presence.nil?
        attributes.merge!(
          wasalx_connection_id: source.fetch('connection_id'), wasalx_group_id: source.fetch('external_group_id'),
          wasalx_group_name: source.fetch('group_name'), wasalx_provider: source.fetch('provider'),
          wasalx_source_message_id: source.fetch('external_message_id')
        )
      end
      ticket.screen = 'edit'
      ticket.update!(attributes)
    end

    def create_group_message_article(ticket, source, operation_key, customer, attachment = nil)
      article = Ticket::Article.create!(
        ticket_id: ticket.id, content_type: 'text/plain', body: source['message_text'].presence || group_message_media_label(source),
        internal: false, sender: Ticket::Article::Sender.find_by!(name: 'Customer'),
        type: Ticket::Article::Type.find_by!(name: 'wasalx group message'),
        preferences: { wasalx_origin: 'provider', wasalx_external_message_id: source.fetch('external_message_id') },
        wasalx_operation_key: operation_key, origin_by_id: customer.id,
        created_by_id: @actor.id, updated_by_id: @actor.id
      )
      if attachment
        Store.create!(object: 'Ticket::Article', o_id: article.id, data: attachment.fetch(:data),
                      filename: attachment.fetch(:filename), preferences: { 'Mime-Type' => attachment.fetch(:mime_type) })
      end
      article
    end

    def ensure_group_message_actionable!(source)
      raise ActionController::BadRequest, __('Deleted messages cannot be added to a ticket.') if source['latest_mutation'] == 'REVOKED'
      raise ActionController::BadRequest, __('This message cannot be added to a ticket.') if source['ticket_creatable'] != true
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

      media = Wasalx::Client.download(
        metadata.fetch('url'), maximum,
        expected_content_type: metadata.fetch('mime_type'), expected_sha256: metadata.fetch('sha256')
      )

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
      resolved = source['sender_phone'].to_s
      return resolved if resolved.match?(/\A\+[1-9][0-9]{5,19}\z/)

      participant = source.fetch('external_participant_id').to_s
      jid = participant.match(/\A([1-9][0-9]{5,14})@(c\.us|s\.whatsapp\.net)\z/)
      digits = jid&.[](1)
      digits ||= participant if source['provider'].to_s.casecmp('META').zero? && participant.match?(/\A[1-9][0-9]{5,14}\z/)
      digits ? "+#{digits}" : nil
    end

    def add_group_message_mobile(customer, mobile)
      return customer if mobile.blank? || customer.mobile.present?

      customer.update!(mobile: mobile, updated_by_id: @actor.id)
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

  end
end
