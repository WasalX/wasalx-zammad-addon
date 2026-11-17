# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
class Service::Ticket::Article::Type::WasalxGroupMessage::Deliver < Service::Base
  ARTICLE_TYPE = 'wasalx group message'.freeze
  MAX_ATTACHMENTS = 10
  MAX_FILENAME_LENGTH = 120
  TEMPORARY_FAILURE_CODE = 'WX-DELIVERY-TEMPORARY'.freeze
  TERMINAL_FAILURE_CODE = 'WX-DELIVERY-TERMINAL'.freeze
  TEMPORARY_FAILURE_MESSAGE = 'WasalX delivery is temporarily unavailable. Retry later.'.freeze
  TERMINAL_FAILURE_MESSAGE = 'WasalX delivery could not be queued. Contact an administrator.'.freeze
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  DELIVERY_STATES = %w[
    QUEUED SENDING SENT DELIVERED READ FAILED_RETRYABLE FAILED_TERMINAL OUTCOME_UNKNOWN
  ].freeze

  attr_reader :article, :ticket

  def self.execute(**arguments)
    new(**arguments).execute
  end

  def initialize(article_id:)
    @article = Ticket::Article.find(article_id)
    @ticket = Ticket.find(article.ticket_id)
  end

  def execute
    delivery_error = nil

    Transaction.execute({ reset_user_id: true }) do
      article.with_lock do
        # A duplicate ActiveJob is harmless after the first durable acceptance.
        # A crash before this preference commits repeats the HTTP request with the
        # same idempotency key, so WasalX still creates only one outbox record.
        next if delivered_to_wasalx?

        begin
          validate_article!
          validate_ticket!
          attachments = attachment_descriptors
          begin_delivery!

          response = Wasalx::Client.post(
            '/internal/v1/zammad/outbound',
            outbound_payload(attachments),
            scope: 'zammad:outbound',
            actor: agent_actor
          )
          record_acceptance!(response)
        rescue Wasalx::Client::TemporaryRequestFailed => e
          terminal = delivery_attempts >= 4
          record_failure!(e, terminal: terminal)
          delivery_error = e
        rescue Wasalx::Client::PermanentRequestFailed => e
          record_failure!(e, terminal: true)
          delivery_error = e
        rescue KeyError, ArgumentError => e
          permanent = Wasalx::Client::PermanentRequestFailed.new('WasalX delivery input was invalid')
          record_failure!(permanent, terminal: true)
          delivery_error = permanent
        end
      end
    end

    raise delivery_error if delivery_error

    article
  end

  private

  def validate_article!
    fail_permanently!('Internal WasalX articles are not communicative') if article.internal != false
    fail_permanently!('Provider-origin WasalX articles are not communicative') if provider_origin?

    sender = Ticket::Article::Sender.lookup(id: article.sender_id)
    fail_permanently!('Only agent-authored WasalX articles are communicative') if sender.nil? || sender.name != 'Agent'

    type = Ticket::Article::Type.lookup(id: article.type_id)
    fail_permanently!("Article type must be '#{ARTICLE_TYPE}'") if type.nil? || type.name != ARTICLE_TYPE
  end

  def validate_ticket!
    missing = %w[wasalx_connection_id wasalx_group_id].select do |attribute|
      !present_text?(ticket.public_send(attribute))
    end
    return if missing.empty?

    fail_permanently!("Missing WasalX ticket metadata: #{missing.join(', ')}")
  end

  def fail_permanently!(message)
    raise Wasalx::Client::PermanentRequestFailed, message
  end

  def begin_delivery!
    preferences['delivery_retry'] = delivery_attempts + 1
    preferences['delivery_status'] = 'pending'
    preferences['delivery_status_date'] = Time.zone.now
    preferences['delivery_status_message'] = nil
    preferences['wasalx_delivery_error_code'] = nil
    preferences['wasalx_delivery_state'] = 'SENDING'
    article.save!
    update_ticket_status!('SENDING')
  end

  def record_acceptance!(response)
    delivery_id = required_response_text(response, 'id')
    state = required_response_text(response, 'state')
    raise ArgumentError, 'WasalX response state is invalid' if !DELIVERY_STATES.include?(state)

    preferences['delivery_status'] = 'pending'
    preferences['delivery_status_date'] = Time.zone.now
    preferences['delivery_status_message'] = nil
    preferences['wasalx_delivery_id'] = delivery_id
    preferences['wasalx_delivery_state'] = state
    article.save!
    update_ticket_status!(state)
  end

  def record_failure!(_error, terminal:)
    state = terminal ? 'FAILED_TERMINAL' : 'FAILED_RETRYABLE'
    code = terminal ? TERMINAL_FAILURE_CODE : TEMPORARY_FAILURE_CODE
    message = __(terminal ? TERMINAL_FAILURE_MESSAGE : TEMPORARY_FAILURE_MESSAGE)

    preferences['delivery_status'] = 'fail'
    preferences['delivery_status_date'] = Time.zone.now
    preferences['delivery_status_message'] = message
    preferences['wasalx_delivery_error_code'] = code
    preferences['wasalx_delivery_state'] = state
    create_delivery_failed_article!(message, code) if terminal && !preferences['wasalx_delivery_failure_noted']
    article.save!
    update_ticket_status!(state)
  end

  def create_delivery_failed_article!(message, code)
    preferences['wasalx_delivery_failure_noted'] = true
    Ticket::Article.create!(
      ticket_id: ticket.id,
      content_type: 'text/plain',
      body: "#{message} (#{code})",
      internal: true,
      sender: Ticket::Article::Sender.find_by(name: 'System'),
      type: Ticket::Article::Type.find_by(name: 'note'),
      preferences: {
        delivery_article_id_related: article.id,
        delivery_message: true
      },
      updated_by_id: 1,
      created_by_id: 1
    )
  end

  def outbound_payload(attachments)
    {
      native_reply_intent_id: preferences['wasalx_native_reply_intent_id'],
      tenant_id: environment_uuid('WASALX_TENANT_ID'),
      connection_id: ticket.wasalx_connection_id,
      group_id: ticket.wasalx_group_id,
      ticket_id: ticket.id,
      article_id: article.id,
      body: outbound_body,
      content_type: 'text/plain',
      reply_to_article_id: reply_to_article_id,
      idempotency_key: idempotency_key,
      internal: false,
      agent: agent_identity,
      attachments: attachments
    }.compact
  end

  def reply_to_article_id
    Service::Ticket::WasalxReplyContext.article_id(
      ticket: ticket, requested: article.respond_to?(:in_reply_to) ? article.in_reply_to : nil,
      excluding_article_id: article.id
    )
  end

  def agent_identity
    Service::Ticket::WasalxReplyContext.agent_identity(user: article.created_by, id: article.created_by_id)
  end

  def agent_actor
    user = article.created_by
    fail_permanently!('Agent identity is missing') if user.nil?

    {
      user_id: article.created_by_id,
      group_ids: user.group_ids_access('read'),
      group_admin: user.permissions?('admin')
    }
  rescue NoMethodError, TypeError, ArgumentError
    fail_permanently!('Agent authorization context is invalid')
  end

  def outbound_body
    value = article.respond_to?(:body_as_text) ? article.body_as_text : article.body.to_s
    value.to_s
  end

  def attachment_descriptors
    stores = Array(article.attachments)
    stores.concat(Array(article.inline_attachments)) if article.respond_to?(:inline_attachments)
    stores = stores.uniq { |store| store.id.to_s }
    fail_permanently!("WasalX supports at most #{MAX_ATTACHMENTS} attachments per article") if stores.length > MAX_ATTACHMENTS

    stores.map do |store|
      attachment_id = Integer(store.id)
      fail_permanently!('Attachment ID must be positive') if attachment_id <= 0
      size = Integer(store.size)
      fail_permanently!('Attachment size must be positive') if size <= 0

      {
        id: attachment_id.to_s,
        filename: sanitize_filename(store.filename, attachment_id),
        content_type: attachment_content_type(store),
        size: size
      }
    rescue TypeError, ArgumentError
      fail_permanently!('Attachment descriptor is invalid')
    end
  end

  def attachment_content_type(store)
    values = store.preferences || {}
    value = %w[Content-Type Mime-Type content_type mime_type].map { |key| values[key] }.compact.first
    sanitize_text(value, maximum: 255, fallback: 'application/octet-stream')
  end

  def sanitize_filename(value, attachment_id)
    basename = File.basename(value.to_s.tr('\\', '/'))
    sanitize_text(basename, maximum: MAX_FILENAME_LENGTH, fallback: "attachment-#{attachment_id}")
  end

  def sanitize_text(value, maximum:, fallback:)
    text = value.to_s
    text = text.unicode_normalize(:nfc) if text.respond_to?(:unicode_normalize)
    text = text.gsub(/[[:cntrl:]\u200B-\u200F\u202A-\u202E\u2060-\u206F]/, ' ').gsub(/\s+/, ' ').strip
    text = text[0, maximum]
    text.empty? ? fallback : text
  end

  def required_response_text(response, key)
    value = response.fetch(key)
    raise ArgumentError, "WasalX response #{key} is invalid" if !present_text?(value)

    sanitize_text(value, maximum: 255, fallback: '')
  end

  def update_ticket_status!(state)
    ticket.update!(wasalx_delivery_status: state)
  end

  def idempotency_key
    [
      'zammad',
      environment_uuid('WASALX_TENANT_ID'),
      environment_uuid('WASALX_ZAMMAD_INSTANCE_ID'),
      ticket.id,
      article.id
    ].join(':')
  end

  def delivery_attempts
    preferences['delivery_retry'].to_i
  end

  def environment_uuid(name)
    value = ENV.fetch(name)
    raise ArgumentError, "#{name} must be a UUID" if !value.match?(UUID_PATTERN)

    value
  end

  def delivered_to_wasalx?
    present_text?(preferences['wasalx_delivery_id'])
  end

  def preferences
    article.preferences ||= {}
  end

  def present_text?(value)
    !value.nil? && !value.to_s.strip.empty?
  end

  def provider_origin?
    origin = preferences['wasalx_origin'] || preferences[:wasalx_origin]
    origin == 'provider' || article.subject == 'Sent from WhatsApp device'
  end
end
