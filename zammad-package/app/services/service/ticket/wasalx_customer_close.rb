# SPDX-License-Identifier: AGPL-3.0-only
require 'time'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>

# A customer confirmation is a separate direct-ticket capability. It never
# relaxes the permissions of the existing group quoted-command service.
class Service::Ticket::WasalxCustomerClose
  def initialize(ticket:, command_id:, current_user:)
    Wasalx::ServiceIdentity.authorize!(current_user, UserInfo.current_token)
    raise ArgumentError, 'Invalid customer close command' unless command_id.to_s.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i)
    @ticket, @command_id, @current_user = ticket, command_id.to_s, current_user
    @key = "direct-customer-close:#{@command_id}"
  end

  def admitted_snapshot
    value = Wasalx::Client.get("/internal/v1/zammad/direct-customer-closes/#{@command_id}", scope: 'zammad:ticket-state')
    raise ArgumentError, 'Invalid customer close admission' unless value.is_a?(Hash) &&
      value['tenant_id'] == ENV.fetch('WASALX_TENANT_ID') && value['instance_id'] == ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID') &&
      value['ticket_id'].to_s == @ticket.id.to_s && value['command_id'] == @command_id &&
      value['request_sha256'].to_s.match?(/\A[a-f0-9]{64}\z/) && %w[ATTEMPTED OUTCOME_UNKNOWN SUCCEEDED].include?(value['native_action_state'])
    value
  end

  def receipt(snapshot)
    article = Ticket::Article.find_by(wasalx_operation_key: @key)
    return nil unless article
    p = article.preferences || {}
    raise ArgumentError, 'Customer close receipt conflict' unless article.ticket_id == @ticket.id && article.internal == true &&
      p['wasalx_customer_close_command_id'] == @command_id && p['wasalx_customer_close_request_sha256'] == snapshot.fetch('request_sha256') &&
      p['wasalx_customer_close_customer_id'] == snapshot.fetch('customer_id') &&
      p['wasalx_customer_close_epoch'] == snapshot.fetch('human_ownership_epoch') && p['wasalx_customer_close_fence'] == snapshot.fetch('conversation_fencing_token')
    { 'state' => 'SUCCEEDED', 'command_id' => @command_id, 'ticket_id' => @ticket.id.to_s, 'article_id' => article.id.to_s,
      'request_sha256' => snapshot.fetch('request_sha256'), 'closed_at' => p.fetch('wasalx_customer_close_closed_at'),
      'customer_id' => snapshot.fetch('customer_id'), 'human_ownership_epoch' => snapshot.fetch('human_ownership_epoch'),
      'conversation_fencing_token' => snapshot.fetch('conversation_fencing_token') }
  end

  def reconcile
    snapshot = admitted_snapshot
    receipt(snapshot) || { 'state' => 'NO_RECEIPT', 'command_id' => @command_id }
  end

  def execute
    snapshot = admitted_snapshot
    @ticket.with_lock do
      existing = receipt(snapshot)
      return existing if existing
      raise Exceptions::Forbidden, 'Customer close is not admitted' unless snapshot['native_action_state'] == 'ATTEMPTED' && snapshot['effects_clear'] == true
      raise ArgumentError, 'Direct customer destination changed' unless @ticket.wasalx_bot_conversation.to_s == 'true' &&
        @ticket.customer_id.to_s == snapshot.fetch('customer_id') && @ticket.wasalx_connection_id.to_s == snapshot.fetch('connection_id') &&
        @ticket.wasalx_group_id.to_s == snapshot.fetch('external_chat_id') && @ticket.group_id.to_s == snapshot.fetch('native_group_id')
      raise ArgumentError, 'Ticket activity changed' unless @ticket.updated_at.utc.iso8601(6) == snapshot.fetch('expected_native_updated_at') &&
        @ticket.state_id.to_s == snapshot.fetch('expected_native_state_id') && Ticket::Article.where(ticket_id: @ticket.id).maximum(:id).to_s == snapshot.fetch('expected_native_article_id')
      closed = Ticket::State.find_by!(name: 'closed')
      state_type = Ticket::StateType.lookup(id: closed.state_type_id)
      raise ArgumentError, 'Closed state is unavailable' unless state_type&.name.to_s.downcase == 'closed'
      raise ArgumentError, 'Ticket is already closed' if @ticket.state_id == closed.id
      raise ArgumentError, 'Reply admission is pending' unless @ticket.send(:wasalx_pending_close_articles, closed, state_type).empty?
      raise ArgumentError, 'Customer close admission changed' unless admitted_snapshot == snapshot
      Transaction.execute do
        # This package-owned transient value is captured by the state hook, never
        # accepted from a controller parameter or a mutable ticket custom field.
        @ticket.instance_variable_set(:@wasalx_customer_close_command_id, @command_id)
        @ticket.update!(state_id: closed.id, wasalx_correlation_status: 'RESOLVED', updated_by_id: @current_user.id)
        Ticket::Article.create!(ticket_id: @ticket.id, type: Ticket::Article::Type.lookup(name: 'note'),
          sender: Ticket::Article::Sender.lookup(name: 'System'), internal: true,
          body: 'Customer explicitly confirmed that this request is resolved.', content_type: 'text/plain',
          wasalx_operation_key: @key, created_by_id: @current_user.id, updated_by_id: @current_user.id,
          preferences: { 'wasalx_customer_close_command_id' => @command_id,
            'wasalx_customer_close_request_sha256' => snapshot.fetch('request_sha256'),
            'wasalx_customer_close_customer_id' => snapshot.fetch('customer_id'),
            'wasalx_customer_close_epoch' => snapshot.fetch('human_ownership_epoch'),
            'wasalx_customer_close_fence' => snapshot.fetch('conversation_fencing_token'),
            'wasalx_customer_close_closed_at' => @ticket.updated_at.utc.iso8601(6) })
      ensure
        @ticket.remove_instance_variable(:@wasalx_customer_close_command_id) if @ticket.instance_variable_defined?(:@wasalx_customer_close_command_id)
      end
      receipt(snapshot)
    end
  end
end
