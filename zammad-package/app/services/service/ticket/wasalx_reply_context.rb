# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
# Shared by delivery and read-only composer preview. Resolve native article IDs
# here; only the control plane can resolve their tenant-bound provider identity.
class Service::Ticket::WasalxReplyContext < Service::Base
  ARTICLE_TYPE = 'wasalx group message'.freeze

  def self.article_id(ticket:, requested:, excluding_article_id: nil)
    return nil if requested.nil? || (requested.is_a?(String) && requested.strip.empty?)
    if !requested.is_a?(String) || requested.length > 512 || requested.match?(/[[:cntrl:]\u200B-\u200F\u202A-\u202E\u2060-\u206F]/)
      raise ArgumentError, 'Quoted WhatsApp message is invalid'
    end

    explicit_id = /\Awasalx-article:([1-9][0-9]{0,15})\z/.match(requested)
    source = if explicit_id
               ::Ticket::Article.find_by(ticket_id: ticket.id, id: Integer(explicit_id[1], 10))
             else
               ::Ticket::Article.find_by(ticket_id: ticket.id, message_id: requested)
             end
    if source.nil? || source.ticket_id != ticket.id || (excluding_article_id && source.id.to_s == excluding_article_id.to_s)
      raise ArgumentError, 'Quoted WhatsApp message was not found'
    end
    source_type = ::Ticket::Article::Type.lookup(id: source.type_id)
    source_sender = ::Ticket::Article::Sender.lookup(id: source.sender_id)
    if source.internal != false || source_type&.name != ARTICLE_TYPE || !%w[Customer Agent].include?(source_sender&.name)
      raise ArgumentError, 'Quoted WhatsApp message is unavailable'
    end

    source.id.to_s
  end

  def self.agent_identity(user:, id:)
    raise ArgumentError, 'Agent identity is missing' if user.nil?
    agent_id = Integer(id)
    raise ArgumentError, 'Agent identity is invalid' if agent_id <= 0

    name = [user.respond_to?(:firstname) ? user.firstname : nil,
            user.respond_to?(:lastname) ? user.lastname : nil].compact.join(' ')
    name = name.unicode_normalize(:nfc).gsub(/[[:cntrl:]\u200B-\u200F\u202A-\u202E\u2060-\u206F]/, ' ').gsub(/\s+/, ' ').strip[0, 80]
    { id: agent_id.to_s, display_name: name.empty? ? 'Agent' : name }
  end
end
