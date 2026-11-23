# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
class WasalxTicketRoutingJob < ApplicationJob
  self.enqueue_after_transaction_commit = false
  self.log_arguments = false
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  ROUTING_PAYLOAD_KEYS = %w[
    admitted_at article_id expected_assignment_revision expected_group_id expected_owner_id
    instance_id sender_email tenant_id ticket_id ticket_number
  ].sort.freeze
  ACKNOWLEDGEMENT_PAYLOAD_KEYS = %w[
    application_status article_id instance_id observed_group_id observed_owner_id phase
    route_id tenant_id ticket_id
  ].sort.freeze
  TERMINAL_FAILURE_CODE = 'WX-EMAIL-ROUTING-TERMINAL'
  TERMINAL_FAILURE_MESSAGE = 'WasalX could not apply this email routing decision. Review the routing setup, then retry from the WasalX action.'

  def self.positive_retry_setting(name, default)
    value = Integer(ENV.fetch(name, default.to_s), 10, exception: false)
    raise ArgumentError, "#{name} must be a positive integer" unless value&.positive?
    value
  end
  private_class_method :positive_retry_setting

  RETRY_ATTEMPTS = positive_retry_setting('WASALX_ROUTING_RETRY_ATTEMPTS', 10)
  RETRY_WAIT_SECONDS = positive_retry_setting('WASALX_ROUTING_RETRY_WAIT_SECONDS', 30)
  RETRY_MAX_WAIT_SECONDS = 15 * 60

  retry_on Wasalx::Client::TemporaryRequestFailed, attempts: RETRY_ATTEMPTS, wait: lambda { |executions|
    [executions**2 * RETRY_WAIT_SECONDS, RETRY_MAX_WAIT_SECONDS].min
  } do |job|
    job.send(:record_retry_exhaustion)
  end

  class << self
    def replay!(ticket:, article:)
      ticket.with_lock do
        article.lock!
        permanent!('Routing source article does not belong to this ticket') if article.ticket_id != ticket.id
        preferences = (article.preferences || {}).deep_dup
        routing_state = preferences['wasalx_email_routing_state'].to_s
        acknowledgement_state = preferences['wasalx_email_routing_ack_state'].to_s

        if routing_state == 'FAILED_TERMINAL'
          payload = validated_routing_payload!(preferences['wasalx_email_routing_payload'], ticket, article)
          preferences['wasalx_email_routing_state'] = 'PENDING'
          preferences.delete('wasalx_email_routing_error_code')
          Transaction.execute do
            article.update!(preferences: preferences)
            ticket.update!(wasalx_client_route_status: 'PENDING') if ticket.wasalx_client_route_status == 'FAILED_TERMINAL'
            perform_later(payload)
          end
          return { state: 'PENDING', duplicate: false }
        end

        if acknowledgement_state == 'FAILED_TERMINAL'
          payload = validated_acknowledgement_payload!(preferences['wasalx_email_routing_ack_payload'], ticket, article)
          preferences['wasalx_email_routing_ack_state'] = 'PENDING'
          preferences.delete('wasalx_email_routing_ack_error_code')
          Transaction.execute do
            article.update!(preferences: preferences)
            perform_later(payload)
          end
          return { state: 'PENDING', duplicate: false }
        end

        return { state: 'PENDING', duplicate: true } if routing_state == 'PENDING' || acknowledgement_state == 'PENDING'

        permanent!('Email routing is not retryable')
      end
    end

    private

    def validated_routing_payload!(value, ticket, article)
      keys = value.is_a?(Hash) && (value.key?('entry_group_id') || value.key?(:entry_group_id)) ? (ROUTING_PAYLOAD_KEYS + ['entry_group_id']).sort : ROUTING_PAYLOAD_KEYS
      payload = exact_payload!(value, keys)
      permanent!('Stored email routing entry group is invalid') if payload.key?('entry_group_id') && payload['entry_group_id'].to_s != payload['expected_group_id'].to_s
      permanent!('Stored email routing provenance is invalid') unless
        payload['tenant_id'] == ENV.fetch('WASALX_TENANT_ID') &&
        payload['instance_id'] == ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID') &&
        payload['ticket_id'].to_s == ticket.id.to_s && payload['article_id'].to_s == article.id.to_s &&
        payload['ticket_number'].to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z/) &&
        valid_positive_id?(payload['expected_group_id']) && valid_positive_id?(payload['expected_owner_id']) &&
        valid_nonnegative_integer?(payload['expected_assignment_revision']) &&
        valid_email?(payload['sender_email']) && valid_admission_timestamp?(payload['admitted_at'])
      payload
    end

    def validated_acknowledgement_payload!(value, ticket, article)
      payload = exact_payload!(value, ACKNOWLEDGEMENT_PAYLOAD_KEYS)
      permanent!('Stored email routing acknowledgement is invalid') unless
        payload['phase'] == 'ACKNOWLEDGEMENT' && payload['tenant_id'] == ENV.fetch('WASALX_TENANT_ID') &&
        payload['instance_id'] == ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID') &&
        payload['ticket_id'].to_s == ticket.id.to_s && payload['article_id'].to_s == article.id.to_s &&
        payload['route_id'].to_s.match?(UUID) && %w[APPLIED MANUAL_OVERRIDE].include?(payload['application_status'].to_s) &&
        valid_positive_id?(payload['observed_group_id']) &&
        (payload['observed_owner_id'].nil? || valid_positive_id?(payload['observed_owner_id']))
      payload
    end

    def exact_payload!(value, keys)
      permanent!('Stored email routing payload is unavailable') unless value.is_a?(Hash)
      payload = value.to_h.deep_stringify_keys
      permanent!('Stored email routing payload is invalid') unless payload.keys.sort == keys
      payload
    end

    def valid_positive_id?(value)
      Integer(value.to_s, 10).positive?
    rescue ArgumentError, TypeError
      false
    end

    def valid_nonnegative_integer?(value)
      Integer(value.to_s, 10) >= 0
    rescue ArgumentError, TypeError
      false
    end

    def valid_email?(value)
      return false unless value.is_a?(String) && value.length.between?(1, 320) && !value.match?(/[\x00-\x1f\x7f]/)
      Mail::Address.new(value).address.to_s.strip.downcase == value
    rescue StandardError
      false
    end

    def valid_admission_timestamp?(value)
      value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/) && Time.iso8601(value).year >= 2000
    rescue ArgumentError
      false
    end

    def permanent!(message)
      raise Wasalx::Client::PermanentRequestFailed, message
    end
  end

  def perform(payload)
    input = payload.to_h.deep_stringify_keys.symbolize_keys
    phase = input[:phase].to_s
    return perform_acknowledgement(input) if phase == 'ACKNOWLEDGEMENT'
    raise Wasalx::Client::PermanentRequestFailed, 'Routing job phase is invalid' if phase.present?

    source = source_article!(input, 'wasalx_email_routing_payload')
    source_state = source.preferences['wasalx_email_routing_state'].to_s
    return if %w[APPLIED FAILED_TERMINAL].include?(source_state)
    raise Wasalx::Client::PermanentRequestFailed, 'Routing source state is invalid' if source_state != 'PENDING'

    result = Wasalx::Client.post(
      '/internal/v1/zammad/routing',
      input.slice(:tenant_id, :instance_id, :ticket_id, :article_id, :ticket_number, :sender_email, :admitted_at, :entry_group_id),
      scope: 'zammad:routing'
    )
    validate_routing_result!(result)
    raise Wasalx::Client::PermanentRequestFailed, 'WasalX returned another ticket' if result['ticket_id'].to_s != input.fetch(:ticket_id).to_s
    raise Wasalx::Client::PermanentRequestFailed, 'WasalX returned another article' if result['source_article_id'].to_s != input.fetch(:article_id).to_s
    route_id = result.fetch('route_id').to_s
    raise Wasalx::Client::PermanentRequestFailed, 'Routing identifier is invalid' unless route_id.match?(UUID)

    status = result.fetch('status').to_s
    raise Wasalx::Client::PermanentRequestFailed, 'Routing status is invalid' if !%w[MATCHED FALLBACK UNCONFIGURED].include?(status)
    routed = result['routed'] == true
    if routed != %w[MATCHED FALLBACK].include?(status)
      raise Wasalx::Client::PermanentRequestFailed, 'Routing result is internally inconsistent'
    end
    group_id = routed ? positive_id(result.fetch('zammad_group_id'), 'Zammad group') : nil
    owner_id = result['owner_id'].nil? ? nil : positive_id(result['owner_id'], 'Zammad owner')
    attributes = {
      wasalx_client_routing_version_id: result['routing_version_id'].to_s.presence,
      wasalx_client_id: result['client_id'].to_s.presence,
      wasalx_client_route_status: status,
      wasalx_client_route_matched_by: result['matched_by'].to_s.presence
    }
    expected_group_id = input.fetch(:expected_group_id).to_i
    expected_owner_id = input.fetch(:expected_owner_id).to_i
    expected_revision = nonnegative_integer(input.fetch(:expected_assignment_revision), 'Assignment revision')
    target_assignment = group_id ? [group_id, owner_id || expected_owner_id] : [expected_group_id, expected_owner_id]
    applied_revision = expected_revision + (target_assignment == [expected_group_id, expected_owner_id] ? 0 : 1)

    ticket = Ticket.find(input.fetch(:ticket_id))
    ticket.with_lock do
      article = Ticket::Article.find(input.fetch(:article_id))
      article.lock!
      source_article!(input, 'wasalx_email_routing_payload', article)
      current_state = article.preferences['wasalx_email_routing_state'].to_s
      if current_state != 'PENDING'
        validate_existing_projection!(ticket, attributes) if current_state == 'APPLIED'
        return if %w[APPLIED FAILED_TERMINAL].include?(current_state)
        raise Wasalx::Client::PermanentRequestFailed, 'Routing source state changed unexpectedly'
      end

      application_status = nil
      Transaction.execute({ reset_user_id: true }) do
        if group_id && ticket.wasalx_assignment_revision.to_i != expected_revision
          attributes[:wasalx_client_route_status] = 'MANUAL_OVERRIDE'
          application_status = 'MANUAL_OVERRIDE'
        else
          attributes[:group_id] = group_id if group_id
          attributes[:owner_id] = owner_id if owner_id
          application_status = 'APPLIED'
        end
        ticket.update!(attributes)
      end
      ticket.reload
      if application_status == 'APPLIED' && group_id && (
        ticket.wasalx_assignment_revision.to_i != applied_revision || !applied_target?(ticket, group_id, owner_id)
      )
        Transaction.execute({ reset_user_id: true }) do
          ticket.update!(wasalx_client_route_status: 'MANUAL_OVERRIDE')
        end
        ticket.reload
        application_status = 'MANUAL_OVERRIDE'
      end
      acknowledgement_payload = {
        'phase' => 'ACKNOWLEDGEMENT', 'tenant_id' => input.fetch(:tenant_id),
        'instance_id' => input.fetch(:instance_id), 'route_id' => route_id,
        'ticket_id' => input.fetch(:ticket_id), 'article_id' => input.fetch(:article_id),
        'application_status' => application_status, 'observed_group_id' => ticket.group_id.to_s,
        'observed_owner_id' => ticket.owner_id.to_i.positive? ? ticket.owner_id.to_s : nil
      }
      preferences = (article.preferences || {}).deep_dup
      preferences['wasalx_email_routing_state'] = 'APPLIED'
      preferences['wasalx_email_routing_ack_payload'] = acknowledgement_payload
      preferences['wasalx_email_routing_ack_state'] = 'PENDING'
      preferences.delete('wasalx_email_routing_error_code')
      preferences.delete('wasalx_email_routing_ack_error_code')
      Transaction.execute({ reset_user_id: true }) do
        article.update!(preferences: preferences)
        self.class.perform_later(acknowledgement_payload)
      end
    end
  rescue Wasalx::Client::PermanentRequestFailed, KeyError, ArgumentError, TypeError => error
    raise error unless record_terminal_failure(input || {}, phase.to_s)
  end

  def perform_acknowledgement(input)
    source = source_article!(input, 'wasalx_email_routing_ack_payload')
    source_state = source.preferences['wasalx_email_routing_ack_state'].to_s
    return if %w[SUCCEEDED FAILED_TERMINAL].include?(source_state)
    raise Wasalx::Client::PermanentRequestFailed, 'Routing acknowledgement state is invalid' if source_state != 'PENDING'

    route_id = input.fetch(:route_id).to_s
    raise Wasalx::Client::PermanentRequestFailed, 'Routing identifier is invalid' unless route_id.match?(UUID)
    application_status = input.fetch(:application_status).to_s
    unless %w[APPLIED MANUAL_OVERRIDE].include?(application_status)
      raise Wasalx::Client::PermanentRequestFailed, 'Routing application status is invalid'
    end
    observed_group_id = positive_id(input.fetch(:observed_group_id), 'Observed Zammad group').to_s
    observed_owner_id = input[:observed_owner_id].nil? ? nil : positive_id(input[:observed_owner_id], 'Observed Zammad owner').to_s
    acknowledgement = Wasalx::Client.post(
      '/internal/v1/zammad/routing/acknowledgement',
      {
        tenant_id: input.fetch(:tenant_id), instance_id: input.fetch(:instance_id),
        route_id: route_id, ticket_id: input.fetch(:ticket_id), article_id: input.fetch(:article_id),
        idempotency_key: "wasalx-routing-ack:#{route_id}", application_status: application_status,
        observed_group_id: observed_group_id, observed_owner_id: observed_owner_id
      },
      scope: 'zammad:routing'
    )
    validate_acknowledgement!(acknowledgement, route_id, application_status, observed_group_id, observed_owner_id)

    ticket = Ticket.find(input.fetch(:ticket_id))
    ticket.with_lock do
      article = Ticket::Article.find(input.fetch(:article_id))
      article.lock!
      source_article!(input, 'wasalx_email_routing_ack_payload', article)
      preferences = (article.preferences || {}).deep_dup
      return if preferences['wasalx_email_routing_ack_state'] == 'SUCCEEDED'
      raise Wasalx::Client::PermanentRequestFailed, 'Routing acknowledgement state changed unexpectedly' if preferences['wasalx_email_routing_ack_state'] != 'PENDING'
      preferences['wasalx_email_routing_ack_state'] = 'SUCCEEDED'
      preferences.delete('wasalx_email_routing_ack_error_code')
      Transaction.execute({ reset_user_id: true }) do
        article.update!(preferences: preferences)
      end
    end
  end

  private

  def record_retry_exhaustion
    input = arguments.first.to_h.deep_stringify_keys.symbolize_keys
    ticket_id = Integer(input[:ticket_id].to_s, 10, exception: false)
    article_id = Integer(input[:article_id].to_s, 10, exception: false)
    logger.error("event=wasalx_ticket_routing_retry_exhausted job_id=#{job_id} ticket_id=#{ticket_id} article_id=#{article_id}")
    record_terminal_failure(input, input[:phase].to_s)
  end

  def source_article!(input, preference_key, existing = nil)
    article = existing || Ticket::Article.find(input.fetch(:article_id))
    raise Wasalx::Client::PermanentRequestFailed, 'Routing source article does not belong to this ticket' if article.ticket_id.to_s != input.fetch(:ticket_id).to_s
    stored = (article.preferences || {})[preference_key]
    expected = input.to_h.deep_stringify_keys
    raise Wasalx::Client::PermanentRequestFailed, 'Stored routing provenance does not match the job' unless stored.is_a?(Hash) && stored.to_h.deep_stringify_keys == expected
    article
  end

  def record_terminal_failure(input, phase)
    ticket = Ticket.find_by(id: input[:ticket_id])
    article = Ticket::Article.find_by(id: input[:article_id])
    return false if !ticket || !article || article.ticket_id != ticket.id
    ticket.with_lock do
      article.lock!
      preferences = (article.preferences || {}).deep_dup
      payload_key = phase == 'ACKNOWLEDGEMENT' ? 'wasalx_email_routing_ack_payload' : 'wasalx_email_routing_payload'
      stored_payload = preferences[payload_key]
      expected_payload = input.to_h.deep_stringify_keys
      return false unless stored_payload.is_a?(Hash) && stored_payload.to_h.deep_stringify_keys == expected_payload
      if phase == 'ACKNOWLEDGEMENT'
        return true if preferences['wasalx_email_routing_ack_state'] == 'FAILED_TERMINAL'
        return false if preferences['wasalx_email_routing_ack_state'] != 'PENDING'
        preferences['wasalx_email_routing_ack_state'] = 'FAILED_TERMINAL'
        preferences['wasalx_email_routing_ack_error_code'] = TERMINAL_FAILURE_CODE
        should_note = preferences['wasalx_email_routing_ack_failure_noted'] != true
        preferences['wasalx_email_routing_ack_failure_noted'] = true if should_note
        Transaction.execute({ reset_user_id: true }) do
          article.update!(preferences: preferences)
          create_terminal_failure_note!(ticket, article, phase) if should_note
        end
        return true
      end
      return true if preferences['wasalx_email_routing_state'] == 'FAILED_TERMINAL'
      return false if preferences['wasalx_email_routing_state'] != 'PENDING'
      preferences['wasalx_email_routing_state'] = 'FAILED_TERMINAL'
      preferences['wasalx_email_routing_error_code'] = TERMINAL_FAILURE_CODE
      should_note = preferences['wasalx_email_routing_failure_noted'] != true
      preferences['wasalx_email_routing_failure_noted'] = true if should_note
      Transaction.execute({ reset_user_id: true }) do
        article.update!(preferences: preferences)
        ticket.update!(wasalx_client_route_status: 'FAILED_TERMINAL') if ticket.wasalx_client_route_status == 'PENDING'
        create_terminal_failure_note!(ticket, article, phase) if should_note
      end
    end
    true
  end

  def create_terminal_failure_note!(ticket, article, phase)
    Ticket::Article.create!(
      ticket_id: ticket.id, content_type: 'text/plain',
      body: "#{TERMINAL_FAILURE_MESSAGE} (#{TERMINAL_FAILURE_CODE})", internal: true,
      sender: Ticket::Article::Sender.find_by(name: 'System'),
      type: Ticket::Article::Type.find_by(name: 'note'),
      preferences: { wasalx_email_routing_failure: true, wasalx_email_routing_failure_phase: phase, source_article_id: article.id },
      updated_by_id: 1, created_by_id: 1
    )
  end

  def positive_id(value, label)
    number = Integer(value, 10)
    raise Wasalx::Client::PermanentRequestFailed, "#{label} is invalid" if number <= 0
    number
  rescue ArgumentError, TypeError
    raise Wasalx::Client::PermanentRequestFailed, "#{label} is invalid"
  end

  def nonnegative_integer(value, label)
    number = Integer(value.to_s, 10)
    raise Wasalx::Client::PermanentRequestFailed, "#{label} is invalid" if number.negative?
    number
  rescue ArgumentError, TypeError
    raise Wasalx::Client::PermanentRequestFailed, "#{label} is invalid"
  end

  def validate_acknowledgement!(acknowledgement, route_id, application_status, group_id, owner_id)
    valid = acknowledgement.is_a?(Hash) && acknowledgement['acknowledged'] == true &&
      [true, false].include?(acknowledgement['duplicate']) && acknowledgement['route_id'].to_s == route_id &&
      acknowledgement['application_status'].to_s == application_status &&
      acknowledgement['observed_group_id'].to_s == group_id &&
      acknowledgement.key?('observed_owner_id') && acknowledgement['observed_owner_id']&.to_s == owner_id
    return if valid
    raise Wasalx::Client::TemporaryRequestFailed, 'Routing acknowledgement response is invalid'
  end

  def validate_routing_result!(result)
    raise Wasalx::Client::PermanentRequestFailed, 'Routing response is invalid' unless result.is_a?(Hash)
    status = result['status'].to_s
    case status
    when 'UNCONFIGURED'
      valid = result['routed'] == false &&
        %w[routing_version_id client_id matched_by zammad_group_id owner_id].all? { |key| result[key].nil? }
    when 'FALLBACK'
      valid = result['routed'] == true && result['routing_version_id'].to_s.present? &&
        result['client_id'].nil? && result['matched_by'].to_s == 'FALLBACK' && result['zammad_group_id'].present?
    when 'MATCHED'
      valid = result['routed'] == true && result['routing_version_id'].to_s.present? &&
        result['client_id'].to_s.present? && %w[EMAIL DOMAIN CLIENT_IDENTIFIER].include?(result['matched_by'].to_s) &&
        result['zammad_group_id'].present?
    else
      valid = false
    end
    raise Wasalx::Client::PermanentRequestFailed, 'Routing response is invalid' unless valid
  end

  def validate_existing_projection!(ticket, attributes)
    expected_status = attributes.fetch(:wasalx_client_route_status)
    actual_status = ticket.wasalx_client_route_status.to_s
    status_matches = actual_status == expected_status || (actual_status == 'MANUAL_OVERRIDE' && expected_status != 'UNCONFIGURED')
    fields_match = ticket.wasalx_client_routing_version_id.to_s.presence == attributes[:wasalx_client_routing_version_id] &&
      ticket.wasalx_client_id.to_s.presence == attributes[:wasalx_client_id] &&
      ticket.wasalx_client_route_matched_by.to_s.presence == attributes[:wasalx_client_route_matched_by]
    return if status_matches && fields_match
    raise Wasalx::Client::PermanentRequestFailed, 'Existing ticket routing metadata conflicts with the pinned route'
  end

  def applied_target?(ticket, group_id, owner_id)
    return false if ticket.group_id.to_i != group_id
    return ticket.owner_id.to_i == owner_id if owner_id
    true
  end
end
