# SPDX-License-Identifier: AGPL-3.0-only
require 'base64'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'json'
require 'net/http'
require 'openssl'
require 'securerandom'
require 'timeout'
require 'uri'

module Wasalx
  class Client
    class RequestFailed < StandardError
      def retryable?
        false
      end
    end

    class TemporaryRequestFailed < RequestFailed
      def retryable?
        true
      end
    end

    class PermanentRequestFailed < RequestFailed; end

    def self.post(path, payload, scope: 'zammad:outbound', actor: nil)
      request_json(Net::HTTP::Post, path, payload, scope: scope, actor: actor)
    end

    def self.get(path, scope: 'zammad:health', actor: nil)
      request_json(Net::HTTP::Get, path, nil, scope: scope, actor: actor)
    end

    def self.request_json(request_class, path, payload, scope:, actor:)
      uri = URI.join(ENV.fetch('WASALX_CONTROL_URL'), path)
      request = request_class.new(uri)
      request['Authorization'] = "Bearer #{service_token(scope, actor)}"
      request['Accept'] = 'application/json'
      if payload
        request['Content-Type'] = 'application/json'
        request['Idempotency-Key'] = payload[:idempotency_key] if payload[:idempotency_key]
        request.body = payload.to_json
      end
      request['X-Request-ID'] = SecureRandom.uuid
      request['User-Agent'] = 'WasalX-Zammad/0.5'
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http.open_timeout = 5
      http.read_timeout = 15
      response = http.start do
        http.request(request)
      end
      if !response.is_a?(Net::HTTPSuccess)
        error = retryable_status?(response.code.to_i) ? TemporaryRequestFailed : PermanentRequestFailed
        raise error, "WasalX returned HTTP #{response.code}"
      end

      parsed = JSON.parse(response.body)
      raise TemporaryRequestFailed, 'WasalX returned an invalid JSON value' if !parsed.is_a?(Hash) && !parsed.is_a?(Array)

      parsed
    rescue JSON::ParserError
      raise TemporaryRequestFailed, 'WasalX returned an invalid JSON response'
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError, EOFError,
           SystemCallError, OpenSSL::SSL::SSLError => e
      raise TemporaryRequestFailed, "WasalX request failed (#{e.class.name})"
    end

    def self.service_token(scope, actor)
      now = Time.now.to_i
      claims = {
        iss: 'wasalx-zammad', aud: 'wasalx-control', sub: ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'),
        tenant_id: ENV.fetch('WASALX_TENANT_ID'), instance_id: ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'),
        scope: scope, iat: now, exp: now + 120, jti: SecureRandom.uuid
      }
      claims.merge!(actor_claims(actor)) if actor
      header = base64url({ alg: 'HS256', typ: 'JWT' }.to_json)
      payload = base64url(claims.to_json)
      signature = OpenSSL::HMAC.digest('SHA256', ENV.fetch('WASALX_SERVICE_JWT_SECRET'), "#{header}.#{payload}")
      "#{header}.#{payload}.#{base64url(signature)}"
    end

    def self.actor_claims(actor)
      user_id = actor.fetch(:user_id).to_s
      group_ids = Array(actor[:group_ids]).map(&:to_s).uniq
      valid = /\A[1-9][0-9]{0,15}\z/
      raise ArgumentError, 'Invalid Zammad agent identity' if !user_id.match?(valid)
      raise ArgumentError, 'Invalid Zammad agent groups' if group_ids.length > 100 || group_ids.any? { |id| !id.match?(valid) }

      { zammad_user_id: user_id, zammad_group_ids: group_ids, zammad_group_admin: actor[:group_admin] == true }
    end

    def self.base64url(value)
      Base64.urlsafe_encode64(value, padding: false)
    end

    def self.retryable_status?(status)
      [408, 425, 429].include?(status) || status >= 500
    end
    private_class_method :request_json, :service_token, :actor_claims, :base64url, :retryable_status?
  end
end
