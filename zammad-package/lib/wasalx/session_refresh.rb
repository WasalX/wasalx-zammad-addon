# SPDX-License-Identifier: AGPL-3.0-only
require 'json'
# Copyright (c) 2026 WasalX
require 'net/http'
require 'openssl'
require 'securerandom'
require 'timeout'

module Wasalx
  # The grant lives with one Rails session, outside its whole-hash data writer.
  module SessionRefresh
    COLUMN = 'wasalx_oidc_refresh_state'.freeze
    PENDING = 'wasalx.oidc_refresh_enrollment'.freeze
    INTERVAL = 300
    NETWORK_LIMIT = 8
    WAIT_LIMIT = NETWORK_LIMIT + 2
    LIMIT = 65_536

    # Native admin session lists serialize the base store model directly.
    # Filter after native options/methods are applied; persistence still sees it.
    module Serialization
      def serializable_hash(options = nil)
        super(options).except(Wasalx::SessionRefresh::COLUMN)
      end
    end

    def self.protect_models!
      # SQL bind logging uses Base's filter; model inspection has its own list.
      ActiveRecord::Base.filter_attributes |= [COLUMN]
      [ActiveRecord::SessionStore::Session, ::Session].uniq.each do |model|
        model.attr_readonly COLUMN
        model.filter_attributes |= [COLUMN]
        model.prepend(Serialization) unless model < Serialization
      end
    end

    def self.credential?(value)
      SessionAssurance.text?(value, 32_768) && value.bytesize <= 32_768
    end

    def self.encryptor
      key = Rails.application.key_generator.generate_key('wasalx/native-oidc-refresh/v1', 32)
      ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm', serializer: JSON)
    end

    def self.seal(state, reference)
      encryptor.encrypt_and_sign(state, purpose: "wasalx/native-oidc-refresh/v1/#{reference}")
    end

    def self.open(ciphertext, reference)
      return unless ciphertext.is_a?(String) && ciphertext.bytesize <= LIMIT
      encryptor.decrypt_and_verify(ciphertext, purpose: "wasalx/native-oidc-refresh/v1/#{reference}")
    end

    def self.rows
      ActiveRecord::SessionStore::Session
    end

    def self.row(reference)
      rows.uncached { rows.find_by(session_id: reference) }
    end

    def self.bound?(record, state, proof, reference)
      state.is_a?(Hash) && state['proof'] == proof && proof.is_a?(Hash) &&
        proof['rails_session_id'] == reference && SessionAssurance.text?(proof['sid'], 512) &&
        SessionAssurance.value(record.data, 'user_id').to_s == proof['native_user_id'] &&
        SessionAssurance.value(record.data, 'oidc_sid') == proof['sid'] &&
        SessionAssurance.value(record.data, SessionAssurance::PROOF) == proof &&
        Digest::SHA256.hexdigest(SessionAssurance.value(record.data, 'oidc_id_token').to_s) == proof['token_sha256']
    end

    def self.write!(record, state, reference)
      ciphertext = seal(state, reference)
      raise 'Native refresh state too large' unless ciphertext.bytesize <= LIMIT
      count = rows.where(id: record.id, session_id: reference).update_all(COLUMN => ciphertext)
      raise 'Native session disappeared' unless count == 1
    end

    def self.discard(reference)
      rows.where(session_id: reference).delete_all
      false
    end

    def self.enroll!(reference, pending)
      record = row(reference)
      return false unless record
      record.with_lock do
        state = { 'phase' => 'READY', 'proof' => pending.fetch('proof'),
                  'refresh_token' => pending.fetch('refresh_token'), 'checked_at' => Time.now.to_i }
        raise 'Native session state rejected' unless bound?(record, state, pending['proof'], reference) && credential?(state['refresh_token'])
        # An enrollment is exclusive to this fresh callback; never replace an
        # existing grant or unresolved intent through an ordinary session save.
        raise 'Native session state rejected' unless record.read_attribute(COLUMN).nil?
        write!(record, state, reference)
      end
      true
    rescue StandardError
      discard(reference)
    end

    def self.allowed?(reference, proof)
      # Never send a grant while an outer transaction could roll back its intent.
      outer_transaction = rows.connection.transaction_open?
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WAIT_LIMIT
      loop do
        record = row(reference)
        return false unless record
        claim = nil
        ready = false
        record.with_lock do
          state = open(record.read_attribute(COLUMN), reference)
          raise 'Native session state rejected' unless bound?(record, state, proof, reference)
          checked = state['checked_at']
          raise 'Native session state rejected' unless checked.is_a?(Integer) && checked >= 0 && checked <= Time.now.to_i + 5
          if state['phase'] == 'READY'
            raise 'Native session state rejected' unless credential?(state['refresh_token'])
            if Time.now.to_i - checked < INTERVAL
              ready = true
            else
              return false if outer_transaction
              # The intent must COMMIT before the POST. Process loss cannot
              # roll it back and make an already-consumed credential reusable.
              operation = SecureRandom.hex(16)
              claim = state.merge('operation' => operation)
              intent = state.reject { |key, _| key == 'refresh_token' }
              write!(record, intent.merge('phase' => 'IN_FLIGHT', 'operation' => operation,
                                         'started_at' => Time.now.to_i), reference)
            end
          elsif state['phase'] == 'IN_FLIGHT'
            started = state['started_at']
            raise 'Native session state rejected' unless started.is_a?(Integer) && started <= Time.now.to_i + 5 &&
                                             Time.now.to_i - started <= WAIT_LIMIT
          else
            raise 'Native session state rejected'
          end
        end
        return true if ready
        return finish(reference, proof, claim) if claim
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.05
      end
    rescue StandardError
      discard(reference)
    end

    def self.finish(reference, proof, claim)
      response = Timeout.timeout(NETWORK_LIMIT) { refresh(claim) }
      record = row(reference)
      return false unless record
      record.with_lock do
        state = open(record.read_attribute(COLUMN), reference)
        raise 'Native session state rejected' unless bound?(record, state, proof, reference) &&
                                         state['phase'] == 'IN_FLIGHT' && state['operation'] == claim['operation']
        write!(record, { 'phase' => 'READY', 'proof' => proof, 'checked_at' => Time.now.to_i,
                         'refresh_token' => response.fetch('refresh_token') }, reference)
      end
      true
    rescue StandardError
      # No retry after invalid_grant, transport uncertainty, verification or
      # persistence failure; other sessions belonging to this user are untouched.
      discard(reference)
    end

    def self.refresh(claim)
      proof = claim.fetch('proof')
      strategy = OmniAuth::Strategies::OidcDatabase.new(nil)
      strategy.send(:discover!)
      configured = SessionAssurance.configuration
      raise 'Native identity configuration changed' unless configured == [proof['issuer'], proof['client_id']]
      uri = URI(strategy.options.client_options.token_endpoint)
      issuer = URI(proof.fetch('issuer'))
      raise 'Invalid native token endpoint' unless uri.is_a?(URI::HTTPS) && uri.userinfo.nil? && uri.fragment.nil? &&
                                                  uri.host == issuer.host && uri.port == issuer.port
      client = strategy.options.client_options
      raise 'Native identity configuration changed' unless client.identifier == proof['client_id'] &&
        strategy.options.issuer.to_s.delete_suffix('/') == proof['issuer']
      method = strategy.options.client_auth_method.to_s
      # Native OidcDatabase is a public client. Do not substitute an admin or
      # application grant, or guess an unsupported client authentication method.
      raise 'Unsupported native client authentication' unless client.secret.to_s.empty? && ['', 'not_required'].include?(method)
      response = token_response(uri, proof.fetch('client_id'), claim.fetch('refresh_token'))
      token = response['id_token']
      raise 'Missing renewed ID token' unless credential?(token)
      decoded = strategy.send(:decode_id_token, token) # Native signature/algorithm verifier.
      claims = decoded.raw_attributes
      nonce = claims['nonce'].nil? ? nil : proof['nonce']
      decoded.verify!(issuer: proof['issuer'], client_id: proof['client_id'], nonce: nonce)
      raise 'Renewed native identity mismatch' unless claims['iss'] == proof['issuer'] &&
        Array(claims['aud']).include?(proof['client_id']) && claims['sub'] == proof['subject'] &&
        claims['sid'] == proof['sid'] && (!claims.key?('azp') || claims['azp'] == proof['client_id']) &&
        (Array(claims['aud']).length == 1 || claims['azp'] == proof['client_id']) &&
        claims['iat'].is_a?(Integer) && claims['iat'] >= 0 && claims['iat'] <= Time.now.to_i + 5 &&
        renewed_authentication_time_valid?(claims, proof)
      renewed = response.fetch('refresh_token', claim.fetch('refresh_token'))
      raise 'Missing renewed grant' unless credential?(renewed)
      { 'refresh_token' => renewed }
    end

    def self.renewed_authentication_time_valid?(claims, proof)
      return true unless claims.key?('auth_time')
      renewed = claims['auth_time']
      original = proof['auth_time']
      # Another client's fresh MFA can advance Keycloak's shared SSO time.
      # Validate it without replacing this native session's original age/proof.
      renewed.is_a?(Integer) && renewed >= 0 && claims['iat'].is_a?(Integer) && renewed <= claims['iat'] &&
        (original.nil? || (original.is_a?(Integer) && renewed >= original))
    end

    def self.token_response(uri, identifier, refresh_token)
      request = Net::HTTP::Post.new(uri.request_uri)
      request['Accept'] = 'application/json'
      request.set_form_data(grant_type: 'refresh_token', client_id: identifier, refresh_token: refresh_token)
      # Explicit nil proxy prevents credentials being delegated through ambient
      # HTTP proxy configuration. Net::HTTP performs no POST retry or redirect.
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = http.read_timeout = http.write_timeout = NETWORK_LIMIT
      http.max_retries = 0
      body = +''
      http.start do |connection|
        connection.request(request) do |response|
          raise 'Native refresh refused' unless response.code == '200'
          response.read_body do |chunk|
            body << chunk
            raise 'Native refresh response too large' if body.bytesize > LIMIT
          end
        end
      end
      result = JSON.parse(body)
      raise 'Invalid native refresh response' unless result.is_a?(Hash) && result['token_type'].to_s.casecmp('bearer').zero?
      result
    end

    module Store
      private
      def write_session(request, sid, data, options)
        pending = request.env.delete(Wasalx::SessionRefresh::PENDING)
        saved = super
        return saved unless pending
        return false unless saved && Wasalx::SessionRefresh.enroll!(saved.private_id, pending)
        saved
      end
    end
  end
end
