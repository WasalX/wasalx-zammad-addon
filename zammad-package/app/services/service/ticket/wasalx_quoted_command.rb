# SPDX-License-Identifier: AGPL-3.0-only
require 'time'
# Copyright (c) 2026 WasalX
class Service::Ticket::WasalxQuotedCommand
  def initialize(ticket:, execution_id:, current_user:)
    Wasalx::ServiceIdentity.authorize!(current_user, UserInfo.current_token)
    raise ArgumentError, 'Invalid command execution' unless execution_id.to_s.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i)
    @ticket, @execution_id, @current_user = ticket, execution_id.to_s, current_user
    @key = "ticket-command:#{@execution_id}"
  end

  # Both GET and POST resolve the authoritative committed application snapshot.
  # Never accept membership, expected activity, or permission booleans from HTTP params.
  def admitted_snapshot
    value = Wasalx::Client.get("/internal/v1/zammad/quoted-commands/#{@execution_id}?denied_transcript=v1", scope: 'zammad:ticket-state')
    raise ArgumentError, 'Invalid command admission' unless value.is_a?(Hash) &&
      value['tenant_id'] == ENV.fetch('WASALX_TENANT_ID') &&
      value['instance_id'] == ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID') &&
      value['ticket_id'].to_s == @ticket.id.to_s && value['execution_id'] == @execution_id &&
      value['request_sha256'].to_s.match?(/\A[a-f0-9]{64}\z/) &&
      %w[ATTEMPTED OUTCOME_UNKNOWN SUCCEEDED].include?(value['native_action_state'])
    denied_transcript?(value)
    value
  end

  def denied_transcript?(snapshot)
    return false if !snapshot.key?('disposition') || snapshot['disposition'] == 'CLOSE'
    raise ArgumentError, 'Invalid command disposition' unless snapshot['disposition'] == 'TRANSCRIPT_ONLY_DENIED' &&
      snapshot['denied_transcript'] == 'v1' && snapshot['command_authorized'] == false &&
      snapshot.dig('plan', 'effects') == [] && %w[AGENTS SPECIFIC ANYONE].include?(snapshot['permission'])
    true
  end

  def denied_body(snapshot)
    reason = snapshot['permission'] == 'AGENTS' ?
      "Rejected: only tenant agents may close this ticket.\nتم الرفض: يمكن لموظفي المستأجر فقط إغلاق هذه التذكرة." :
      "Rejected: you do not have permission to close this ticket.\nتم الرفض: ليست لديك صلاحية إغلاق هذه التذكرة."
    "#{snapshot.fetch('command_text')}\n\n#{reason}"
  end

  def receipt(snapshot)
    article = Ticket::Article.find_by(wasalx_operation_key: @key)
    return nil if !article
    preferences = article.preferences || {}
    raise ArgumentError, 'Command receipt conflict' unless article.ticket_id == @ticket.id &&
      article.internal == true && preferences['wasalx_command_execution_id'] == @execution_id &&
      preferences['wasalx_command_request_sha256'] == snapshot.fetch('request_sha256') &&
      preferences['wasalx_external_message_id'] == snapshot.fetch('message_id') &&
      preferences['wasalx_quoted_external_message_id'] == snapshot.fetch('quoted_message_id') &&
      preferences['wasalx_participant_id'] == snapshot.fetch('participant_id')
    result = { 'state' => 'SUCCEEDED', 'execution_id' => @execution_id,
      'ticket_id' => @ticket.id.to_s, 'article_id' => article.id.to_s,
      'request_sha256' => snapshot.fetch('request_sha256') }
    if denied_transcript?(snapshot)
      raise ArgumentError, 'Denied command receipt conflict' unless preferences['wasalx_command_disposition'] == 'TRANSCRIPT_ONLY_DENIED' &&
        article.body == denied_body(snapshot) && !preferences.key?('wasalx_command_closed_at')
      result.merge('disposition' => 'TRANSCRIPT_ONLY_DENIED', 'outcome' => 'REJECTED',
        'recorded_at' => preferences.fetch('wasalx_command_recorded_at'))
    else
      raise ArgumentError, 'Command receipt disposition conflict' if preferences['wasalx_command_disposition']
      result.merge('closed_at' => preferences.fetch('wasalx_command_closed_at'))
    end
  end

  # Read-only reconciliation is the ONLY allowed operation after an ambiguous POST.
  def reconcile
    snapshot = admitted_snapshot
    receipt(snapshot) || { 'state' => 'NO_RECEIPT', 'execution_id' => @execution_id }
  end

  def execute
    snapshot = admitted_snapshot
    @ticket.with_lock do
      existing = receipt(snapshot)
      return existing if existing
      raise Exceptions::Forbidden, 'Command is not admitted for execution' unless snapshot['native_action_state'] == 'ATTEMPTED' && snapshot['effects_clear'] == true
      raise ArgumentError, 'Ticket destination changed' unless @ticket.wasalx_connection_id.to_s == snapshot.fetch('connection_id') &&
        @ticket.wasalx_group_id.to_s == snapshot.fetch('external_group_id') &&
        @ticket.group_id.to_s == snapshot.fetch('native_group_id')
      expected = snapshot.fetch('expected_native_updated_at')
      raise ArgumentError, 'Ticket activity changed' unless @ticket.updated_at.utc.iso8601(6) == expected &&
        @ticket.state_id.to_s == snapshot.fetch('expected_native_state_id') &&
        Ticket::Article.where(ticket_id: @ticket.id).maximum(:id).to_s == snapshot.fetch('expected_native_article_id')
      if denied_transcript?(snapshot)
        raise ArgumentError, 'Command admission changed' unless admitted_snapshot == snapshot
        state = [@ticket.state_id, @ticket.owner_id, @ticket.group_id, @ticket.wasalx_correlation_status]
        Transaction.execute do
          Ticket::Article.create!(ticket_id: @ticket.id, type: Ticket::Article::Type.lookup(name: 'note'),
            sender: Ticket::Article::Sender.lookup(name: 'System'), internal: true,
            body: denied_body(snapshot), content_type: 'text/plain', wasalx_operation_key: @key,
            created_by_id: @current_user.id, updated_by_id: @current_user.id,
            preferences: { 'wasalx_command_execution_id' => @execution_id,
              'wasalx_origin' => 'provider', 'wasalx_external_message_id' => snapshot.fetch('message_id'),
              'wasalx_quoted_external_message_id' => snapshot.fetch('quoted_message_id'),
              'wasalx_participant_id' => snapshot.fetch('participant_id'),
              'wasalx_command_request_sha256' => snapshot.fetch('request_sha256'),
              'wasalx_command_disposition' => 'TRANSCRIPT_ONLY_DENIED',
              'wasalx_command_recorded_at' => Time.now.utc.iso8601(6) })
          @ticket.reload
          raise ArgumentError, 'Denied command changed ticket state' unless state ==
            [@ticket.state_id, @ticket.owner_id, @ticket.group_id, @ticket.wasalx_correlation_status]
        end
        return receipt(snapshot)
      end
      if snapshot.fetch('permission') == 'AGENTS'
        # Email comes from the active WasalX membership selected by verified phone.
        # Unique, active native identity + actual native ticket.agent/full-group permission.
        users = User.where('LOWER(email) = ?', snapshot.fetch('member_email').downcase).where(active: true).limit(2).to_a
        agent = users.one? && users.first
        raise Exceptions::Forbidden, 'Agent access unavailable' unless agent && agent.permissions?('ticket.agent') &&
          agent.group_ids_access('full').map(&:to_s).include?(@ticket.group_id.to_s)
      elsif !%w[SPECIFIC ANYONE].include?(snapshot.fetch('permission'))
        raise Exceptions::Forbidden, 'Command policy is invalid'
      end
      closed = Ticket::State.find_by!(name: 'closed')
      raise ArgumentError, 'Closed state is unavailable' unless Ticket::StateType.lookup(id: closed.state_type_id)&.name.to_s.downcase == 'closed'
      pending = @ticket.send(:wasalx_pending_close_articles, closed, Ticket::StateType.lookup(id: closed.state_type_id))
      raise ArgumentError, 'Reply admission is pending' unless pending.empty?
      # Explicit backend activity/delivery check immediately before native write,
      # while the ticket is locked. Backend preserves the committed command barrier.
      current = admitted_snapshot
      raise ArgumentError, 'Command admission changed' unless current == snapshot
      Transaction.execute do
        @ticket.update!(state_id: closed.id, wasalx_correlation_status: 'RESOLVED', updated_by_id: @current_user.id)
        closed_at = @ticket.updated_at.utc.iso8601(6)
        Ticket::Article.create!(ticket_id: @ticket.id, type: Ticket::Article::Type.lookup(name: 'note'),
          sender: Ticket::Article::Sender.lookup(name: 'System'), internal: true,
          body: snapshot.fetch('command_text'), content_type: 'text/plain',
          wasalx_operation_key: @key, created_by_id: @current_user.id, updated_by_id: @current_user.id,
          preferences: { 'wasalx_command_execution_id' => @execution_id,
            'wasalx_origin' => 'provider', 'wasalx_external_message_id' => snapshot.fetch('message_id'),
            'wasalx_quoted_external_message_id' => snapshot.fetch('quoted_message_id'),
            'wasalx_participant_id' => snapshot.fetch('participant_id'),
            'wasalx_command_request_sha256' => snapshot.fetch('request_sha256'),
            'wasalx_command_closed_at' => closed_at })
      end
      receipt(snapshot)
    end
  end
end
