# SPDX-License-Identifier: AGPL-3.0-only
require 'openssl'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'json'
require 'base64'

module Wasalx
  # Portal requests have their own verified assurance; they never mint a Rails session.
  module PortalDelegation
    PURPOSE = 'wasalx.portal-workspace.v1'.freeze
    PATH = '/api/v1/wasalx/portal-workspace'.freeze
    OPERATIONS = %w[PRIVACY_TARGET CHECK LIST SHOW ARTICLES ARTICLE_CONTENT SOURCE_CONTEXT CREATE_OPTIONS CREATE_TICKET CREATE_RECEIPT ATTACHMENT REPLY UPDATE RECEIPT PREVIEW
      GROUP_MEDIA GROUP_REMOVE_UPLOAD REMOVE_UPLOAD GROUP_CHECK GROUP_LIST GROUP_SHOW GROUP_MESSAGES GROUP_CONTEXT GROUP_PARTICIPANTS GROUP_TICKETS GROUP_TEAMS
      GROUP_READ GROUP_SEND GROUP_REACTION GROUP_CREATE_TICKET GROUP_LINK_TICKET GROUP_RECEIPT
      GROUP_TICKET_RECEIPT GROUP_REPAIR_TICKET_LINK TEAM_LIST TEAM_SHOW TEAM_CREATE TEAM_SAVE TEAM_GRANT_SAVE TEAM_RECEIPT
      MAILBOX_LIST MAILBOX_SHOW MAILBOX_CREATE MAILBOX_SAVE MAILBOX_VERIFY_START MAILBOX_VERIFY_STATUS MAILBOX_VERIFY_RECHECK
      MAILBOX_ACTIVATE MAILBOX_PAUSE MAILBOX_RECEIPT MAILBOX_SIGNATURE_SHOW MAILBOX_SIGNATURE_SAVE].freeze
    UPLOAD_PURPOSE = 'wasalx.portal-workspace-upload.v1'.freeze
    UPLOAD_PATH = '/api/v1/wasalx/portal-workspace/upload'.freeze
    UUID = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i
    class Invalid < StandardError; end

    def self.decode(body, timestamp, signature, secret:, tenant:, instance:, now: Time.now.to_i)
      decode_envelope(body, timestamp, signature, secret: secret, tenant: tenant, instance: instance, now: now,
        purpose: PURPOSE, path: PATH, operations: OPERATIONS, upload: false)
    end

    IDENTITY_PURPOSE = 'wasalx.service-identity.v1'.freeze
    IDENTITY_PATH = '/api/v1/wasalx/service/identity'.freeze
    IDENTITY_OPERATIONS = %w[IDENTITY_STATUS IDENTITY_INITIALIZE IDENTITY_PREPARE IDENTITY_GRANT IDENTITY_BIND IDENTITY_COMPLETE IDENTITY_RECEIPT].freeze

    def self.decode_identity(body, timestamp, signature, secret:, tenant:, instance:, now: Time.now.to_i)
      decode_envelope(body, timestamp, signature, secret: secret, tenant: tenant, instance: instance, now: now,
        purpose: IDENTITY_PURPOSE, path: IDENTITY_PATH, operations: IDENTITY_OPERATIONS, upload: false)
    end

    def self.decode_upload(encoded, timestamp, signature, secret:, tenant:, instance:, now: Time.now.to_i)
      raise Invalid unless encoded.bytesize.between?(1, 8_000) && encoded.match?(/\A[A-Za-z0-9_-]+\z/)
      body = Base64.urlsafe_decode64(encoded)
      raise Invalid unless Base64.urlsafe_encode64(body, padding: false) == encoded && body.bytesize <= 6000
      decode_envelope(body, timestamp, signature, secret: secret, tenant: tenant, instance: instance, now: now,
        purpose: UPLOAD_PURPOSE, path: UPLOAD_PATH, operations: %w[GROUP_UPLOAD TICKET_UPLOAD], upload: true)
    rescue ArgumentError
      raise Invalid
    end

    def self.decode_envelope(body, timestamp, signature, secret:, tenant:, instance:, now:, purpose:, path:, operations:, upload:)
      raise Invalid unless body.bytesize <= 65_536 && timestamp.match?(/\A[0-9]{10}\z/) &&
                           now - timestamp.to_i <= 30 && timestamp.to_i <= now + 5
      expected = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{purpose}\nPOST\n#{path}\n#{timestamp}\n#{body}")
      raise Invalid unless signature.match?(/\A[a-f0-9]{64}\z/) && OpenSSL.fixed_length_secure_compare(signature, expected)
      value = JSON.parse(body)
      keys!(value, %w[purpose tenant_id instance_id source actor assurance operation input] + (upload ? ['file'] : []))
      raise Invalid unless value['purpose'] == purpose && value['tenant_id'] == tenant && value['instance_id'] == instance &&
                           operations.include?(value['operation']) && value['input'].is_a?(Hash)
      keys!(value['source'], %w[issuer audience])
      raise Invalid unless %w[issuer audience].all? { |key| text?(value['source'][key], 2048) }
      actor = value['actor']
      identity = purpose == IDENTITY_PURPOSE
      keys!(actor, %w[user_id subject revision native_user_id] + (identity ? ['email'] : []))
      raise Invalid unless actor['user_id'].is_a?(String) && UUID.match?(actor['user_id']) &&
                           text?(actor['subject'], 320) && actor['revision'].is_a?(Integer) &&
                           (1..9_007_199_254_740_991).cover?(actor['revision']) &&
                           ((identity && actor['native_user_id'].nil?) || actor['native_user_id'].is_a?(String) && actor['native_user_id'].match?(/\A[1-9][0-9]{0,15}\z/)) &&
                           (!identity || text?(actor['email'], 320))
      assurance = value['assurance']
      keys!(assurance, %w[auth_time amr acr])
      raise Invalid unless assurance['auth_time'].is_a?(Integer) &&
                           assurance['amr'].is_a?(Array) && assurance['amr'].length <= 32 &&
                           assurance['amr'].all? { |entry| text?(entry, 128) } &&
                           (assurance['acr'].nil? || text?(assurance['acr'], 128))
      validate_upload!(value) if upload
      value
    rescue JSON::ParserError, TypeError
      raise Invalid
    end


    def self.validate_upload!(value)
      input = value.fetch('input')
      target = value['operation'] == 'GROUP_UPLOAD' ? 'group_id' : input.key?('ticket_id') ? 'ticket_id' : 'create_group_id'
      keys!(input, ['upload_cache_id', target])
      raise Invalid unless input['upload_cache_id'].is_a?(String) && UUID.match?(input['upload_cache_id']) &&
        input[target].is_a?(String) && (target == 'group_id' ? UUID : /\A[1-9][0-9]{0,15}\z/).match?(input[target])
      file = value.fetch('file')
      keys!(file, %w[filename mime_type byte_size sha256])
      raise Invalid unless text?(file['filename'], 120) && file['filename'] == file['filename'].unicode_normalize(:nfc) &&
        !file['filename'].match?(/[\p{Cc}\p{Cf}\/\\]/) && text?(file['mime_type'], 120) &&
        file['mime_type'].match?(/\A[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*\z/) &&
        file['byte_size'].is_a?(Integer) && file['byte_size'].between?(1, 50_000_000) &&
        file['sha256'].is_a?(String) && file['sha256'].match?(/\A[a-f0-9]{64}\z/)
    end
    private_class_method :decode_envelope, :validate_upload!

    def self.keys!(value, keys)
      raise Invalid unless value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def self.text?(value, maximum)
      value.is_a?(String) && value.length.between?(1, maximum) && value == value.strip && !value.match?(/[[:cntrl:]]/)
    end
  end
end
