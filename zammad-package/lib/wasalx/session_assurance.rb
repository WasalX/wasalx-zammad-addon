# SPDX-License-Identifier: AGPL-3.0-only
require 'digest'
# Copyright (c) 2026 WasalX
require 'uri'

module Wasalx
  # Proof belongs to one native Rails session, never to a User or browser input.
  module SessionAssurance
    CALLBACK = 'wasalx.verified_oidc'.freeze
    PROOF = 'wasalx_oidc_assurance'.freeze
    NATIVE_LOGIN = 'wasalx_native_authentication'.freeze
    REFERENCE = 'wasalx_rails_session'.freeze
    RECOVERY = 'wasalx_oidc_recovery'.freeze
    MAX_INTEGER = 9_007_199_254_740_991

    def self.value(hash, key)
      hash[key] || hash[key.to_sym]
    end

    def self.text?(value, maximum = 255)
      value.is_a?(String) && !value.empty? && value.length <= maximum && !value.match?(/[\p{Cc}\p{Cf}\s]/)
    end

    def self.values?(values)
      values.is_a?(Array) && values.length <= 32 && values.uniq == values && values.all? { |entry| text?(entry, 128) }
    end

    def self.subject?(subject)
      subject.is_a?(String) && subject.valid_encoding? && !subject.empty? &&
        subject.codepoints.sum { |point| point > 0xffff ? 2 : 1 } <= 320 &&
        !subject.match?(/[\p{Cc}\p{Cf}]/) && !subject.match?(/\A[[:space:]\u00a0]|[[:space:]\u00a0]\z/)
    end

    def self.policy(value)
      return unless value.is_a?(Hash) && [true, false].include?(value['mfa_required']) &&
                    value['session_timeout_minutes'].is_a?(Integer) && (15..1440).cover?(value['session_timeout_minutes']) &&
                    value['policy_version'].is_a?(Integer) && (1..MAX_INTEGER).cover?(value['policy_version']) &&
                    subject?(value['subject']) && values?(value['mfa_amr_values']) && values?(value['mfa_acr_values'])
      value
    end

    def self.configuration
      settings = Setting.get('auth_openid_connect_credentials')
      return unless settings.is_a?(Hash)
      issuer = value(settings, 'issuer')
      client = value(settings, 'identifier')
      return unless text?(issuer, 2048) && text?(client)
      [issuer.delete_suffix('/'), client]
    end

    def self.private_id(session)
      session&.id&.private_id
    end

    def self.stored_session(reference, user)
      return unless text?(reference, 512)
      stored = ActiveRecord::SessionStore::Session.find_by(session_id: reference)
      return unless stored && value(stored.data, 'user_id').to_s == user.id.to_s
      stored
    end

    def self.recent?(timestamp, policy, now = Time.now.to_i)
      timestamp.is_a?(Integer) && (0..MAX_INTEGER).cover?(timestamp) && timestamp <= now + 5 &&
        now - timestamp <= policy.fetch('session_timeout_minutes') * 60
    end

    def self.authoritative_mfa?(proof, policy)
      methods = proof['amr'] || []
      return false unless methods.is_a?(Array) && methods.length <= 32 && methods.all? { |entry| entry.is_a?(String) && entry.length <= 128 }
      normalized = methods.map { |entry| entry.strip.downcase }
      return true if policy.fetch('mfa_amr_values').any? { |entry| normalized.include?(entry) }
      context = proof['acr']
      context.is_a?(String) && context.length <= 128 && policy.fetch('mfa_acr_values').include?(context.strip)
    end

    def self.proof_valid?(proof, token, subject, policy)
      configured = configuration
      proof.is_a?(Hash) && token.is_a?(String) && !token.empty? && token.bytesize <= 32_768 && configured &&
        proof['issuer'] == configured[0] && proof['client_id'] == configured[1] &&
        proof['subject'] == subject && subject == policy['subject'] &&
        proof['token_sha256'] == Digest::SHA256.hexdigest(token) &&
        (!policy['mfa_required'] || (recent?(proof['auth_time'], policy) && authoritative_mfa?(proof, policy)))
    end

    def self.allowed?(user, membership, result, reference:, session: nil, auth_type: 'session')
      current = policy(result['authentication_policy'])
      return false unless current && current['subject'] == membership.subject
      # Human API/basic credentials cannot supply the required verified SSO session.
      return !current['mfa_required'] unless auth_type == 'session'
      return false unless reference
      stored = stored_session(reference, user)
      return false unless stored
      data = session || stored.data
      return false unless value(data, 'user_id').to_s == user.id.to_s
      proof = value(data, PROOF)
      if proof
        return false unless proof.is_a?(Hash)
        return false unless proof['native_user_id'] == user.id.to_s && proof['rails_session_id'] == reference
        return proof_valid?(proof, value(data, 'oidc_id_token'), membership.subject, current) &&
          (current['mfa_required'] || recent?(proof['native_authenticated_at'], current)) &&
          Wasalx::SessionRefresh.allowed?(reference, proof)
      end
      # Non-required roles retain native password/SSO authentication. The native
      # server's creation time is conservative and is not asserted as OIDC MFA.
      native = value(data, NATIVE_LOGIN)
      # A legacy OIDC session has no renewable grant until normal SSO enrollment;
      # it must not fall through to the native-password compatibility path.
      return false if value(data, 'oidc_id_token') && native.nil?
      if native
        return false unless native.is_a?(Hash) && native['native_user_id'] == user.id.to_s && native['rails_session_id'] == reference
      end
      !current['mfa_required'] && recent?(native ? native['native_authenticated_at'] : stored.created_at&.to_i, current)
    end

    module OidcVerification
      private
      def verify_id_token!(id_token)
        env.delete(Wasalx::SessionAssurance::CALLBACK)
        super
        return unless id_token.is_a?(String) && !id_token.empty? && id_token.bytesize <= 32_768
        # Reuse the provider's verified decoder; raw_info can contain userinfo
        # claims and is therefore not an ID-token assurance source.
        claims = decode_id_token(id_token).raw_attributes
        issuer = options.issuer.to_s.delete_suffix('/')
        client = client_options.identifier
        return unless claims['iss'] == issuer && Array(claims['aud']).include?(client) && Wasalx::SessionAssurance.subject?(claims['sub'])
        env[Wasalx::SessionAssurance::CALLBACK] = {
          'issuer' => issuer, 'client_id' => client, 'subject' => claims['sub'],
          'auth_time' => claims['auth_time'], 'amr' => claims['amr'], 'acr' => claims['acr'],
          'sid' => claims['sid'], 'nonce' => claims['nonce'],
          'token_sha256' => Digest::SHA256.hexdigest(id_token),
        }
      end

      public
      def request_phase
        marker = session[Wasalx::SessionAssurance::RECOVERY]
        if marker.is_a?(Hash) && marker['armed'] == true && marker['until'].is_a?(Integer) && marker['until'] >= Time.now.to_i
          marker['armed'] = false
          # This existing realm context requests recovery only. It is never an
          # accepted proof value unless Source's active policy also accepts it.
          options.acr_values = 'urn:wasalx:loa:2'
          options.prompt = 'login'
        end
        super
      end
    end

    module OidcCallback
      def create_omniauth
        auth = request.env['omniauth.auth']
        request.env.delete(Wasalx::SessionRefresh::PENDING)
        session.delete(Wasalx::SessionAssurance::PROOF)
        session.delete(Wasalx::SessionAssurance::NATIVE_LOGIN)
        return super unless auth && auth['provider'] == 'openid_connect'
        readiness = Wasalx::Client.post('/internal/v1/zammad/membership/identity', { subject: auth['uid'] }, scope: 'zammad:membership')
        raise Authorization::Provider::AccountError unless readiness.is_a?(Hash) && [true, false].include?(readiness['enabled'])
        return super if readiness['enabled'] == false
        current = Wasalx::SessionAssurance.policy(readiness['authentication_policy'])
        native_id = readiness['native_user_id']
        authorization = Authorization.find_by(provider: 'openid_connect', uid: auth['uid'])
        raise Authorization::Provider::AccountError unless current && authorization && native_id == authorization.user_id.to_s && current['subject'] == auth['uid']
        proof = request.env[Wasalx::SessionAssurance::CALLBACK]
        token = auth.dig('credentials', 'id_token')
        return wasalx_assurance_recovery unless Wasalx::SessionAssurance.proof_valid?(proof, token, auth['uid'], current)
        refresh_token = auth.dig('credentials', 'refresh_token')
        unless Wasalx::SessionRefresh.credential?(refresh_token) && Wasalx::SessionAssurance.text?(proof['sid'], 512)
          raise Authorization::Provider::AccountError
        end
        old_reference = Wasalx::SessionAssurance.private_id(session)
        return_to = session[:doorkeeper_return_to]
        return_to = nil unless return_to.is_a?(String) && return_to.match?(%r{\A/oauth/authorize(?:\z|[/?#])})
        # Rails destroys the old stored session and issues a fresh ID. Verified
        # callback state is in request.env; retain only core's approved OAuth path.
        reset_session
        @_current_user = @_user_on_behalf = nil
        session[:doorkeeper_return_to] = return_to if return_to
        reference = Wasalx::SessionAssurance.private_id(session)
        raise Authorization::Provider::AccountError unless Wasalx::SessionAssurance.text?(reference, 512) && reference != old_reference
        result = super
        # Native callback writes the authenticated user/token before returning.
        reference = Wasalx::SessionAssurance.private_id(session)
        if session[:user_id].to_s == native_id && session[:oidc_id_token].is_a?(String) &&
           Digest::SHA256.hexdigest(session[:oidc_id_token]) == proof['token_sha256'] &&
           Wasalx::SessionAssurance.text?(reference, 512) && reference != old_reference
          session[Wasalx::SessionAssurance::PROOF] = proof.merge('native_user_id' => native_id,
            'rails_session_id' => reference, 'native_authenticated_at' => Time.now.to_i)
          session.delete(Wasalx::SessionAssurance::RECOVERY)
          raise Authorization::Provider::AccountError unless session[:oidc_sid] == proof['sid']
          request.env[Wasalx::SessionRefresh::PENDING] = {
            'proof' => session[Wasalx::SessionAssurance::PROOF].dup, 'refresh_token' => refresh_token }
        else
          session.delete(:user_id)
          raise Authorization::Provider::AccountError
        end
        result
      rescue Wasalx::Client::RequestFailed, Authorization::Provider::AccountError
        request.env.delete(Wasalx::SessionRefresh::PENDING)
        raise Exceptions::NotAuthorized, 'Workspace access is not available'
      ensure
        request.env.delete(Wasalx::SessionAssurance::CALLBACK)
      end

      private
      def initiate_session_for(user, type = 'password')
        result = super
        session.delete(Wasalx::SessionAssurance::PROOF)
        session[Wasalx::SessionAssurance::NATIVE_LOGIN] = { 'native_user_id' => user.id.to_s,
          'rails_session_id' => Wasalx::SessionAssurance.private_id(session), 'native_authenticated_at' => Time.now.to_i }
        result
      end

      def wasalx_assurance_recovery
        # No native login is granted while the required claims are absent. This
        # explicit CSRF-protected button is bounded and never auto-redirects.
        marker = session[Wasalx::SessionAssurance::RECOVERY]
        marker = { 'until' => Time.now.to_i + 600, 'attempts' => 0 } unless marker.is_a?(Hash) && marker['until'].is_a?(Integer) && marker['until'] >= Time.now.to_i
        marker['attempts'] += 1
        marker['armed'] = marker['attempts'] <= 2
        session[Wasalx::SessionAssurance::RECOVERY] = marker
        session.delete(:user_id)
        session.delete(:oidc_id_token)
        @_current_user = nil
        # Native callback recreates device state from this request after session
        # rotation; never restore old device/session fields to carry it forward.
        fingerprint = request.env.dig('omniauth.params', 'fingerprint')
        raise Exceptions::UnprocessableContent, 'Invalid browser fingerprint' unless fingerprint.nil? || fingerprint.is_a?(String)
        UserDevice.fingerprint_validation(fingerprint)
        # OmniAuth2 stores only request.GET for the callback. Match the native
        # sign-in URL; a hidden POST field is discarded by that middleware.
        recovery_path = '/auth/openid_connect'
        recovery_path += "?#{URI.encode_www_form(fingerprint: fingerprint)}" if fingerprint
        render inline: <<~ERB, locals: { recovery_path: recovery_path }, status: :forbidden
          <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Verify your identity</title></head>
          <body><main><h1>Verify your identity</h1><p>Sign in again with WasalX SSO and complete the required authentication.</p>
          <% if session[Wasalx::SessionAssurance::RECOVERY]['armed'] %>
            <%= form_tag(recovery_path, method: :post) do %>
              <button type="submit">Verify with WasalX SSO</button><% end %>
          <% else %><p>Verification could not be completed. Contact your workspace administrator before trying again.</p><% end %>
          <a href="/#login">Return to sign in</a></main></body></html>
        ERB
      end
    end

    module LegacyLogin
      def run
        previous = Thread.current[:wasalx_native_login]
        public_id = @payload['session_id']
        reference = public_id.is_a?(String) && public_id.bytesize <= 512 ? Rack::Session::SessionId.new(public_id).private_id : nil
        stored = reference && ActiveRecord::SessionStore::Session.find_by(session_id: reference)
        Thread.current[:wasalx_native_login] = stored && { reference: reference, user_id: Wasalx::SessionAssurance.value(stored.data, 'user_id') }
        super
      ensure
        Thread.current[:wasalx_native_login] = previous
      end
    end

    module LegacySession
      def create(client_id, data, meta)
        binding = Thread.current[:wasalx_native_login]
        if binding && data.is_a?(Hash) && data['id'] == binding[:user_id]
          data[Wasalx::SessionAssurance::REFERENCE] = binding[:reference]
        end
        super
      end
    end
  end
end
