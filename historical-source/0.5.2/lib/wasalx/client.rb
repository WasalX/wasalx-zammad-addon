# SPDX-License-Identifier: AGPL-3.0-only
require 'base64'
# Copyright (c) 2026 WasalX
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

    def self.post(path, payload, scope: 'zammad:outbound')
      request_json(Net::HTTP::Post, path, payload, scope: scope)
    end

    def self.get(path, scope: 'zammad:health')
      request_json(Net::HTTP::Get, path, nil, scope: scope)
    end

    def self.request_json(request_class, path, payload, scope:)
      uri = URI.join(ENV.fetch('WASALX_CONTROL_URL'), path)
      request = request_class.new(uri)
      request['Authorization'] = "Bearer #{service_token(scope)}"
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
      raise TemporaryRequestFailed, 'WasalX returned an invalid JSON object' if !parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise TemporaryRequestFailed, 'WasalX returned an invalid JSON response'
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError, EOFError,
           SystemCallError, OpenSSL::SSL::SSLError => e
      raise TemporaryRequestFailed, "WasalX request failed (#{e.class.name})"
    end

    def self.service_token(scope)
      now = Time.now.to_i
      claims = {
        iss: 'wasalx-zammad', aud: 'wasalx-control', sub: ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'),
        tenant_id: ENV.fetch('WASALX_TENANT_ID'), instance_id: ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'),
        scope: scope, iat: now, exp: now + 120, jti: SecureRandom.uuid
      }
      header = base64url({ alg: 'HS256', typ: 'JWT' }.to_json)
      payload = base64url(claims.to_json)
      signature = OpenSSL::HMAC.digest('SHA256', ENV.fetch('WASALX_SERVICE_JWT_SECRET'), "#{header}.#{payload}")
      "#{header}.#{payload}.#{base64url(signature)}"
    end

    def self.base64url(value)
      Base64.urlsafe_encode64(value, padding: false)
    end

    def self.retryable_status?(status)
      [408, 425, 429].include?(status) || status >= 500
    end
    private_class_method :request_json, :service_token, :base64url, :retryable_status?
  end
end
