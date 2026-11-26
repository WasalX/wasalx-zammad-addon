# SPDX-License-Identifier: AGPL-3.0-only
require_relative 'native_identifiers'
# Copyright (c) 2026 WasalX

module Wasalx
  class ReplyPreview
    include NativeIdentifiers
    def initialize(actor:)
      @actor = User.find(actor.id)
      raise Exceptions::Forbidden, __('Not authorized') unless @actor.active && @actor.permissions?('ticket.agent') &&
        !Wasalx::ServiceIdentity.automation?(@actor)
      Wasalx::MembershipAccess.check!(@actor)
    end

    def call(**input)
    ticket = Ticket.find(positive_identifier!(input[:ticket_id], 'ticket'))
    raise Exceptions::Forbidden, __('Not authorized') unless TicketPolicy.new(@actor, ticket).agent_update_access?
    if input[:internal] != false || !input[:body].is_a?(String) || ![true, false].include?(input[:has_attachments]) ||
       (input.key?(:restored_draft) && ![true, false].include?(input[:restored_draft]))
      raise ActionController::BadRequest, __('Invalid message')
    end
    body = input[:body]
    if body.each_char.count > 4096 || body.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/) || (body.strip.empty? && !input[:has_attachments])
      raise ActionController::BadRequest, __('Invalid message')
    end
    connection_id = uuid!(ticket.wasalx_connection_id, 'connection')
    group_id = ticket.wasalx_group_id.to_s
    if group_id.empty? || group_id.length > 512 || group_id.match?(/[[:cntrl:]]/)
      raise ActionController::BadRequest, __('Invalid group')
    end
    marker = ticket.respond_to?(:wasalx_bot_conversation) ? ticket.wasalx_bot_conversation : nil
    state = ticket.respond_to?(:wasalx_bot_state) ? ticket.wasalx_bot_state : nil
    direct = marker == true || marker.to_s.downcase == 'true' || !state.to_s.empty?
    raise Exceptions::Forbidden, __('Not authorized') if direct && state != 'HUMAN' && !(state == 'BOT' && ticket.respond_to?(:wasalx_bot_keep_open) && ticket.wasalx_bot_keep_open == 'true')

    selected_article_id = Service::Ticket::WasalxReplyContext.article_id(ticket: ticket, requested: input[:in_reply_to])
    identity = Service::Ticket::WasalxReplyContext.agent_identity(user: @actor, id: @actor.id)
    Wasalx::Client.post(
      '/internal/v1/zammad/reply-preview',
      { tenant_id: ENV.fetch('WASALX_TENANT_ID'), connection_id: connection_id, group_id: group_id,
        ticket_id: ticket.id, body: body, reply_to_article_id: selected_article_id,
        agent: identity, has_attachments: input[:has_attachments], internal: false, restored_draft: input[:restored_draft] }.compact,
      scope: 'zammad:outbound', actor: Wasalx::GroupWorkspace.actor_claims(@actor)
    )
  rescue ArgumentError, TypeError
    raise ActionController::BadRequest, __('Invalid message')
  end
  end
end
