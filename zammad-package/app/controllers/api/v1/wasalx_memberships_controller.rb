# SPDX-License-Identifier: AGPL-3.0-only
require 'openssl'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>

class Api::V1::WasalxMembershipsController < ApplicationController
  prepend_before_action :authentication_check

  def create
    # A native administrator alone cannot assert an identity. Both the installed
    # service credential and the tenant/instance-bound signing secret are required.
    Wasalx::ServiceIdentity.authorize!(current_user, @_token)
    body = request.raw_post
    timestamp = request.headers['X-Wasalx-Timestamp'].to_s
    signature = request.headers['X-Wasalx-Signature'].to_s
    raise Exceptions::Forbidden, 'Not authorized' unless body.bytesize <= 8_192 && timestamp.match?(/\A[0-9]{10}\z/) && (Time.now.to_i - timestamp.to_i).abs <= 30
    expected = OpenSSL::HMAC.hexdigest('SHA256', ENV.fetch('WASALX_SERVICE_JWT_SECRET'), "#{timestamp}\n#{body}")
    raise Exceptions::Forbidden, 'Not authorized' unless signature.match?(/\A[a-f0-9]{64}\z/) && ActiveSupport::SecurityUtils.secure_compare(signature, expected)

    payload = JSON.parse(body)
    render json: Wasalx::MembershipProjection.call(payload, service_user: current_user)
  rescue JSON::ParserError, ArgumentError
    render json: { error: 'Invalid workspace identity request' }, status: :bad_request
  end
end
