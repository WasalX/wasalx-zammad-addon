# SPDX-License-Identifier: AGPL-3.0-only
require 'openssl'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'digest'
require 'cgi'
require_relative 'portal_mail'

module Wasalx
  class PortalMailboxAdministration
    class Conflict < StandardError; end
    class StorageError < StandardError; end
    WRITES = %w[MAILBOX_CREATE MAILBOX_SAVE MAILBOX_VERIFY_START MAILBOX_VERIFY_RECHECK MAILBOX_ACTIVATE MAILBOX_PAUSE MAILBOX_SIGNATURE_SAVE].freeze

    def initialize(actor:, envelope:, authorizer:)
      @actor, @envelope, @input = actor, envelope, envelope.fetch('input')
      @kind = envelope.fetch('operation')
      @authorizer = authorizer
    end

    def call
      authorize!
      case @kind
      when 'MAILBOX_LIST'
        keys!(%w[before])
        rows = Channel.where(area: 'Email::Account').order(:id)
        rows = rows.where('id > ?', id!(@input['before'])) if @input['before']
        page = rows.limit(101).to_a
        { items: page.first(100).map { |row| show(row) }, next_cursor: page.length > 100 ? page[99].id.to_s : nil,
          mail_ready: PortalMail.review[:ready] == true,
          can_create: ENV.fetch('WASALX_MAIL_ALLOWED_HOSTS', '').split(',').any? { |host| host.strip.present? } }
      when 'MAILBOX_SHOW', 'MAILBOX_VERIFY_STATUS'
        keys!(%w[mailbox_id operation_id])
        show(channel!)
      when 'MAILBOX_SIGNATURE_SHOW'
        keys!(%w[team_id]); @actor.permissions!('admin.group')
        group = Group.find(id!(@input['team_id']))
        signature = group.signature
        html = signature&.body.to_s
        plain = html.gsub(/<br\s*\/?\s*>/i, "\n").gsub(%r{</(?:p|div)>}i, "\n")
        { team_id: group.id.to_s, version: self.class.signature_version(group), body: CGI.unescapeHTML(ActionController::Base.helpers.strip_tags(plain)),
          requires_plain_replacement: html.gsub(/<br\s*\/?\s*>/i, '').match?(/<[^>]+>/), applies_to_team: true }
      when 'MAILBOX_RECEIPT'
        reconcile
      when *WRITES
        mutate
      else
        raise ArgumentError
      end
    rescue ActiveRecord::RecordNotFound
      raise
    rescue ActiveRecord::ActiveRecordError
      # Database exception details can include the serialized write-only credentials.
      raise StorageError, 'Mailbox storage unavailable', cause: nil
    end

    def self.digest(value)
      OpenSSL::HMAC.hexdigest('SHA256', ENV.fetch('WASALX_SERVICE_JWT_SECRET'), JSON.generate(ServiceIdentity.canonical(value)))
    end

    def self.version(channel)
      address = EmailAddress.where(channel_id: channel.id).order(:id).pluck(:id, :email, :name, :active)
      # Operational fetch logs and verification state do not change configuration version.
      digest([channel.id, channel.group_id, Group.where(id: channel.group_id).pick(:email_address_id), channel.options.deep_stringify_keys, address, channel.preferences['wasalx_mail_revision']])
    end

    def self.effect_lock_key(id)
      Digest::SHA256.hexdigest("portal-mailbox-effect:#{id}")[0, 15].to_i(16)
    end

    def self.seed_signature?(group)
      seed = '
  #{user.firstname} #{user.lastname}

--
 Super Support - Waterford Business Park
 5201 Blue Lagoon Drive - 8th Floor & 9th Floor - Miami, 33126 USA
 Email: hot@example.com - Web: http://www.example.com/
--'.text2html
      group.signature&.body.to_s == seed
    end

    def self.signature_version(group)
      signature = group.signature
      digest([group.id, group.signature_id, signature&.updated_at&.utc&.iso8601(6), signature&.body.to_s])
    end

    def self.editable?(channel)
      channel.options.dig(:inbound, :adapter).to_s.downcase == 'imap' && channel.options.dig(:outbound, :adapter).to_s.downcase == 'smtp' &&
        channel.options.dig(:auth, :type).blank? && channel.options.dig(:inbound, :options, :auth_type).to_s.upcase != 'XOAUTH2' && channel.options.dig(:outbound, :options, :authentication).to_s.downcase != 'xoauth2'
    end

    def self.assert_transport!(channel)
      raise ArgumentError unless editable?(channel)
      inbound, outbound = channel.options.dig(:inbound, :options), channel.options.dig(:outbound, :options)
      raise ArgumentError unless %w[on starttls].include?(inbound[:ssl]) && inbound[:ssl_verify] == true && outbound[:ssl_verify] == true &&
        (outbound[:ssl] == true || outbound[:wasalx_require_starttls] == true) && outbound[:openssl_verify_mode].to_s == 'peer'
      allowed = ENV.fetch('WASALX_MAIL_ALLOWED_HOSTS', '').split(',').map { |host| host.strip.downcase }.reject(&:empty?)
      raise ArgumentError unless [inbound[:host], outbound[:host]].all? { |host| allowed.include?(host.to_s.downcase) }
    end

    private

    def authorize!
      fresh = @authorizer.call
      raise Exceptions::Forbidden unless fresh && fresh.id == @actor.id
      @actor = fresh
      @actor.reload.permissions!('admin.channel_email')
    end

    def keys!(allowed)
      raise ArgumentError unless @input.is_a?(Hash) && (@input.keys - allowed).empty?
    end

    def id!(value)
      raise ArgumentError unless value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,15}\z/)
      value.to_i
    end

    def uuid!(value)
      raise ArgumentError unless value.is_a?(String) && PortalDelegation::UUID.match?(value)
      value.downcase
    end

    def text!(value, maximum)
      raise ArgumentError unless value.is_a?(String) && value.strip.length.between?(1, maximum) && !value.match?(/[[:cntrl:]]/)
      value.strip
    end

    def channel!
      Channel.find_by!(id: id!(@input['mailbox_id']), area: 'Email::Account')
    end

    def show(channel)
      inbound = channel.options.dig(:inbound, :options) || {}
      outbound = channel.options.dig(:outbound, :options) || {}
      address = EmailAddress.where(channel_id: channel.id).order(:id).first
      verification = channel.preferences['wasalx_mail_verification'] || {}
      state = %w[QUEUED SENDING AWAITING].include?(verification['state']) ? 'RUNNING' : verification.fetch('state', 'NOT_VERIFIED')
      { id: channel.id.to_s, active: channel.active, editable: self.class.editable?(channel), version: self.class.version(channel),
        team_name: Group.find_by(id: channel.group_id)&.name,
        inbound_credential_configured: inbound[:password].present?, outbound_credential_configured: outbound[:password].present?,
        verification: state, verification_operation_id: verification['operation_id'], verification_version: verification['version'],
        config: { email: address&.email.to_s, name: address&.name.to_s, team_id: channel.group_id.to_s,
          inbound: { host: inbound[:host].to_s, port: inbound[:port].to_i, user: inbound[:user].to_s, folder: inbound[:folder].presence || 'INBOX', security: inbound[:ssl] == 'starttls' ? 'STARTTLS' : 'TLS' },
          outbound: { host: outbound[:host].to_s, port: outbound[:port].to_i, user: outbound[:user].to_s, security: outbound[:ssl] == true ? 'TLS' : 'STARTTLS' } } }
    end

    def lock!(operation)
      Channel.connection.execute("SELECT pg_advisory_xact_lock(#{Digest::SHA256.hexdigest("portal-admin:#{operation}")[0, 15].to_i(16)})")
    end

    def receipt!(operation, kind, target)
      receipt = WasalxAdminOperation.find_by(operation_id: operation)
      return unless receipt
      raise Conflict unless receipt.portal_user_id == @envelope['actor']['user_id'] && receipt.native_user_id == @actor.id && receipt.kind == kind && receipt.target_id == target
      receipt
    end

    def record!(operation, kind, target, digest, result)
      WasalxAdminOperation.create!(operation_id: operation, portal_user_id: @envelope['actor']['user_id'], native_user_id: @actor.id,
        kind: kind, target_id: target, request_sha256: digest, result: result)
    end

    def target(kind = @kind)
      return nil if kind == 'MAILBOX_CREATE'
      kind == 'MAILBOX_SIGNATURE_SAVE' ? "team:#{id!(@input['team_id'])}" : id!(@input['mailbox_id']).to_s
    end

    def mutate
      allowed = case @kind
                when 'MAILBOX_CREATE' then %w[operation_id config credentials]
                when 'MAILBOX_SAVE' then %w[operation_id mailbox_id expected_version config credentials]
                when 'MAILBOX_SIGNATURE_SAVE' then %w[operation_id team_id expected_version body replace_formatting]
                else %w[operation_id mailbox_id expected_version]
                end
      keys!(allowed)
      operation, bound_target = uuid!(@input['operation_id']), target
      # HMAC prevents credential guessing from the retained request fingerprint; secrets themselves stay only in Channel.
      digest = self.class.digest([@kind, @input.merge('operation_id' => operation)])
      Transaction.execute do
        lock!(operation)
        authorize!
        if (old = receipt!(operation, @kind, bound_target))
          raise Conflict unless old.request_sha256 == digest && old.result['state'] == 'APPLIED'
          next old.result
        end
        if @kind == 'MAILBOX_SIGNATURE_SAVE'
          result = save_signature(operation)
        else
          Channel.connection.execute("SELECT pg_advisory_xact_lock(#{self.class.effect_lock_key(id!(@input['mailbox_id']))})") unless @kind == 'MAILBOX_CREATE'
          authorize!
          channel = @kind == 'MAILBOX_CREATE' ? nil : channel!
          channel.lock! if channel
          raise Conflict if channel && @input['expected_version'] != self.class.version(channel)
          case @kind
          when 'MAILBOX_CREATE', 'MAILBOX_SAVE' then channel = save_config(channel)
          when 'MAILBOX_VERIFY_START' then start_verification(channel, operation)
          when 'MAILBOX_VERIFY_RECHECK'
            self.class.assert_transport!(channel)
            verification = channel.preferences['wasalx_mail_verification'] || {}
            raise Conflict unless verification['state'] == 'UNKNOWN' && verification['version'] == self.class.version(channel)
            # Resume only receiving/checking the existing marker; never resubmit SMTP.
            verification['binding']['source'] = @envelope.fetch('source')
            verification['binding']['assurance'] = @envelope.fetch('assurance').deep_dup
            verification['state'] = 'AWAITING'
            channel.save!
            Delayed::Job.enqueue(Wasalx::MailboxVerification.new(channel.id, verification['version'], verification['binding']), queue: 'default')
          when 'MAILBOX_ACTIVATE' then activate(channel)
          when 'MAILBOX_PAUSE'
            channel.update!(active: false, updated_by_id: @actor.id)
          end
          result = { state: 'APPLIED', mailbox_id: channel.id.to_s }
        end
        record!(operation, @kind, bound_target, digest, result)
        result
      end
    end

    def configuration
      config = @input['config']
      raise ArgumentError unless config.is_a?(Hash) && config.keys.sort == %w[email inbound name outbound team_id]
      address = text!(config['email'], 320).downcase
      raise ArgumentError unless address.match?(/\A[^\s<>@]+@[^\s<>@]+\z/)
      name = text!(config['name'], 160)
      group = Group.lock.find(id!(config['team_id']))
      raise ArgumentError unless group.active
      [config, address, name, group]
    end

    def transport(config, direction, old)
      required = direction == 'inbound' ? %w[folder host port security user] : %w[host port security user]
      raise ArgumentError unless config.is_a?(Hash) && config.keys.sort == required
      host = text!(config['host'], 253).downcase
      raise ArgumentError unless host.match?(/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/) && !host.include?('..') && config['port'].is_a?(Integer) && (1..65535).cover?(config['port']) && %w[TLS STARTTLS].include?(config['security'])
      options = (old&.dig(:options) || {}).deep_dup.merge(host: host, port: config['port'], user: text!(config['user'], 320), ssl_verify: true)
      password = @input.fetch('credentials', {}).fetch(direction, old&.dig(:options, :password))
      raise ArgumentError unless password.is_a?(String) && password.length.between?(1, 4096) && !password.include?("\0")
      options[:password] = password
      if direction == 'inbound'
        retained = old&.dig(:options)&.key?(:keep_on_server) ? old[:options][:keep_on_server] : true
        options.merge!(folder: text!(config['folder'], 255), ssl: config['security'] == 'TLS' ? 'on' : 'starttls', keep_on_server: retained)
      else
        options.merge!(ssl: config['security'] == 'TLS', enable_starttls_auto: false,
          wasalx_require_starttls: config['security'] == 'STARTTLS', openssl_verify_mode: 'peer')
      end
      { adapter: direction == 'inbound' ? 'imap' : 'smtp', options: options }
    end

    def save_config(channel)
      # Native mailbox creation is rare: one admission lock keeps duplicate address/account
      # checks and their writes atomic across distinct operation IDs and destination teams.
      lock!('mailbox-config')
      raise Conflict if channel&.active
      raise Conflict if channel && %w[QUEUED SENDING AWAITING].include?(channel.preferences.dig('wasalx_mail_verification', 'state'))
      raise Exceptions::Forbidden if channel && !self.class.editable?(channel)
      credentials = @input.fetch('credentials', {})
      raise ArgumentError unless credentials.is_a?(Hash) && (credentials.keys - %w[inbound outbound]).empty?
      config, email, name, group = configuration
      options = { inbound: transport(config['inbound'], 'inbound', channel&.options&.dig(:inbound)), outbound: transport(config['outbound'], 'outbound', channel&.options&.dig(:outbound)) }
      duplicate = Channel.where(area: 'Email::Account').where.not(id: channel&.id).any? do |other|
        inbound = other.options.dig(:inbound, :options) || {}
        inbound.values_at(:host, :user, :folder) == options[:inbound][:options].values_at(:host, :user, :folder)
      end
      addresses = EmailAddress.where('lower(email) = ?', email)
      addresses = addresses.where.not(channel_id: channel.id) if channel
      raise Conflict if duplicate || addresses.exists?
      channel ||= Channel.new(area: 'Email::Account', active: false, created_by_id: @actor.id)
      channel.assign_attributes(group: group, options: options, updated_by_id: @actor.id)
      self.class.assert_transport!(channel)
      channel.preferences['wasalx_mail_revision'] = channel.preferences.fetch('wasalx_mail_revision', 0).to_i + 1
      channel.preferences['wasalx_mail_verification'] = { 'state' => 'NOT_VERIFIED' }
      channel.save!
      address = EmailAddress.where(channel_id: channel.id).order(:id).first || EmailAddress.new(channel_id: channel.id, created_by_id: @actor.id)
      raise Conflict if EmailAddress.where(channel_id: channel.id).count > 1
      address.update!(email: email, name: name, active: true, updated_by_id: @actor.id)
      channel
    end

    def start_verification(channel, operation)
      raise Conflict if channel.active
      self.class.assert_transport!(channel)
      prior = channel.preferences['wasalx_mail_verification'] || {}
      raise Conflict if %w[QUEUED SENDING AWAITING].include?(prior['state'])
      binding = @envelope.fetch('actor').slice('user_id', 'native_user_id', 'revision', 'subject').merge('tenant_id' => @envelope['tenant_id'], 'instance_id' => @envelope['instance_id'], 'operation_id' => operation, 'source' => @envelope.fetch('source'), 'assurance' => @envelope.fetch('assurance').deep_dup)
      version = self.class.version(channel)
      channel.preferences['wasalx_mail_verification'] = { 'state' => 'QUEUED', 'version' => version, 'operation_id' => operation, 'binding' => binding }
      channel.save!
      # Delayed::Job uses the same native database transaction; a job contains references only.
      Delayed::Job.enqueue(Wasalx::MailboxVerification.new(channel.id, version, binding), queue: 'default')
    end

    def activate(channel)
      raise Conflict unless PortalMail.review[:ready] == true
      self.class.assert_transport!(channel)
      verification = channel.preferences['wasalx_mail_verification'] || {}
      raise Conflict unless verification['state'] == 'VERIFIED' && verification['version'] == self.class.version(channel)
      group = Group.lock.find(channel.group_id)
      raise Conflict unless @input['expected_version'] == self.class.version(channel)
      @actor.permissions!('admin.group')
      raise Conflict if self.class.seed_signature?(group)
      address = EmailAddress.find_by!(channel_id: channel.id, active: true)
      Service::Channel::Email::UpdateDestinationGroupEmail.execute(group: group, channel: channel, email_address: address)
      channel.update!(active: true, updated_by_id: @actor.id)
    end

    def save_signature(operation)
      @actor.permissions!('admin.group')
      group = Group.lock.find(id!(@input['team_id']))
      raise Conflict unless @input['expected_version'] == self.class.signature_version(group)
      body = @input['body']
      raise ArgumentError unless body.is_a?(String) && body.length <= 4000 && !body.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)
      existing = group.signature
      raise Conflict if existing&.body.to_s.gsub(/<br\s*\/?\s*>/i, '').match?(/<[^>]+>/) && @input['replace_formatting'] != true
      # Copy-on-edit avoids altering another team's shared signature or attachment ownership.
      if body.strip.empty?
        group.screen = 'edit'
        group.update!(signature: nil, updated_by_id: @actor.id)
        return { state: 'APPLIED', team_id: group.id.to_s }
      end
      signature = Signature.create!(name: "WasalX team #{group.id} signature #{operation}", body: ERB::Util.html_escape(body).gsub("\n", '<br>'), active: true, created_by_id: @actor.id, updated_by_id: @actor.id)
      group.screen = 'edit'
      group.update!(signature: signature, updated_by_id: @actor.id)
      { state: 'APPLIED', team_id: group.id.to_s }
    end

    def reconcile
      keys!(%w[operation_id kind mailbox_id team_id cancel_if_missing])
      operation, kind = uuid!(@input['operation_id']), @input['kind']
      raise ArgumentError unless WRITES.include?(kind) && [true, false].include?(@input.fetch('cancel_if_missing', false))
      Transaction.execute do
        lock!(operation)
        authorize!
        if (receipt = receipt!(operation, kind, target(kind)))
          next receipt.result
        end
        next({ state: 'UNKNOWN' }) unless @input['cancel_if_missing']
        @actor.permissions!('admin.group') if %w[MAILBOX_ACTIVATE MAILBOX_SIGNATURE_SAVE].include?(kind)
        result = { state: 'CANCELLED' }
        record!(operation, kind, target(kind), nil, result)
        result
      end
    end
  end
end
