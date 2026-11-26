# SPDX-License-Identifier: AGPL-3.0-only
require 'openssl'
# Copyright (c) 2026 WasalX

class Api::V1::WasalxRoutingConfigurationsController < ApplicationController
  prepend_before_action :authentication_check

  def create
    # Unlike legacy service endpoints, configuration writes never admit an
    # administrator or a PREPARED handover token in place of the bound machine.
    raise Exceptions::Forbidden, 'Not authorized' unless Wasalx::ServiceIdentity.token_allowed?(current_user, @_token, 'runtime')

    body = request.raw_post
    timestamp = request.headers['X-Wasalx-Timestamp'].to_s
    signature = request.headers['X-Wasalx-Signature'].to_s
    valid = body.bytesize <= 5 * 1024 * 1024 && timestamp.match?(/\A[0-9]{10}\z/) && (Time.now.to_i - timestamp.to_i).abs <= 30
    raise Exceptions::Forbidden, 'Not authorized' unless valid
    expected = OpenSSL::HMAC.hexdigest('SHA256', ENV.fetch('WASALX_SERVICE_JWT_SECRET'), "#{timestamp}\n#{body}")
    raise Exceptions::Forbidden, 'Not authorized' unless signature.match?(/\A[a-f0-9]{64}\z/) && ActiveSupport::SecurityUtils.secure_compare(signature, expected)

    render json: Wasalx::RoutingConfiguration.call(JSON.parse(body), service_user: current_user)
  rescue JSON::ParserError, Wasalx::RoutingConfiguration::InvalidRequest
    render json: { error_code: 'ROUTING_CONFIGURATION_INVALID' }, status: :bad_request
  end
end
