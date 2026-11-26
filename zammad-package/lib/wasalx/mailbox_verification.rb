# SPDX-License-Identifier: AGPL-3.0-only
require 'timeout'
# Copyright (c) 2026 WasalX

module Wasalx
  # Native Delayed::Job payload contains identifiers/binding only; credentials stay in Channel.
  MailboxVerification = Struct.new(:channel_id, :version, :binding) do
    def perform
      Channel.connection_pool.with_connection do |connection|
        key = PortalMailboxAdministration.effect_lock_key(channel_id)
        # A duplicate worker must never declare an active sender dead. A session
        # lock survives short DB transactions and is released on process death.
        acquired = connection.select_value("SELECT pg_try_advisory_lock(#{key})")
        return unless acquired
        begin
          perform_locked
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{key})")
        end
      end
    end

    def perform_locked
      actor = bound_actor!
      state = nil
      Transaction.execute do
        channel = Channel.lock.find(channel_id)
        verification = current!(channel)
        next unless verification
        state = verification['state']
        if state == 'SENDING'
          # A killed worker can leave the remote SMTP result unknown. Never resend automatically.
          verification['state'] = 'UNKNOWN'
          channel.save!
          state = nil
          next
        end
        unless %w[QUEUED AWAITING UNKNOWN].include?(state)
          state = nil
          next
        end
        PortalMailboxAdministration.assert_transport!(channel)
        verification['state'] = 'SENDING' if state == 'QUEUED'
        channel.save! if state == 'QUEUED'
      end
      return unless state
      channel = Channel.find(channel_id)
      return unless current!(channel)
      address = EmailAddress.find_by!(channel_id: channel.id, active: true)
      marker = "wasalx-mail-#{binding.fetch('operation_id')}"
      if state == 'QUEUED'
        bound_actor!
        UserInfo.with_user_id(actor.id) do
          # No stock probe: only this owned mailbox receives this explicit WasalX test.
          Timeout.timeout(90) do
            MailboxVerificationSmtp.new.deliver(channel.options.fetch(:outbound).fetch(:options).deep_dup,
              { from: address.email, to: address.email, subject: "WasalX verification #{marker}",
                body: 'This message verifies your WasalX customer email account. No customer conversation was sent.',
                'X-Zammad-Test-Message' => marker, 'X-Zammad-Ignore' => 'true',
                'X-Zammad-Verify' => 'true', 'X-Zammad-Verify-Time' => Time.current.iso8601,
                'X-Loop' => 'yes', 'Auto-Submitted' => 'auto-generated', 'Precedence' => 'bulk' })
          end
        end
        transition!('AWAITING')
      end
      9.times do
        bound_actor!
        channel = Channel.find(channel_id)
        return unless current!(channel)
        driver = Channel::Driver::Imap.new
        begin
          result = Timeout.timeout(15) { driver.verify_transport(channel.options.fetch(:inbound).fetch(:options).deep_dup, marker) }
          if result[:result] == 'ok'
            transition!('VERIFIED')
            return
          end
        ensure
          driver.disconnect
        end
        sleep 5
      end
      transition!('UNKNOWN')
    rescue StandardError
      # Never serialize/log native errors: authentication and server notices may contain secrets.
      transition!('UNKNOWN')
    end

    def bound_actor!
      row = WasalxMembership.find_by!(portal_user_id: binding.fetch('user_id'), tenant_id: binding.fetch('tenant_id'), instance_id: binding.fetch('instance_id'))
      raise Exceptions::Forbidden unless row.member_state == 'ACTIVE' && row.revision == binding.fetch('revision') && row.subject == binding.fetch('subject') && row.user_id.to_s == binding.fetch('native_user_id')
      actor = User.find(row.user_id)
      raise Exceptions::Forbidden unless actor.active && !ServiceIdentity.automation?(actor) && %w[tenant_owner tenant_admin].include?(row.portal_role)
      actor.permissions!('admin.channel_email')
      raise Exceptions::Forbidden unless MembershipProjection.native_access_matches?(actor, row.portal_role, row.member_state) &&
        Authorization.where(provider: 'openid_connect', uid: row.subject).pluck(:user_id) == [actor.id]
      result = Client.post('/internal/v1/zammad/membership/check',
        { user_id: row.portal_user_id, native_user_id: actor.id.to_s, revision: row.revision, privileged: true }, scope: 'zammad:membership')
      policy = result.is_a?(Hash) && SessionAssurance.policy(result['authentication_policy'])
      assurance = binding.fetch('assurance')
      minutes = result.is_a?(Hash) && result['privileged_reauth_minutes']
      raise Exceptions::Forbidden unless result.is_a?(Hash) && result['allowed'] == true && policy &&
        policy['subject'] == row.subject && result['portal_source'] == binding.fetch('source') &&
        assurance.is_a?(Hash) && SessionAssurance.recent?(assurance['auth_time'], policy) &&
        SessionAssurance.authoritative_mfa?(assurance, policy) && minutes.is_a?(Integer) && (5..120).cover?(minutes) &&
        Time.now.to_i - assurance['auth_time'] <= minutes * 60
      actor
    end

    def current!(channel)
      verification = channel.preferences['wasalx_mail_verification'] || {}
      return unless verification['operation_id'] == binding['operation_id'] && verification['binding'] == binding && verification['version'] == version && PortalMailboxAdministration.version(channel) == version && !channel.active
      verification
    end

    def transition!(state)
      Transaction.execute do
        channel = Channel.lock.find_by(id: channel_id)
        return unless channel
        verification = current!(channel)
        return unless verification
        return if verification['state'] == 'VERIFIED' && state != 'VERIFIED'
        verification['state'] = state
        verification['checked_at'] = Time.current.utc.iso8601(6)
        channel.save!
      end
    rescue ActiveRecord::ActiveRecordError
      # Original durable state remains unconfirmed, never falsely verified.
      nil
    end
  end
end
