# SPDX-License-Identifier: AGPL-3.0-only
require 'digest'
# Copyright (c) 2026 WasalX
require_relative 'portal_upload_expiry'

module Wasalx
  module PortalWorkspaceUploads
    MAXIMUM_BYTES = 50_000_000
    INLINE_MEDIA = %w[image/jpeg image/png image/gif image/webp audio/ogg audio/mpeg audio/mp4 audio/webm video/mp4].freeze

    def upload
      raise Exceptions::Forbidden unless Wasalx::ServiceIdentity.token_allowed?(current_user, @_token, 'runtime')
      @envelope = Wasalx::PortalDelegation.decode_upload(request.headers['X-Wasalx-Upload-Envelope'].to_s,
        request.headers['X-Wasalx-Timestamp'].to_s, request.headers['X-Wasalx-Signature'].to_s,
        secret: ENV.fetch('WASALX_SERVICE_JWT_SECRET'), tenant: ENV.fetch('WASALX_TENANT_ID'),
        instance: ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'))
      @actor = resolve_actor!
      @input = @envelope.fetch('input')
      expected = @envelope.fetch('file')
      raise ArgumentError unless request.content_type == 'application/octet-stream' && request.content_length == expected.fetch('byte_size')
      bytes = request.body.read(expected.fetch('byte_size') + 1)
      raise ArgumentError unless bytes.bytesize == expected.fetch('byte_size') && Digest::SHA256.hexdigest(bytes) == expected.fetch('sha256')
      result = UserInfo.with_user_id(@actor.id) do
        Store.transaction do
          cache_id = workspace_cache_id!
          workspace_upload_lock!(cache_id)
          capabilities, target = workspace_upload_target!
          cache = UploadCache.new(cache_id)
          current = cache.attachments(created_by_id: @actor.id).to_a
          current.reject! do |item|
            next false if Wasalx::PortalUploadExpiry.fresh?(item)
            cache.remove_item(item.id)
            true
          end
          raise ArgumentError unless current.all? { |item| item.preferences['Wasalx-Portal-Target'] == target }
          accepted = capabilities.fetch('accepted').find { |rule| rule['mime_type'] == expected.fetch('mime_type') }
          raise ArgumentError unless accepted && expected.fetch('byte_size') <= [accepted.fetch('maximum_bytes'), MAXIMUM_BYTES].min
          duplicate = current.find do |item|
            item.preferences['Wasalx-Portal-SHA256'] == expected.fetch('sha256') && item.filename == expected.fetch('filename') &&
              item.preferences['Content-Type'] == expected.fetch('mime_type') && workspace_store_size!(item) == expected.fetch('byte_size')
          end
          if duplicate
            duplicate.touch
            next { items: [{ id: duplicate.id.to_s, filename: duplicate.filename, mime_type: duplicate.preferences['Content-Type'], size: workspace_store_size!(duplicate) }] }
          end
          raise ArgumentError unless current.length < [capabilities.fetch('maximum_files'), 10].min &&
            current.sum { |item| workspace_store_size!(item) } + expected.fetch('byte_size') <= capabilities.fetch('maximum_total_bytes')
          store = cache.add(filename: expected.fetch('filename'), data: bytes,
            preferences: { 'Content-Type' => expected.fetch('mime_type'), 'Wasalx-Portal-Target' => target, 'Wasalx-Portal-SHA256' => expected.fetch('sha256') }, created_by_id: @actor.id)
          { items: [{ id: store.id.to_s, filename: store.filename, mime_type: store.preferences['Content-Type'], size: workspace_store_size!(store) }] }
        end
      end
      response.headers['Cache-Control'] = 'private, no-store'
      render json: result
    rescue Wasalx::PortalGroups::GroupUnavailable => error
      render json: { code: 'GROUP_ACCESS_DENIED', group_id: error.group_id }, status: :forbidden
    rescue Wasalx::PortalDelegation::Invalid, ArgumentError
      render json: { code: 'INVALID_WORKSPACE_UPLOAD' }, status: :bad_request
    rescue Wasalx::Client::RequestFailed
      render json: { code: 'WORKSPACE_UNAVAILABLE' }, status: :service_unavailable
    end

    private

    def ticket_upload_constraints
      { accepted: nil, maximum_file_bytes: MAXIMUM_BYTES, maximum_files: 10, maximum_total_bytes: MAXIMUM_BYTES }
    end

    def workspace_cache_id!
      id = @input['upload_cache_id']
      raise ArgumentError unless id.is_a?(String) && Wasalx::PortalDelegation::UUID.match?(id)
      id
    end

    def workspace_upload_lock!(id)
      Wasalx::PortalUploadExpiry.lock!(@actor.id, id)
    end

    def workspace_store_size!(item)
      raise ArgumentError unless item.size.to_s.match?(/\A[0-9]+\z/)
      Integer(item.size.to_s, 10)
    end

    def workspace_authorized_group!
      id = @input['group_id']
      raise ArgumentError unless id.is_a?(String) && Wasalx::PortalDelegation::UUID.match?(id)
      result = Wasalx::GroupWorkspace.new(actor: @actor).groups(limit: 1, selected: id, scope: 'ALL')
      group = result.fetch('items').find { |item| item['id'] == id }
      raise Wasalx::PortalGroups::GroupUnavailable.new(id) unless group
      group
    end

    def workspace_upload_target!
      @actor = resolve_actor!
      if @input.key?('group_id')
        group = workspace_authorized_group!
        raise Exceptions::Forbidden unless group['send_available'] == true
        return [group.fetch('media_capabilities'), { 'kind' => 'GROUP', 'id' => @input.fetch('group_id') }]
      end
      target = if @input.key?('ticket_id')
                 ticket = ticket!(write: true)
                 { 'kind' => 'TICKET', 'id' => ticket.id.to_s }
               else
                 group = Group.find(positive!(@input['create_group_id']))
                 raise Exceptions::Forbidden unless group.active && TicketPolicy.new(@actor, Ticket.new(group_id: group.id)).create?
                 { 'kind' => 'CREATE_GROUP', 'id' => group.id.to_s }
               end
      # Ticket attachments use native MIME discovery; downloaded files never execute inline.
      mime = @envelope.fetch('file').fetch('mime_type')
      raise ArgumentError unless mime == 'application/octet-stream' || MIME::Types[mime].present?
      limits = ticket_upload_constraints
      [{ 'accepted' => [{ 'mime_type' => mime, 'maximum_bytes' => limits.fetch(:maximum_file_bytes) }],
         'maximum_files' => limits.fetch(:maximum_files), 'maximum_total_bytes' => limits.fetch(:maximum_total_bytes) }, target]
    end

    def remove_workspace_upload
      keys!(%w[group_id ticket_id create_group_id upload_cache_id upload_store_id])
      expected = @input.key?('group_id') ? %w[group_id upload_cache_id upload_store_id] :
        @input.key?('ticket_id') ? %w[ticket_id upload_cache_id upload_store_id] : %w[create_group_id upload_cache_id upload_store_id]
      raise ArgumentError unless @input.keys.sort == expected.sort
      Store.transaction do
        cache_id = workspace_cache_id!
        workspace_upload_lock!(cache_id)
        @actor = resolve_actor!
        # A remove request is authorized against the current destination before touching its cache.
        target = if @input.key?('group_id')
                   workspace_authorized_group!
                   { 'kind' => 'GROUP', 'id' => @input.fetch('group_id') }
                 elsif @input.key?('ticket_id')
                   ticket = ticket!(write: true)
                   { 'kind' => 'TICKET', 'id' => ticket.id.to_s }
                 else
                   group = Group.find(positive!(@input['create_group_id']))
                   raise Exceptions::Forbidden unless group.active && TicketPolicy.new(@actor, Ticket.new(group_id: group.id)).create?
                   { 'kind' => 'CREATE_GROUP', 'id' => group.id.to_s }
                 end
        cache = UploadCache.new(cache_id)
        store = cache.attachments(created_by_id: @actor.id).find_by(id: positive!(@input['upload_store_id']))
        raise ActiveRecord::RecordNotFound unless store && store.preferences['Wasalx-Portal-Target'] == target
        cache.remove_item(store.id)
      end
      { removed: true }
    end

    def group_media
      keys!(%w[group_id message_id])
      workspace_authorized_group!
      file = Wasalx::GroupWorkspace.new(actor: @actor).message_media(group_id: @input['group_id'], message_id: @input['message_id'])
      raise ArgumentError unless file.data.bytesize.between?(1, MAXIMUM_BYTES)
      @actor = resolve_actor!
      workspace_authorized_group!
      mime = file.content_type.to_s.split(';', 2).first.to_s.strip.downcase
      safe = INLINE_MEDIA.include?(mime)
      Attachment.new(file.data, file.filename, safe ? mime : 'application/octet-stream', safe ? 'inline' : 'attachment')
    end
  end
end
