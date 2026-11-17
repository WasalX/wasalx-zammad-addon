# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'minitest/autorun'
require_relative '../zammad-package/lib/wasalx/portal_delegation'

class PortalDelegationTest < Minitest::Test
  D = Wasalx::PortalDelegation
  def setup
    @now = 1_792_000_000
    @tenant = '10000000-0000-4000-8000-000000000001'
    @instance = '11000000-0000-4000-8000-000000000001'
    @value = { 'purpose' => D::PURPOSE, 'tenant_id' => @tenant, 'instance_id' => @instance,
      'source' => { 'issuer' => 'https://identity.example.test', 'audience' => 'api' },
      'actor' => { 'user_id' => @tenant, 'subject' => 'staff', 'revision' => 4, 'native_user_id' => '12' },
      'assurance' => { 'auth_time' => @now, 'amr' => ['mfa'], 'acr' => nil },
      'operation' => 'SHOW', 'input' => { 'ticket_id' => '42' } }
  end
  def decode(value = @value, timestamp: @now, tamper: false)
    body = JSON.generate(value)
    signature = OpenSSL::HMAC.hexdigest('SHA256', 'synthetic', "#{D::PURPOSE}\nPOST\n#{D::PATH}\n#{timestamp}\n#{body}")
    D.decode(tamper ? body.sub('staff', 'admin') : body, timestamp.to_s, signature,
      secret: 'synthetic', tenant: @tenant, instance: @instance, now: @now)
  end
  def test_accepts_exact_signed_request
    assert_equal @value, decode
    assert_equal @value, decode(timestamp: @now - 30)
    assert_equal @value, decode(timestamp: @now + 5)
  end
  def test_rejects_tampering_and_expired_or_future_signatures
    assert_raises(D::Invalid) { decode(tamper: true) }
    assert_raises(D::Invalid) { decode(timestamp: @now - 31) }
    assert_raises(D::Invalid) { decode(timestamp: @now + 6) }
  end
  def test_rejects_wrong_scope_unknown_fields_and_malformed_assurance
    variants = [
      @value.merge('tenant_id' => @instance), @value.merge('instance_id' => @tenant),
      @value.merge('purpose' => 'other'), @value.merge('operation' => 'DELETE'),
      @value.merge('actor_id' => '1'), @value.merge('actor' => @value['actor'].merge('revision' => '4')),
      @value.merge('assurance' => @value['assurance'].merge('amr' => ['mfa'] * 33)),
      @value.merge('input' => []), @value.merge('input' => { 'body' => 'x' * 65_536 })
    ]
    variants.each { |value| assert_raises(D::Invalid) { decode(value) } }
  end

  def test_upload_purpose_path_and_file_bounds
    value = @value.merge('purpose' => D::UPLOAD_PURPOSE, 'operation' => 'GROUP_UPLOAD',
      'input' => { 'group_id' => @instance, 'upload_cache_id' => @tenant },
      'file' => { 'filename' => 'fixture.txt', 'mime_type' => 'text/plain', 'byte_size' => 12, 'sha256' => 'a' * 64 })
    decode_upload = lambda do |input, purpose = D::UPLOAD_PURPOSE, path = D::UPLOAD_PATH|
      body = JSON.generate(input)
      signature = OpenSSL::HMAC.hexdigest('SHA256', 'synthetic', "#{purpose}\nPOST\n#{path}\n#{@now}\n#{body}")
      D.decode_upload(Base64.urlsafe_encode64(body, padding: false), @now.to_s, signature,
        secret: 'synthetic', tenant: @tenant, instance: @instance, now: @now)
    end
    assert_equal value, decode_upload.call(value)
    assert_raises(D::Invalid) { decode_upload.call(value, D::PURPOSE, D::PATH) }
    assert_raises(D::Invalid) { decode_upload.call(value.merge('purpose' => D::PURPOSE)) }
    [value.merge('input' => value['input'].merge('native_user_id' => '1')),
     value.merge('file' => value['file'].merge('byte_size' => 50_000_001)),
     value.merge('file' => value['file'].merge('filename' => '../file')),
     value.merge('file' => value['file'].merge('mime_type' => "image/png\r\nInjected: true"))].each do |invalid|
      assert_raises(D::Invalid) { decode_upload.call(invalid) }
    end
  end
  def test_identity_purpose_has_no_cross_path_replay_and_binds_unmapped_owner_email
    value = @value.merge('purpose' => D::IDENTITY_PURPOSE, 'operation' => 'IDENTITY_INITIALIZE',
      'actor' => @value['actor'].merge('native_user_id' => nil, 'email' => 'owner@example.invalid'),
      'input' => { 'request_id' => @tenant, 'expected_status_version' => 'a' * 64 })
    identity = lambda do |input, timestamp = @now, purpose = D::IDENTITY_PURPOSE, path = D::IDENTITY_PATH|
      body = JSON.generate(input)
      signature = OpenSSL::HMAC.hexdigest('SHA256', 'synthetic', "#{purpose}\nPOST\n#{path}\n#{timestamp}\n#{body}")
      D.decode_identity(body, timestamp.to_s, signature, secret: 'synthetic', tenant: @tenant, instance: @instance, now: @now)
    end
    assert_equal value, identity.call(value)
    assert_raises(D::Invalid) { identity.call(value, @now, D::PURPOSE, D::PATH) }
    assert_raises(D::Invalid) { identity.call(value, @now - 31) }
    assert_raises(D::Invalid) { identity.call(value, @now + 6) }
    [value.merge('tenant_id' => @instance), value.merge('instance_id' => @tenant),
      value.merge('actor' => value['actor'].reject { |key, _| key == 'email' }),
      value.merge('actor' => value['actor'].merge('native_user_id' => '0')),
      value.merge('actor' => value['actor'].merge('subject' => " owner")),
      value.merge('source' => value['source'].merge('unexpected' => true))].each do |invalid|
      assert_raises(D::Invalid) { identity.call(invalid) }
    end
  end

end
