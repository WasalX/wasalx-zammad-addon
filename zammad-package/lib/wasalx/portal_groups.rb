# SPDX-License-Identifier: AGPL-3.0-only
require_relative 'group_workspace'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>

module Wasalx
  # Only presentation shapes live here; the native workspace retains every action boundary.
  module PortalGroups
    class GroupUnavailable < StandardError
      attr_reader :group_id
      def initialize(group_id)
        @group_id = group_id
        super('Group access is unavailable')
      end
    end
    private

    def group_workspace
      @group_workspace ||= Wasalx::GroupWorkspace.new(actor: @actor)
    end

    def selected_workspace_group!
      group = group_workspace.groups(scope: 'ALL', selected: @input['group_id'], limit: 1)
        .fetch('items').find { |item| item['id'] == @input['group_id'] }
      raise GroupUnavailable.new(@input['group_id']) unless group
      group
    end

    def group_operation
      case @envelope.fetch('operation')
      when 'GROUP_CHECK'
        keys!(%w[group_id])
        selected_workspace_group! if @input['group_id']
        { allowed: true }
      when 'GROUP_LIST'
        keys!(%w[scope after selected])
        group_workspace.groups(scope: @input['scope'], after: @input['after'], selected: @input['selected'])
      when 'GROUP_SHOW'
        keys!(%w[group_id])
        selected_workspace_group!
      when 'GROUP_MESSAGES'
        keys!(%w[group_id before])
        rows = group_workspace.messages(group_id: @input['group_id'], before: @input['before'], limit: 51)
        group_message_page(rows, limit: 50)
      when 'GROUP_CONTEXT'
        keys!(%w[group_id message_id])
        rows = group_workspace.context(group_id: @input['group_id'], message_id: @input['message_id'])
        group_message_page(rows, context: true)
      when 'GROUP_PARTICIPANTS'
        keys!(%w[group_id query])
        group_workspace.participants(group_id: @input['group_id'], q: @input['query']).filter_map do |participant|
          phone = participant['phone']
          token = phone.is_a?(String) && phone.match?(/\A\+[1-9][0-9]{5,19}\z/) ? phone.delete_prefix('+') : participant['id'].to_s.split('@', 2).first
          next unless token.match?(/\A[0-9]{1,24}\z/)
          participant.slice('id', 'name', 'phone').merge('mention_token' => token)
        end
      when 'GROUP_TICKETS'
        keys!(%w[group_id state before])
        raise ArgumentError unless %w[OPEN CLOSED ALL].include?(@input['state'])
        page = group_workspace.tickets(group_id: @input['group_id'], before: @input['before']).deep_stringify_keys
        by_id = Ticket.where(id: page.fetch('items').map { |item| item['ticket_id'] }).index_by { |ticket| ticket.id.to_s }
        { items: page.fetch('items').filter_map do |item|
            ticket = by_id[item['ticket_id']]
            next unless ticket && TicketPolicy.new(@actor, ticket).agent_read_access?
            next unless @input['state'] == 'ALL' || item['state_category'] == @input['state']
            item.slice('ticket_number', 'state_category', 'links').merge(title: ticket.title,
              owner: ticket.owner&.fullname, team: ticket.group.name)
          end, next_cursor: page['next_cursor'] }
      when 'GROUP_TEAMS'
        keys!([])
        group_workspace.ticket_groups
      when 'GROUP_READ'
        keys!(%w[group_id message_id])
        result = group_workspace.read(group_id: @input['group_id'], message_id: @input['message_id'])
        { acknowledged: result['read'] == true }
      when 'GROUP_SEND'
        keys!(%w[group_id request_token message reply_to_message_id mentions upload_cache_id upload_store_ids])
        group_workspace.send_message(**@input.symbolize_keys)
        { accepted: true }
      when 'GROUP_REACTION'
        keys!(%w[group_id message_id request_token emoji removed])
        group_workspace.reaction(group_id: @input['group_id'], message_id: @input['message_id'],
          request_token: @input['request_token'], emoji: @input['emoji'],
          removed_value: @input.key?('removed') ? @input['removed'] : Wasalx::GroupWorkspace::UNSET)
        { accepted: true }
      when 'GROUP_CREATE_TICKET'
        keys!(%w[group_id message_id request_token title target_group_id])
        result = group_workspace.create_ticket(**@input.symbolize_keys)
        { accepted: true, ticket_number: result.data[:ticket_number] || result.data['ticket_number'] }
      when 'GROUP_LINK_TICKET'
        keys!(%w[group_id message_id request_token ticket_number])
        result = group_workspace.link_ticket(**@input.symbolize_keys)
        { accepted: true, ticket_number: result[:ticket_number] || result['ticket_number'] }
      when 'GROUP_RECEIPT'
        keys!(%w[group_id operation_id kind target_message_id action])
        result = group_workspace.operation_receipt(group_id: @input['group_id'], request_token: @input['operation_id'],
          kind: @input['kind'], target_message_id: @input['target_message_id'], action: @input['action'])
        { state: result.fetch('outcome'), terminal: result['terminal'] == true }
      when 'GROUP_TICKET_RECEIPT', 'GROUP_REPAIR_TICKET_LINK'
        keys!(%w[group_id message_id operation_id kind target_ticket_number action])
        kind = { 'CREATE' => 'GROUP_CREATE', 'LINK' => 'GROUP_LINK' }.fetch(@input['kind']) { raise ArgumentError }
        arguments = { group_id: @input['group_id'], message_id: @input['message_id'],
          request_token: @input['operation_id'], kind: kind, ticket_number: @input['target_ticket_number'] }
        if @envelope['operation'] == 'GROUP_REPAIR_TICKET_LINK'
          group_workspace.repair_ticket_link(**arguments)
        else
          group_workspace.group_receipt(**arguments, action: @input['action'])
        end
      else
        raise ArgumentError
      end
    rescue Wasalx::Client::PermanentRequestFailed => error
      if error.http_status == 404 && @input['group_id']
        selected_workspace_group!
        raise ActiveRecord::RecordNotFound
      end
      raise
    end

    def group_message_page(rows, limit: 50, context: false)
      ordered = rows.sort_by { |item| [item.fetch('provider_timestamp'), item.fetch('id')] }.reverse
      visible = ordered.first(limit)
      by_external_id = rows.select { |item| item['external_message_id'].is_a?(String) && !item['external_message_id'].empty? }.group_by { |item| item['external_message_id'] }
      items = visible.map do |item|
        candidates = by_external_id.fetch(item['quoted_external_message_id'], [])
        quoted = candidates.first if candidates.length == 1
        item.except('external_message_id', 'quoted_external_message_id', 'participant_identity_key').merge(
          'quoted_message' => quoted && { id: quoted['id'], author: quoted['participant_name'], text: quoted['message_text'] },
          'quote_unavailable' => item['quoted_external_message_id'].is_a?(String) && !item['quoted_external_message_id'].empty? && !quoted)
      end
      { items: items, next_cursor: (ordered.length > limit || context) ? visible.last&.fetch('id') : nil }
    end
  end
end
