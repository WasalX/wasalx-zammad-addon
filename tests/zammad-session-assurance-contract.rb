# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require_relative 'zammad-membership-contract'
require 'securerandom'
require 'uri'
load File.join(ENV.fetch('WASALX_TEST_PACKAGE_ROOT', File.expand_path('../zammad-package', __dir__)), 'lib/wasalx/session_refresh.rb')

module Exceptions
  class UnprocessableContent < StandardError; end
end
class UserDevice
  # Pinned native UserDevice.fingerprint_validation; real Rails owns logging.
  def self.fingerprint_validation(fingerprint)
    raise Exceptions::UnprocessableContent if fingerprint.to_s.length > 160
    true
  end
end

class Setting
  class << self
    attr_accessor :credentials
    def get(_name); credentials; end
  end
end
module Rack
  module Session
    class SessionId
      def initialize(value); @value = value; end
      def private_id; "private-#{@value}"; end
    end
  end
end
class AssuranceSession < Hash
  attr_accessor :id
  def initialize(public_id, user_id)
    super()
    @id = Rack::Session::SessionId.new(public_id)
    self['user_id'] = user_id
  end
  def [](key); super(key.to_s); end
  def []=(key, value); super(key.to_s, value); end
  def delete(key); super(key.to_s); end
  def destroy
    ActiveRecord::SessionStore::Session.records.delete(id.private_id)
    clear
  end
end

class NativeSessionAssuranceContract < Minitest::Test
  Guard = Wasalx::SessionAssurance
  ISSUER = 'https://identity.example.test/realms/wasalx'
  CLIENT = 'native-workspace'
  SUBJECT = 'native-owner-subject'
  REFRESH_ALLOWED = Wasalx::SessionRefresh.method(:allowed?)

  def setup
    # These existing fixtures isolate proof policy; the real refresh contract follows below.
    Wasalx::SessionRefresh.define_singleton_method(:allowed?) { |*_args| true }
    WasalxMembership.records = {}
    Wasalx::Client.calls = []
    User.query_error = nil
    ActiveRecord::Base.pool = nil
    ActiveRecord::Base.opened = ActiveRecord::Base.removed = 0
    ActiveRecord::SessionStore::Session.records = {}
    Sessions.records = {}
    Setting.credentials = { 'issuer' => ISSUER, 'identifier' => CLIENT }
    @user = OpenStruct.new(id: 12, active: true, roles: [OpenStruct.new(name: 'Agent'), OpenStruct.new(name: 'Admin')])
    User.record = @user
    @membership = OpenStruct.new(portal_user_id: '30000000-0000-4000-8000-000000000003', subject: SUBJECT, revision: 4, member_state: 'ACTIVE', portal_role: 'tenant_owner')
    WasalxMembership.records[12] = @membership
    @policy = { 'mfa_required' => true, 'session_timeout_minutes' => 480, 'policy_version' => 2, 'subject' => SUBJECT,
                'mfa_amr_values' => ['mfa'], 'mfa_acr_values' => [] }
    @token = 'signed-provider-id-token'
    @proof = { 'issuer' => ISSUER, 'client_id' => CLIENT, 'subject' => SUBJECT, 'auth_time' => Time.now.to_i,
               'sid' => 'native-idp-sid', 'nonce' => 'initial-oidc-nonce', 'amr' => ['pwd', 'MFA'], 'acr' => 'provider-context', 'token_sha256' => Digest::SHA256.hexdigest(@token) }
    @session = AssuranceSession.new('owner-a', 12)
    install_session(@session, @proof)
    response!
    Authorization.record = OpenStruct.new(user_id: 12)
  end

  def teardown
    Wasalx::SessionRefresh.define_singleton_method(:allowed?, REFRESH_ALLOWED)
  end

  def response!
    Wasalx::Client.response = { 'allowed' => true, 'authentication_policy' => @policy }
  end

  def install_session(session, proof = nil)
    session['oidc_id_token'] = @token
    session[Guard::PROOF] = proof.merge('native_user_id' => session['user_id'].to_s, 'rails_session_id' => session.id.private_id,
      'native_authenticated_at' => Time.now.to_i) if proof
    ActiveRecord::SessionStore::Session.records[session.id.private_id] = OpenStruct.new(data: session, created_at: Time.now)
  end

  def allowed?(session = @session, **options)
    Wasalx::MembershipAccess.allowed?(@user, interactive: true, reference: session.id.private_id, session: session, **options)
  end

  def test_all_six_policy_fields_are_mandatory_and_bounded
    assert Guard.policy(@policy)
    @policy.each_key { |key| refute Guard.policy(@policy.reject { |entry| entry == key }), key }
    invalid = { 'mfa_required' => nil, 'session_timeout_minutes' => 14, 'policy_version' => Guard::MAX_INTEGER + 1,
                'subject' => "subject\n", 'mfa_amr_values' => ['mfa', 'mfa'], 'mfa_acr_values' => ["two words"] }
    invalid.each { |key, value| refute Guard.policy(@policy.merge(key => value)), key }
    refute Guard.policy(@policy.merge('mfa_amr_values' => Array.new(33) { |i| i.to_s }))
    refute Guard.policy(@policy.merge('mfa_amr_values' => ['a' * 129]))
    refute Guard.policy(@policy.merge('mfa_acr_values' => ["a\u200bb"]))
    assert Guard.policy(@policy.merge('mfa_amr_values' => [], 'mfa_acr_values' => []))
  end

  def test_source_mfa_semantics_match_without_aal2_or_empty_fallback
    assert allowed?
    @policy['mfa_amr_values'] = ['MFA']
    refute allowed?, 'Configured method case must not be broadened'
    @policy['mfa_amr_values'] = []
    refute allowed?
    @policy['mfa_acr_values'] = ['provider-context']
    assert allowed?
    @session[Guard::PROOF]['amr'] = nil
    assert allowed?, 'ACR is independently authoritative when Source accepts it'
    @session[Guard::PROOF]['acr'] = ' provider-context '
    assert allowed?
    @policy['mfa_acr_values'] = ['Provider-context']
    refute allowed?
    @session[Guard::PROOF]['acr'] = 'urn:wasalx:loa:2'
    refute allowed?, 'The recovery request URI alone is not accepted proof'
  end

  def test_exact_issuer_client_subject_and_token_hash_bind_the_session
    %w[issuer client_id subject token_sha256 native_user_id rails_session_id].each do |key|
      old = @session[Guard::PROOF][key]
      @session[Guard::PROOF][key] = 'foreign'
      refute allowed?, key
      @session[Guard::PROOF][key] = old
    end
    @session['oidc_id_token'] = 'different-signed-token'
    refute allowed?
    @session['oidc_id_token'] = @token
    Setting.credentials['issuer'] = 'https://foreign.example.test'
    refute allowed?
    Setting.credentials['issuer'] = ISSUER
    @policy['subject'] = 'other-current-subject'
    refute allowed?
  end

  def test_authentication_age_and_fresh_role_policy_apply_without_version_churn
    @session[Guard::PROOF]['auth_time'] = Time.now.to_i - 901
    assert allowed?
    @policy['policy_version'] += 1
    assert allowed?, 'Unrelated settings version changes do not invalidate valid assurance'
    @policy['session_timeout_minutes'] = 15
    refute allowed?
    @session[Guard::PROOF]['auth_time'] = Time.now.to_i + 6
    refute allowed?
    @session[Guard::PROOF]['auth_time'] = nil
    refute allowed?
    @session[Guard::PROOF]['auth_time'] = Time.now.to_i
    @session[Guard::PROOF]['amr'] = ['pwd']
    refute allowed?
    @policy['mfa_required'] = false
    assert allowed?
    @policy['mfa_required'] = true
    refute allowed?
    @membership.member_state = 'SUSPENDED'
    refute allowed?
  end

  def test_same_user_sessions_never_share_proof_and_cookie_rotation_or_deletion_denies
    other = AssuranceSession.new('owner-b', 12)
    install_session(other)
    refute allowed?(other)
    other[Guard::PROOF] = @session[Guard::PROOF].dup
    refute allowed?(other), 'Copying a proof to a second Rails session is insufficient'
    assert allowed?
    @session.id = Rack::Session::SessionId.new('rotated')
    refute allowed?
    @session.id = Rack::Session::SessionId.new('owner-a')
    ActiveRecord::SessionStore::Session.records.delete(@session.id.private_id)
    refute allowed?
  end

  def test_nonrequired_native_roles_keep_normal_authentication_and_conservative_server_age
    @policy['mfa_required'] = false
    @session.delete(Guard::PROOF)
    @session.delete('oidc_id_token')
    assert allowed?
    assert Wasalx::MembershipAccess.allowed?(@user, interactive: true, auth_type: 'native_login')
    assert Wasalx::MembershipAccess.allowed?(@user, interactive: true, auth_type: 'token_auth')
    ActiveRecord::SessionStore::Session.records[@session.id.private_id].created_at = Time.now - 481 * 60
    refute allowed?
    @policy['mfa_required'] = true
    %w[native_login token_auth basic_auth SSO].each do |mode|
      refute Wasalx::MembershipAccess.allowed?(@user, interactive: true, auth_type: mode), mode
    end
  end

  def test_missing_policy_and_source_failure_deny_interactive_but_machine_authority_is_separate
    Wasalx::Client.response = { 'allowed' => true }
    refute allowed?
    refute Wasalx::MembershipAccess.allowed?(@user), 'Missing policy is not accepted for a managed identity'
    response!
    @session.delete(Guard::PROOF)
    assert Wasalx::MembershipAccess.allowed?(@user), 'Governed noninteractive membership checks do not impersonate a human login'
    Wasalx::Client.response = Wasalx::Client::RequestFailed.new
    refute allowed?
    WasalxMembership.records = {}
    assert Wasalx::MembershipAccess.allowed?(@user, interactive: true)
    assert_empty Wasalx::Client.calls.last.drop(3)
  end

  def strategy(proof_claims = nil)
    claims = proof_claims || { 'iss' => ISSUER, 'aud' => [CLIENT], 'sub' => SUBJECT, 'auth_time' => Time.now.to_i, 'amr' => ['mfa'] }
    Class.new do
      attr_accessor :env, :options, :client_options, :session, :claims, :verified, :fail_verification
      def initialize(claims)
        @env = {}; @session = {}; @verified = false; @claims = claims
        @options = OpenStruct.new(issuer: NativeSessionAssuranceContract::ISSUER)
        @client_options = OpenStruct.new(identifier: NativeSessionAssuranceContract::CLIENT)
      end
      def request_phase; :provider_request_phase; end
      private
      def verify_id_token!(token)
        raise 'provider signature/issuer/nonce validation failed' if fail_verification
        @verified = true if token
      end
      def decode_id_token(_token)
        raise 'capture ran before successful provider verification' unless verified
        OpenStruct.new(raw_attributes: claims)
      end
      prepend Wasalx::SessionAssurance::OidcVerification
    end.new(claims)
  end

  def test_provider_verification_runs_first_and_signature_failure_nil_or_wrong_audience_cannot_capture
    instance = strategy
    instance.send(:verify_id_token!, @token)
    assert_equal Digest::SHA256.hexdigest(@token), instance.env[Guard::CALLBACK]['token_sha256']
    instance.fail_verification = true
    assert_raises(RuntimeError) { instance.send(:verify_id_token!, @token) }
    refute instance.env.key?(Guard::CALLBACK)
    instance.fail_verification = false
    instance.send(:verify_id_token!, nil)
    refute instance.env.key?(Guard::CALLBACK)
    instance.claims['aud'] = ['wrong-client']
    instance.send(:verify_id_token!, @token)
    refute instance.env.key?(Guard::CALLBACK)
    instance.claims['aud'] = [CLIENT]
    instance.claims['iss'] = 'https://foreign.example.test'
    instance.send(:verify_id_token!, @token)
    refute instance.env.key?(Guard::CALLBACK)
  end

  def callback
    controller = Class.new do
      attr_accessor :request, :session, :native_calls, :rendered, :events, :redirected_to
      def initialize; @native_calls = 0; @events = []; end
      def reset_session
        @events << [:reset_session, session.id.private_id]
        session.destroy
        self.session = AssuranceSession.new("renewed-#{SecureRandom.hex(16)}", nil)
      end
      def create_omniauth
        @native_calls += 1
        # Pinned create_omniauth/current_user_set does not rotate the ID.
        @events << [:native_callback, session.id.private_id, session.keys]
        session[:user_id] = 12
        session[:oidc_id_token] = request.env['omniauth.auth']['credentials']['id_token']
        session[:oidc_sid] = request.env['omniauth.auth']['extra']['raw_info']['sid']
        # Pinned SessionsController only initializes device state when the
        # current OAuth request carries the browser's original fingerprint.
        fingerprint = request.env.dig('omniauth.params', 'fingerprint')
        if fingerprint.is_a?(String) && !fingerprint.strip.empty?
          UserDevice.fingerprint_validation(fingerprint)
          session[:user_device_fingerprint] = fingerprint
          session[:user_device_updated_at] = Time.now
        end
        redirect_after_omniauth('/#')
        :native_callback
      end
      # Same pinned redirect_after_omniauth branch/consumption order; redirect_to
      # is observed locally rather than issuing an HTTP response in this fixture.
      def redirect_after_omniauth(default_url)
        return_to = session[:doorkeeper_return_to]
        if return_to.is_a?(String) && return_to.match?(%r{\A/oauth/authorize(?:\z|[/?#])})
          self.redirected_to = session.delete(:doorkeeper_return_to)
        else
          self.redirected_to = default_url
        end
      end
      def render(**options); self.rendered = options; :verification_screen; end
      prepend Wasalx::SessionAssurance::OidcCallback
    end.new
    controller.session = @session
    controller.request = OpenStruct.new(env: { 'omniauth.auth' => { 'provider' => 'openid_connect', 'uid' => SUBJECT,
      'credentials' => { 'id_token' => @token, 'refresh_token' => 'native-own-refresh' }, 'extra' => { 'raw_info' => { 'amr' => ['mfa'], 'sid' => 'native-idp-sid' } } }, Guard::CALLBACK => @proof.dup })
    Wasalx::Client.response = { 'enabled' => true, 'native_user_id' => '12', 'authentication_policy' => @policy }
    controller
  end

  def test_callback_admits_only_exact_verified_token_and_binds_final_rotated_session
    @session.delete(Guard::PROOF)
    @session['untrusted_old_state'] = 'must-not-survive'
    old = @session.dup
    old_reference = old.id.private_id
    old_channel = channel(old_reference)
    old_legacy = { 'id' => 12, Guard::REFERENCE => old_reference }
    Sessions.records['old-socket'] = { user: old_legacy }
    refute allowed?(old)
    controller = callback
    assert_equal :native_callback, controller.create_omniauth
    assert_equal 1, controller.native_calls
    @session = controller.session
    assert_equal [[:reset_session, old_reference], [:native_callback, @session.id.private_id, ['user_id']]], controller.events
    refute_equal old_reference, @session.id.private_id
    assert_equal @session.id.private_id, @session[Guard::PROOF]['rails_session_id']
    assert_equal '12', @session[Guard::PROOF]['native_user_id']
    refute @session.key?('untrusted_old_state')
    refute ActiveRecord::SessionStore::Session.records.key?(old_reference)
    refute controller.request.env.key?(Guard::CALLBACK)
    install_session(@session) # The response commits only the final session.
    response!
    assert allowed?
    refute allowed?(old)
    old_channel.execute({}); old_channel.transmit({})
    assert old_channel.connection.closed
    refute old_channel.executed
    refute old_channel.transmitted
    refute Wasalx::MembershipAccess.legacy_allowed?('old-socket', old_legacy)
    current_channel = channel(@session.id.private_id)
    current_channel.execute({}); current_channel.transmit({})
    assert current_channel.executed
    assert current_channel.transmitted
    current_legacy = { 'id' => 12, Guard::REFERENCE => @session.id.private_id }
    Sessions.records['new-socket'] = { user: current_legacy }
    assert Wasalx::MembershipAccess.legacy_allowed?('new-socket', current_legacy)
  end

  def test_callback_userinfo_or_substituted_token_cannot_grant_native_login
    [nil, @proof.merge('token_sha256' => Digest::SHA256.hexdigest('foreign')), @proof.merge('amr' => ['pwd'])].each do |proof|
      controller = callback
      controller.request.env[Guard::CALLBACK] = proof
      assert_equal :verification_screen, controller.create_omniauth
      assert_equal 0, controller.native_calls
      assert_nil @session[:user_id]
      assert_nil @session[Guard::PROOF]
      assert_equal :forbidden, controller.rendered[:status]
      assert_includes controller.rendered[:inline], 'form_tag(recovery_path, method: :post)'
      refute controller.request.env.key?(Guard::CALLBACK)
    end
  end

  def test_callback_denies_missing_foreign_or_malformed_source_policy
    [nil, @policy.merge('subject' => 'foreign'), @policy.reject { |key| key == 'mfa_acr_values' }].each do |policy|
      controller = callback
      Wasalx::Client.response['authentication_policy'] = policy
      assert_raises(Exceptions::NotAuthorized) { controller.create_omniauth }
      assert_equal 0, controller.native_calls
    end
    controller = callback
    Wasalx::Client.response['native_user_id'] = '13'
    assert_raises(Exceptions::NotAuthorized) { controller.create_omniauth }
  end

  def test_recovery_carries_only_original_browser_fingerprint_then_native_recreates_device_state
    controller = callback
    controller.session[:user_device_fingerprint] = 'old-device'
    controller.session[:user_device_updated_at] = Time.at(1)
    controller.session[:untrusted_device_state] = 'must-not-survive'
    controller.request.env['omniauth.params'] = { 'fingerprint' => 'browser-device-123', 'untrusted' => 'ignored' }
    controller.request.env[Guard::CALLBACK]['amr'] = ['pwd']
    assert_equal :verification_screen, controller.create_omniauth
    assert_equal 0, controller.native_calls
    assert_nil controller.session[:user_id]
    assert_equal '/auth/openid_connect?fingerprint=browser-device-123', controller.rendered[:locals][:recovery_path]
    assert_includes controller.rendered[:inline], 'form_tag(recovery_path, method: :post)'
    refute_includes controller.rendered[:inline], 'hidden_field_tag(:fingerprint'

    # Pinned OmniAuth2.1.4 Strategy.request_call saves request.GET only, and
    # callback_call restores it. POST body fields do not survive this handoff.
    # Exercise that boundary rather than injecting the expected callback value.
    action = URI.parse(controller.rendered[:locals][:recovery_path])
    assert_nil action.host
    assert_equal '/auth/openid_connect', action.path
    controller.request.env['omniauth.params'] = URI.decode_www_form(action.query || '').to_h
    controller.request.env[Guard::CALLBACK] = @proof.dup
    old_reference = controller.session.id.private_id
    assert_equal :native_callback, controller.create_omniauth
    refute_equal old_reference, controller.session.id.private_id
    assert_equal 'browser-device-123', controller.session[:user_device_fingerprint]
    assert_operator controller.session[:user_device_updated_at], :>, Time.at(1)
    refute controller.session.key?('untrusted_device_state')
    refute ActiveRecord::SessionStore::Session.records.key?(old_reference)
    @session = controller.session
    install_session(@session)
    response!
    assert allowed?
  end

  def test_recovery_rejects_nested_or_native_oversized_fingerprint_before_login
    [{ 'value' => 'nested' }, ['nested'], 'x' * 161].each do |fingerprint|
      controller = callback
      controller.request.env['omniauth.params'] = { 'fingerprint' => fingerprint }
      controller.request.env[Guard::CALLBACK] = @proof.merge('amr' => ['pwd'])
      assert_raises(Exceptions::UnprocessableContent) { controller.create_omniauth }
      assert_equal 0, controller.native_calls
      assert_nil controller.session[:user_id]
      assert_nil controller.session[Guard::PROOF]
    end
  end

  def test_recovery_does_not_invent_missing_fingerprint_or_interpolate_browser_html
    controller = callback
    controller.request.env[Guard::CALLBACK]['amr'] = ['pwd']
    assert_equal :verification_screen, controller.create_omniauth
    assert_equal({ recovery_path: '/auth/openid_connect' }, controller.rendered[:locals])
    fingerprint = '<input name="user_id" value="1">&user_id=1+/?#'
    controller.request.env['omniauth.params'] = { 'fingerprint' => fingerprint }
    controller.request.env[Guard::CALLBACK] = @proof.merge('amr' => ['pwd'])
    assert_equal :verification_screen, controller.create_omniauth
    action = URI.parse(controller.rendered[:locals][:recovery_path])
    assert_equal({ 'fingerprint' => fingerprint }, URI.decode_www_form(action.query).to_h)
    assert_nil action.host
    assert_equal '/auth/openid_connect', action.path
    refute_match(/[<>"#]/, action.to_s)
    refute_includes controller.rendered[:inline], fingerprint
    assert_includes controller.rendered[:inline], 'form_tag(recovery_path, method: :post)'
    assert_equal 0, controller.native_calls
  end

  def test_nonrequired_oidc_does_not_require_mfa_or_forge_auth_time
    @policy['mfa_required'] = false
    @proof['auth_time'] = nil
    @proof['amr'] = nil
    controller = callback
    assert_equal :native_callback, controller.create_omniauth
    @session = controller.session
    install_session(@session)
    assert_nil @session[Guard::PROOF]['auth_time']
    response!
    assert allowed?
  end

  def test_missing_native_grant_or_sid_cannot_run_native_callback_or_stage_enrollment
    [:refresh, :sid].each do |missing|
      controller = callback
      if missing == :refresh
        controller.request.env['omniauth.auth']['credentials'].delete('refresh_token')
      else
        controller.request.env[Guard::CALLBACK].delete('sid')
      end
      assert_raises(Exceptions::NotAuthorized) { controller.create_omniauth }
      assert_equal 0, controller.native_calls
      refute controller.request.env.key?(Wasalx::SessionRefresh::PENDING)
    end
  end

  def test_nonrequired_legacy_oidc_cannot_fall_back_to_password_while_real_native_login_stays_supported
    @policy['mfa_required'] = false
    @session.delete(Guard::PROOF)
    refute allowed?, 'An old managed OIDC session must enroll through normal SSO'
    @session[Guard::NATIVE_LOGIN] = { 'native_user_id' => '12', 'rails_session_id' => @session.id.private_id,
      'native_authenticated_at' => Time.now.to_i }
    assert allowed?, 'A separately authenticated native password session keeps its own original policy'
  end

  def test_recovery_is_server_session_only_bounded_and_not_an_authority_claim
    instance = strategy
    assert_equal :provider_request_phase, instance.request_phase
    assert_nil instance.options.acr_values
    instance.session[Guard::RECOVERY] = { 'armed' => true, 'until' => Time.now.to_i + 60 }
    instance.request_phase
    assert_equal 'urn:wasalx:loa:2', instance.options.acr_values
    assert_equal 'login', instance.options.prompt
    refute instance.session[Guard::RECOVERY]['armed']
    controller = callback
    controller.request.env[Guard::CALLBACK]['amr'] = ['pwd']
    3.times { controller.request.env[Guard::CALLBACK] = @proof.merge('amr' => ['pwd']); controller.create_omniauth }
    refute controller.session[Guard::RECOVERY]['armed']
    assert_equal 0, controller.native_calls
    refute_match(/window\.|location=|redirect_to|params\[/, controller.rendered[:inline])
  end

  def channel(reference)
    instance = Class.new do
      attr_accessor :connection, :current_user, :executed, :transmitted
      def execute(_data); @executed = true; end
      def transmit(_data, **_options); @transmitted = true; end
      prepend Wasalx::MembershipAccess::CableChannel
    end.new
    instance.current_user = @user
    instance.connection = OpenStruct.new(wasalx_membership_revision: 4, wasalx_session_reference: reference)
    instance.connection.define_singleton_method(:close) { |reconnect:| self.closed = !reconnect }
    instance
  end

  def test_modern_receive_and_send_recheck_exact_rails_session_after_signout_or_rebind
    instance = channel(@session.id.private_id)
    instance.execute({}); instance.transmit({})
    assert instance.executed
    assert instance.transmitted
    ActiveRecord::SessionStore::Session.records[@session.id.private_id].data['user_id'] = 13
    instance.executed = instance.transmitted = false
    instance.execute({}); instance.transmit({})
    assert instance.connection.closed
    refute instance.executed
    refute instance.transmitted
    @session['user_id'] = 12
    ActiveRecord::SessionStore::Session.records.delete(@session.id.private_id)
    refute Wasalx::MembershipAccess.allowed?(@user, interactive: true, reference: @session.id.private_id)
  end

  def test_legacy_receive_send_and_cached_identity_require_original_session_reference
    data = { 'id' => 12, Guard::REFERENCE => @session.id.private_id }
    Sessions.records['socket'] = { user: data }
    assert Wasalx::MembershipAccess.legacy_allowed?('socket', data)
    refute Wasalx::MembershipAccess.legacy_allowed?('socket', data.merge(Guard::REFERENCE => 'foreign'))
    other = AssuranceSession.new('owner-b', 12)
    install_session(other)
    Sessions.records['socket'] = { user: data.merge(Guard::REFERENCE => other.id.private_id) }
    refute Wasalx::MembershipAccess.legacy_allowed?('socket')
    Sessions.records['socket'] = { user: data }
    ActiveRecord::SessionStore::Session.records.delete(@session.id.private_id)
    refute Wasalx::MembershipAccess.legacy_allowed?('socket', data)
    assert_nil ActiveRecord::Base.pool
  end

  def test_legacy_login_binds_only_server_created_same_user_data_and_clears_thread_on_failure
    native = Class.new do
      attr_accessor :payload, :created, :fail_login
      def initialize(public_id); @payload = { 'session_id' => public_id }; end
      def run
        raise 'native login failed' if fail_login
        data = { 'id' => 12 }
        self.created = Class.new do
          def self.create(_id, data, _meta); data; end
          singleton_class.prepend(Wasalx::SessionAssurance::LegacySession)
        end.create('socket', data, { type: 'websocket' })
      end
      prepend Wasalx::SessionAssurance::LegacyLogin
    end.new('owner-a')
    native.run
    assert_equal @session.id.private_id, native.created[Guard::REFERENCE]
    assert_nil Thread.current[:wasalx_native_login]
    native.fail_login = true
    assert_raises(RuntimeError) { native.run }
    assert_nil Thread.current[:wasalx_native_login]
    native.fail_login = false
    native.instance_variable_set(:@payload, { 'session_id' => 'foreign' })
    native.run
    refute native.created.key?(Guard::REFERENCE)
  end

  def test_modern_connection_binds_original_cookie_and_rejects_deleted_or_foreign_session
    connection = Class.new do
      attr_accessor :user, :public_id
      def initialize(user); @user = user; @public_id = 'owner-a'; end
      private
      def find_verified_user; user; end
      def session_id; public_id; end
      def reject_unauthorized_connection; raise Exceptions::NotAuthorized; end
      prepend Wasalx::MembershipAccess::CableConnection
    end.new(@user)
    assert_equal @user, connection.send(:find_verified_user)
    assert_equal @session.id.private_id, connection.wasalx_session_reference
    assert_equal 4, connection.wasalx_membership_revision
    connection.public_id = 'owner-b'
    assert_raises(Exceptions::NotAuthorized) { connection.send(:find_verified_user) }
    connection.user = nil
    assert_raises(Exceptions::NotAuthorized) { connection.send(:find_verified_user) }
  end

  def public_cable_connection(user: nil, cookie: nil)
    Class.new do
      attr_accessor :native_user, :public_id, :current_user, :closed
      def initialize(user, cookie); @native_user = user; @public_id = cookie; end
      def connect
        return if session_id.nil?
        self.current_user = find_verified_user
      end
      def close(reconnect:); @closed = !reconnect; end

      private

      def find_verified_user; native_user; end
      def session_id; public_id; end
      def reject_unauthorized_connection; raise Exceptions::NotAuthorized; end
      prepend Wasalx::MembershipAccess::CableConnection
    end.new(user, cookie)
  end

  def test_public_cable_new_socket_keeps_native_guest_query_and_subscription_dispatch
    [nil, 'expired-native-cookie'].each do |cookie|
      connection = public_cable_connection(cookie: cookie)
      connection.connect
      assert_nil connection.current_user
      assert connection.wasalx_public_connection?
      instance = channel(nil)
      instance.current_user = nil
      instance.connection = connection
      instance.execute({ 'operationName' => 'configUpdates' })
      instance.transmit({ 'result' => { 'data' => {} } })
      assert instance.executed
      assert instance.transmitted
      refute connection.closed
      refute Wasalx::MembershipAccess.allowed?(nil, interactive: true), 'Public schema dispatch must not grant interactive membership'
    end
  end

  def test_public_cable_never_upgrades_a_guest_without_native_reconnect
    connection = public_cable_connection(cookie: 'expired-native-cookie')
    connection.connect
    connection.native_user = @user
    assert_nil connection.current_user, 'Native login must create a new connection'
    assert connection.wasalx_public_connection?

    # Even an unexpected mutation cannot use the public exception for a user.
    connection.current_user = @user
    instance = channel(nil)
    instance.connection = connection
    instance.execute({}); instance.transmit({})
    refute connection.wasalx_public_connection?
    assert connection.closed
    refute instance.executed
    refute instance.transmitted
  end

  def test_public_cable_never_downgrades_an_authenticated_socket_to_a_guest
    connection = public_cable_connection(user: @user, cookie: 'owner-a')
    connection.connect
    assert_same @user, connection.current_user
    refute connection.wasalx_public_connection?
    connection.native_user = connection.current_user = nil
    assert_raises(Exceptions::NotAuthorized) { connection.send(:find_verified_user) }
    refute connection.wasalx_public_connection?
    instance = channel(nil)
    instance.current_user = nil
    instance.connection = connection
    instance.execute({}); instance.transmit({})
    assert connection.closed
    refute instance.executed
    refute instance.transmitted
  end

  def test_public_cable_weak_or_revoked_users_never_receive_guest_dispatch
    [:weak_mfa, :revoked].each do |reason|
      setup
      reason == :weak_mfa ? @session.delete(Guard::PROOF) : Wasalx::Client.response['allowed'] = false
      connection = public_cable_connection(user: @user, cookie: 'owner-a')
      assert_raises(Exceptions::NotAuthorized) { connection.connect }
      assert_nil connection.current_user
      refute connection.wasalx_public_connection?
      instance = channel(nil)
      instance.current_user = nil
      instance.connection = connection
      instance.execute({}); instance.transmit({})
      assert connection.closed
      refute instance.executed
      refute instance.transmitted
    end
  end

  def test_legacy_event_and_delivery_wrappers_stop_after_native_logout
    data = { 'id' => 12, Guard::REFERENCE => @session.id.private_id }
    Sessions.records['socket'] = { user: data }
    event = Class.new do
      def run(_params); :executed; end
      prepend Wasalx::MembershipAccess::LegacyEvents
    end.new
    transport = Class.new do
      def self.send(_id, _data); :sent; end
      def self.queue(_id); [:queued]; end
      singleton_class.prepend(Wasalx::MembershipAccess::LegacyTransport)
    end
    assert_equal :executed, event.run(client_id: 'socket', session: data)
    assert_equal :sent, transport.send('socket', {})
    assert_equal [:queued], transport.queue('socket')
    ActiveRecord::SessionStore::Session.records.delete(@session.id.private_id)
    assert_equal({ event: 'error', data: { state: 'no_session' } }, event.run(client_id: 'socket', session: data))
    refute transport.send('socket', {})
    assert_empty transport.queue('socket')
  end

  def test_native_nonrequired_successful_login_renews_only_its_own_server_authentication_time
    @policy['mfa_required'] = false
    @session.delete(Guard::PROOF)
    ActiveRecord::SessionStore::Session.records[@session.id.private_id].created_at = Time.now - 481 * 60
    refute allowed?
    controller = Class.new do
      attr_accessor :session
      def initiate_session_for(_user, _type); :native_login; end
      prepend Wasalx::SessionAssurance::OidcCallback
    end.new
    controller.session = @session
    assert_equal :native_login, controller.send(:initiate_session_for, @user, 'password')
    assert allowed?
    stamp = @session[Guard::NATIVE_LOGIN]
    assert_equal '12', stamp['native_user_id']
    assert_equal @session.id.private_id, stamp['rails_session_id']
    @policy['mfa_required'] = true
    refute allowed?, 'Native successful password time is never OIDC MFA proof'
    @policy['mfa_required'] = false
    stamp['rails_session_id'] = 'another-session'
    refute allowed?
  end

  def test_malformed_stored_proofs_fail_closed
    [[], 'malformed', true, { 'native_user_id' => '12' }].each do |proof|
      @session[Guard::PROOF] = proof
      refute allowed?
    end
  end

  def test_old_weak_session_can_still_use_native_own_signout_without_a_controller_exemption
    @session.delete(Guard::PROOF)
    refute allowed?
    before = Wasalx::Client.calls.length
    other = AssuranceSession.new('owner-b', 12)
    install_session(other, @proof)
    controller = Class.new(SessionsController) do
      attr_accessor :session
      # The pinned destroy action calls native OidcDatabase.destroy_session;
      # it never calls authentication_check_prerequesits (unlike admin actions).
      def destroy; session.destroy; :native_own_signout; end
      prepend Wasalx::MembershipAccess::Authentication
      prepend Wasalx::SessionAssurance::OidcCallback
    end.new
    controller.session = @session
    assert_equal :native_own_signout, controller.destroy
    assert_equal before, Wasalx::Client.calls.length
    refute ActiveRecord::SessionStore::Session.records.key?(@session.id.private_id)
    assert ActiveRecord::SessionStore::Session.records.key?(other.id.private_id)
    assert allowed?(other)
    refute Guard::OidcCallback.public_instance_methods(false).include?(:destroy)
  end

  def test_sync_disabled_default_off_and_other_provider_keep_native_flow_without_inherited_proof
    controller = callback
    Wasalx::Client.response = { 'enabled' => false }
    assert_equal :native_callback, controller.create_omniauth
    assert_nil @session[Guard::PROOF]
    controller = callback
    controller.request.env['omniauth.auth']['provider'] = 'legacy-provider'
    before = Wasalx::Client.calls.length
    assert_equal :native_callback, controller.create_omniauth
    assert_equal before, Wasalx::Client.calls.length
    assert_nil @session[Guard::PROOF]
  end

  def test_http_required_human_tokens_deny_but_exact_machine_token_path_is_unchanged
    controller = Class.new do
      attr_accessor :session
      def authentication_check_prerequesits(_user, _type); :native_authenticated; end
      prepend Wasalx::MembershipAccess::Authentication
    end.new
    controller.session = @session
    assert_equal :native_authenticated, controller.send(:authentication_check_prerequesits, @user, 'session')
    %w[token_auth basic_auth].each do |type|
      assert_raises(Exceptions::NotAuthorized) { controller.send(:authentication_check_prerequesits, @user, type) }
    end
    token = Object.new
    controller.instance_variable_set(:@_token, token)
    original_machine = Wasalx::ServiceIdentity.method(:automation?)
    original_token = Wasalx::ServiceIdentity.method(:token_allowed?)
    Wasalx::ServiceIdentity.define_singleton_method(:automation?) { |_user| true }
    Wasalx::ServiceIdentity.define_singleton_method(:token_allowed?) { |_user, candidate, purpose| candidate.equal?(token) && purpose == 'runtime' }
    assert_equal :native_authenticated, controller.send(:authentication_check_prerequesits, @user, 'token_auth')
    assert_raises(Exceptions::NotAuthorized) { controller.send(:authentication_check_prerequesits, @user, 'session') }
    controller.instance_variable_set(:@_token, Object.new)
    assert_raises(Exceptions::NotAuthorized) { controller.send(:authentication_check_prerequesits, @user, 'token_auth') }
  ensure
    Wasalx::ServiceIdentity.define_singleton_method(:automation?, original_machine) if original_machine
    Wasalx::ServiceIdentity.define_singleton_method(:token_allowed?, original_token) if original_token
  end

  def test_first_native_password_login_is_preserved_only_for_a_nonrequired_role
    controller = Class.new(SessionsController) do
      attr_accessor :session
      def action_name; 'create'; end
      def authentication_check_prerequesits(_user, _type); :native_authenticated; end
      prepend Wasalx::MembershipAccess::Authentication
    end.new
    controller.session = AssuranceSession.new('not-yet-persisted', nil)
    assert_raises(Exceptions::NotAuthorized) { controller.send(:authentication_check_prerequesits, @user, 'session') }
    @policy['mfa_required'] = false
    assert_equal :native_authenticated, controller.send(:authentication_check_prerequesits, @user, 'session')
  end

  def test_opaque_subject_contract_matches_source_length_trim_and_control_rules
    ['s' * 256, 's' * 320, 'opaque subject with internal spaces', "\u{1f600}" * 160].each do |subject|
      assert Guard.subject?(subject)
      assert Guard.policy(@policy.merge('subject' => subject))
      instance = strategy('iss' => ISSUER, 'aud' => CLIENT, 'sub' => subject, 'auth_time' => Time.now.to_i, 'amr' => ['mfa'])
      instance.send(:verify_id_token!, @token)
      assert_equal subject, instance.env[Guard::CALLBACK]['subject']
    end
    ['', 's' * 321, ' leading', 'trailing ', "\u00a0boundary", "boundary\u3000", "internal\ncontrol", "internal\u200bformat", "\u{1f600}" * 161].each do |subject|
      refute Guard.subject?(subject), subject.inspect
      refute Guard.policy(@policy.merge('subject' => subject)), subject.inspect
    end
  end

  def test_long_opaque_subject_is_admitted_only_with_exact_same_policy_token_and_membership
    subject = "#{'s' * 256} internal space"
    @policy['subject'] = @membership.subject = @proof['subject'] = subject
    controller = callback
    controller.request.env['omniauth.auth']['uid'] = subject
    assert_equal :native_callback, controller.create_omniauth
    @session = controller.session
    install_session(@session)
    response!
    assert allowed?
    @policy['subject'] = subject.sub('internal space', 'different space')
    refute allowed?
    @policy['subject'] = subject
    @session[Guard::PROOF]['subject'] = subject.sub('internal space', 'different space')
    refute allowed?
  end

  def test_rotation_retains_only_core_approved_oauth_continuation_until_native_redirect_consumes_it
    ['/oauth/authorize', '/oauth/authorize?client_id=native-test', '/oauth/authorize/consent', '/oauth/authorize#finish'].each do |path|
      @session[:doorkeeper_return_to] = path
      @session['unrelated_old_state'] = 'not-copied'
      old_reference = @session.id.private_id
      controller = callback
      assert_equal :native_callback, controller.create_omniauth
      @session = controller.session
      assert_equal path, controller.redirected_to
      assert_equal ['user_id', 'doorkeeper_return_to'], controller.events[1][2]
      assert_nil @session[:doorkeeper_return_to], 'The core redirect consumes the continuation'
      refute @session.key?('unrelated_old_state')
      refute_equal old_reference, @session.id.private_id
      refute ActiveRecord::SessionStore::Session.records.key?(old_reference)
      assert_equal @session.id.private_id, @session[Guard::PROOF]['rails_session_id']
      install_session(@session)
    end
  end

  def test_rotation_drops_external_other_paths_and_authorize_prefix_collisions
    ['https://external.example.test/oauth/authorize', '//external.example.test/oauth/authorize', '/api/v1/users',
     '/oauth/authorizeevil', '/oauth/authorize%3fclient_id=test', ['/oauth/authorize'], 7, nil].each do |path|
      @session[:doorkeeper_return_to] = path
      old_reference = @session.id.private_id
      controller = callback
      assert_equal :native_callback, controller.create_omniauth
      @session = controller.session
      assert_equal '/#', controller.redirected_to
      assert_equal ['user_id'], controller.events[1][2]
      assert_nil @session[:doorkeeper_return_to]
      refute ActiveRecord::SessionStore::Session.records.key?(old_reference)
      install_session(@session)
    end
  end
end

# Append to the existing assurance contract; do not create a new suite root.
class GraphqlController; end unless defined?(GraphqlController)

class NativeSessionAssuranceContract
  def graphql_bootstrap_controller
    Class.new(GraphqlController) do
      attr_accessor :session, :optional_type, :native_error
      attr_reader :resets, :native_calls, :guest_context
      def initialize(session)
        @session = session
        @resets = @native_calls = 0
        @optional_type = 'session'
      end

      private

      # Native optional auth returns false for a guest; direct prerequisites
      # return a User or raise. Keep these two caller contracts distinct.
      def authentication_check_only
        raise native_error if native_error
        return false unless session[:user_id]
        user = User.find_by(id: session[:user_id])
        return false unless user
        authentication_check_prerequesits(user, optional_type)
      end

      def authentication_check_prerequesits(user, _type)
        @native_calls += 1
        @_current_user = user
        user
      end

      def reset_session
        @resets += 1
        session.destroy
        @session = AssuranceSession.new('new-guest', nil)
      end

      # The installed HasUser#set_user recomputes native thread identity from
      # these exact caches and the newly anonymous session.
      def set_user
        @guest_context = [session[:user_id], @_current_user, @_user_on_behalf, @_token, @_token_auth, @_auth_type]
      end
      prepend Wasalx::MembershipAccess::Authentication
    end.new(@session)
  end

  def test_graphql_bootstrap_rejected_own_session_becomes_guest_without_proof
    @session.delete(Guard::PROOF)
    other = AssuranceSession.new('other-owner-session', 12)
    install_session(other, @proof)
    controller = graphql_bootstrap_controller
    %i[@_current_user @_user_on_behalf @_token @_token_auth @_auth_type].each { |key| controller.instance_variable_set(key, @user) }
    refute controller.send(:authentication_check_only)
    assert_equal 1, controller.resets
    assert_equal 0, controller.native_calls
    assert_equal [nil] * 6, controller.guest_context
    refute ActiveRecord::SessionStore::Session.records.key?(@session.id.private_id)
    assert ActiveRecord::SessionStore::Session.records.key?(other.id.private_id)
    assert_nil controller.session[Guard::PROOF]
    assert_nil controller.session[:user_id]
    assert_equal true, @policy['mfa_required']
  end

  def test_graphql_bootstrap_valid_and_legacy_sessions_keep_native_authentication
    controller = graphql_bootstrap_controller
    assert_same @user, controller.send(:authentication_check_only)
    assert_equal 0, controller.resets
    assert_equal 1, controller.native_calls
    WasalxMembership.records = {}
    legacy = graphql_bootstrap_controller
    assert_same @user, legacy.send(:authentication_check_only)
    assert_equal 0, legacy.resets
    assert_equal 1, legacy.native_calls
  end

  def test_graphql_bootstrap_direct_login_prerequisites_never_return_false_success
    @session.delete(Guard::PROOF)
    controller = graphql_bootstrap_controller
    error = assert_raises(Exceptions::NotAuthorized) { controller.send(:authentication_check_prerequesits, @user, 'session') }
    assert_equal Exceptions::NotAuthorized, error.class
    assert_equal 'Exceptions::NotAuthorized', error.class.name
    assert_equal 0, controller.resets
    assert_equal 0, controller.native_calls
  end

  def test_graphql_bootstrap_basic_and_token_denials_are_not_recovered
    %w[basic_auth token_auth].each do |mode|
      controller = graphql_bootstrap_controller
      controller.optional_type = mode
      error = assert_raises(Exceptions::NotAuthorized) { controller.send(:authentication_check_only) }
      assert_equal Exceptions::NotAuthorized, error.class
      assert_equal 0, controller.resets
      assert_equal 0, controller.native_calls
    end
  end

  def test_graphql_bootstrap_unmarked_native_error_is_not_swallowed
    controller = graphql_bootstrap_controller
    original = Exceptions::NotAuthorized.new('Native authentication error')
    controller.native_error = original
    actual = assert_raises(Exceptions::NotAuthorized) { controller.send(:authentication_check_only) }
    assert_same original, actual
    assert_equal 0, controller.resets
  end

  def test_graphql_bootstrap_other_controller_denial_stays_unauthorized
    @session.delete(Guard::PROOF)
    controller = Class.new do
      attr_accessor :session
      def authentication_check_only
        authentication_check_prerequesits(User.find_by(id: session[:user_id]), 'session')
      end
      def authentication_check_prerequesits(*); raise 'Native must not execute'; end
      def reset_session; raise 'Other controller must not reset'; end
      prepend Wasalx::MembershipAccess::Authentication
    end.new
    controller.session = @session
    assert_raises(Exceptions::NotAuthorized) { controller.send(:authentication_check_only) }
  end

  def test_graphql_bootstrap_machine_denial_stays_unauthorized
    original = Wasalx::ServiceIdentity.method(:automation?)
    Wasalx::ServiceIdentity.define_singleton_method(:automation?) { |_user| true }
    controller = graphql_bootstrap_controller
    error = assert_raises(Exceptions::NotAuthorized) { controller.send(:authentication_check_only) }
    assert_equal Exceptions::NotAuthorized, error.class
    assert_equal 0, controller.resets
    assert_equal 0, controller.native_calls
  ensure
    Wasalx::ServiceIdentity.define_singleton_method(:automation?, original) if original
  end
end

# Pure local fixture: no Rails server, real provider, network or credentials.
require 'minitest/autorun'
require 'openssl'
require 'base64'
require 'ostruct'
require 'thread'

# Exact openid_connect 2.3.1 lexical hierarchy. This is the gem's own
# OpenIDConnect::Exception, not Ruby's top-level ::Exception.
module OpenIDConnect
  class Exception < StandardError; end
  class ResponseObject
    class IdToken
      class InvalidToken < Exception; end
      class ExpiredToken < InvalidToken; end
      class InvalidIssuer < InvalidToken; end
      class InvalidNonce < InvalidToken; end
      class InvalidAudience < InvalidToken; end
    end
  end
end

module RefreshFixtures
  Refresh = Wasalx::SessionRefresh
  Guard = Wasalx::SessionAssurance
  ISSUER = 'https://identity.example.test/realms/fixture'
  CLIENT = 'native-fixture'
  KEY = OpenSSL::PKey::RSA.generate(2048)

  # API-compatible local AEAD fixture; the product uses Rails MessageEncryptor.
  class Cipher
    def initialize; @key = OpenSSL::Random.random_bytes(32); end
    def encrypt_and_sign(value, purpose:)
      cipher = OpenSSL::Cipher.new('aes-256-gcm').encrypt
      cipher.key = @key
      iv = cipher.random_iv
      cipher.auth_data = purpose
      encrypted = cipher.update(JSON.generate(value)) + cipher.final
      Base64.strict_encode64(iv + cipher.auth_tag + encrypted)
    end
    def decrypt_and_verify(value, purpose:)
      bytes = Base64.strict_decode64(value)
      cipher = OpenSSL::Cipher.new('aes-256-gcm').decrypt
      cipher.key = @key; cipher.iv = bytes[0, 12]; cipher.auth_tag = bytes[12, 16]
      cipher.auth_data = purpose
      JSON.parse(cipher.update(bytes[28..]) + cipher.final)
    end
  end

  class Repository
    attr_reader :records, :posts
    attr_accessor :fail_write, :outer_transaction
    def initialize
      @records = {}; @posts = []; @locks = Hash.new { |hash, key| hash[key] = Mutex.new }
    end
    def seed(reference, proof, checked_at: Time.now.to_i - Refresh::INTERVAL - 1)
      data = { 'user_id' => proof['native_user_id'], 'oidc_sid' => proof['sid'],
        'oidc_id_token' => 'original-signed-fixture', Guard::PROOF => proof }
      @records[reference] = { id: @records.length + 1, data: data, cipher: nil }
      handle = find_by(session_id: reference)
      state = { 'phase' => 'READY', 'proof' => proof, 'refresh_token' => 'initial-refresh', 'checked_at' => checked_at }
      handle.with_lock { Refresh.write!(handle, state, reference) }
      handle
    end
    def uncached; yield; end
    def connection; self; end
    def transaction_open?; !!outer_transaction; end
    def find_by(session_id:); @records.key?(session_id) ? Row.new(self, session_id) : nil; end
    def where(**criteria); Scope.new(self, criteria); end
    def with_lock(reference)
      @locks[reference].synchronize do
        previous = Thread.current[:refresh_fixture_row_lock]
        Thread.current[:refresh_fixture_row_lock] = true
        begin
          yield
        ensure
          Thread.current[:refresh_fixture_row_lock] = previous
        end
      end
    end
    class Row
      def initialize(repo, reference); @repo = repo; @reference = reference; end
      def id; @repo.records.fetch(@reference)[:id]; end
      def data; @repo.records.fetch(@reference)[:data]; end
      def read_attribute(_column); @repo.records.fetch(@reference)[:cipher]; end
      def with_lock; @repo.with_lock(@reference) { yield }; end
    end
    class Scope
      def initialize(repo, criteria); @repo = repo; @criteria = criteria; end
      def target
        entry = @repo.records[@criteria[:session_id]]
        entry if entry && (!@criteria.key?(:id) || entry[:id] == @criteria[:id])
      end
      def update_all(values)
        raise 'fixture database persistence failed' if @repo.fail_write
        entry = target
        return 0 unless entry
        entry[:cipher] = values.fetch(Refresh::COLUMN)
        1
      end
      def delete_all
        return 0 unless target
        @repo.records.delete(@criteria[:session_id]); 1
      end
    end
  end

  def self.sign(claims)
    encode = ->(value) { Base64.urlsafe_encode64(JSON.generate(value), padding: false) }
    input = [encode.call({ 'alg' => 'RS256' }), encode.call(claims)].join('.')
    "#{input}.#{Base64.urlsafe_encode64(KEY.sign('SHA256', input), padding: false)}"
  end

  class Decoded
    attr_reader :raw_attributes
    def initialize(claims); @raw_attributes = claims; end
    # Exact pinned IdToken.verify! predicates, with fixture errors only.
    def verify!(expected = {})
      raise OpenIDConnect::ResponseObject::IdToken::ExpiredToken, 'Expired' unless raw_attributes['exp'].to_i > Time.now.to_i
      raise OpenIDConnect::ResponseObject::IdToken::InvalidIssuer, 'Issuer' unless raw_attributes['iss'] == expected[:issuer]
      raise OpenIDConnect::ResponseObject::IdToken::InvalidNonce, 'Nonce' unless raw_attributes['nonce'] == expected[:nonce]
      raise OpenIDConnect::ResponseObject::IdToken::InvalidAudience, 'Audience' unless Array(raw_attributes['aud']).include?(expected[:client_id])
      true
    end
  end

  class Strategy
    attr_reader :options
    def initialize(_app)
      @options = OpenStruct.new(issuer: ISSUER, client_auth_method: 'not_required', client_options: OpenStruct.new(
        identifier: CLIENT, token_endpoint: "#{ISSUER}/protocol/openid-connect/token", secret: nil))
    end
    def discover!; end
    def decode_id_token(token)
      header, body, signature = token.split('.')
      algorithm = JSON.parse(Base64.urlsafe_decode64(header)).fetch('alg')
      raise 'Signature' unless algorithm == 'RS256' && KEY.verify('SHA256', Base64.urlsafe_decode64(signature), "#{header}.#{body}")
      Decoded.new(JSON.parse(Base64.urlsafe_decode64(body)))
    end
  end

  # Pinned activerecord-session_store 2.2.0 write_session dispatch. The fake
  # record emulates only data persistence; AR readonly filtering is separate.
  class NativeWriter
    attr_reader :saved_data, :save_calls
    def initialize(repo, reference, native_result: true)
      @repo = repo; @reference = reference; @native_result = native_result; @save_calls = 0
    end
    def logger; self; end
    def silence; yield; end
    def get_session_model(_request, sid); [self, sid]; end
    def data=(value); @saved_data = value; end
    def data; @saved_data; end
    def save
      @save_calls += 1
      return false unless @native_result
      @repo.records.fetch(@reference)[:data] = @saved_data
      true
    end
    def write_session(request, sid, session_data, options)
      logger.silence do
        record, sid = get_session_model(request, sid)
        record.data = session_data
        return false unless record.save
        session_data = record.data
        if session_data && session_data.respond_to?(:each_value)
          session_data.each_value do |obj|
            obj.clear_association_cache if obj.respond_to?(:clear_association_cache)
          end
        end
        sid
      end
    end
  end

  class Response
    attr_reader :code
    def initialize(code, chunks); @code = code; @chunks = chunks; end
    def read_body; @chunks.each { |chunk| yield chunk }; end
  end

  class Http
    attr_accessor :use_ssl, :verify_mode, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :requests, :closed
    def initialize(response); @response = response; @requests = []; end
    def start
      yield self
    ensure
      @closed = true
    end
    def request(request); @requests << request; yield @response; end
  end

  class ReadonlyNativeRow
    def self.column_names; %w[id session_id data wasalx_oidc_refresh_state]; end
    def self.readonly_attribute?(name); name == Refresh::COLUMN; end
    def self.counter_cache_column?(_name); false; end
    def column_for_attribute(_name); OpenStruct.new(virtual?: false); end
    # Exact installed ActiveRecord 8.0.5.1 attribute_methods.rb:508-515.
    def attributes_for_update(attribute_names)
      attribute_names &= self.class.column_names
      attribute_names.delete_if do |name|
        self.class.readonly_attribute?(name) ||
          self.class.counter_cache_column?(name) ||
          column_for_attribute(name).virtual?
      end
    end
  end
end

module OmniAuth
  module Strategies
    OidcDatabase = RefreshFixtures::Strategy unless const_defined?(:OidcDatabase)
  end
end

class NativeRefreshContract < Minitest::Test
  include RefreshFixtures
  def setup
    @repo = Repository.new
    @cipher = Cipher.new
    @proof = { 'issuer' => ISSUER, 'client_id' => CLIENT, 'subject' => 'same-subject', 'sid' => 'same-idp-session',
      'nonce' => 'original-nonce', 'auth_time' => Time.now.to_i - 300, 'native_authenticated_at' => Time.now.to_i - 300,
      'native_user_id' => '19', 'rails_session_id' => 'own-private-session',
      'token_sha256' => Digest::SHA256.hexdigest('original-signed-fixture') }
    @claims = { 'iss' => ISSUER, 'aud' => CLIENT, 'sub' => 'same-subject', 'sid' => 'same-idp-session',
      'auth_time' => @proof['auth_time'], 'iat' => Time.now.to_i, 'exp' => Time.now.to_i + 300 }
    @response = { 'id_token' => RefreshFixtures.sign(@claims), 'refresh_token' => 'rotated-refresh', 'token_type' => 'Bearer' }
    @calls = []
    @response_action = -> { @response }
    @restore = {}
    replace(Refresh, :rows) { @fixture_repo }
    Refresh.instance_variable_set(:@fixture_repo, @repo)
    replace(Refresh, :encryptor) { @fixture_cipher }
    Refresh.instance_variable_set(:@fixture_cipher, @cipher)
    fixture = self
    replace(Refresh, :token_response) do |uri, client, token|
      fixture.instance_variable_get(:@calls) << [uri.to_s, client, token]
      fixture.instance_variable_get(:@response_action).call
    end
    replace(Guard, :configuration) { [ISSUER, CLIENT] }
    @repo.seed(@proof['rails_session_id'], @proof)
  end

  def replace(object, name, &block)
    @restore[[object, name]] ||= object.method(name)
    object.define_singleton_method(name, &block)
  end

  def teardown
    @restore.each { |(object, name), method| object.define_singleton_method(name, method) }
    Refresh.remove_instance_variable(:@fixture_repo)
    Refresh.remove_instance_variable(:@fixture_cipher)
  end

  def allowed; Refresh.allowed?(@proof['rails_session_id'], @proof); end
  def state(reference = @proof['rails_session_id'])
    Refresh.open(@repo.records.fetch(reference)[:cipher], reference)
  end

  def test_refresh_uses_only_same_native_client_rotates_and_preserves_original_ages
    before = Marshal.load(Marshal.dump(@proof))
    assert allowed
    assert_equal [["#{ISSUER}/protocol/openid-connect/token", CLIENT, 'initial-refresh']], @calls
    assert_equal 'rotated-refresh', state['refresh_token']
    assert_equal before, state['proof']
    assert_equal before, @proof
    assert allowed
    assert_equal 1, @calls.length, 'fresh validation does not repeat the grant'
  end

  def test_same_sso_reauthentication_can_advance_provider_time_without_extending_native_age
    original = Marshal.load(Marshal.dump(@proof))
    @response['id_token'] = RefreshFixtures.sign(@claims.merge('auth_time' => @proof['auth_time'] + 120))
    assert allowed
    assert_equal 1, @calls.length
    assert_equal original, state['proof']
    assert_equal original, @proof
    policy = { 'session_timeout_minutes' => 480 }
    after_original_deadline = original['auth_time'] + 480 * 60 + 1
    refute Guard.recent?(state['proof']['auth_time'], policy, after_original_deadline)
    assert Guard.recent?(original['auth_time'] + 120, policy, after_original_deadline),
      'using the newer provider time would incorrectly extend the native age'
  end

  def test_intent_is_durable_and_contains_no_replayable_grant_before_provider_effect
    @response_action = lambda do
      refute Thread.current[:refresh_fixture_row_lock], 'the intent transaction must finish before the grant POST'
      intent = state
      assert_equal 'IN_FLIGHT', intent['phase']
      refute intent.key?('refresh_token')
      raise Timeout::Error, 'unknown effect'
    end
    refute allowed
    refute allowed
    assert_equal 1, @calls.length
    refute @repo.records.key?(@proof['rails_session_id'])
  end

  def test_existing_in_flight_never_replays_even_if_process_died_before_sending
    record = @repo.find_by(session_id: @proof['rails_session_id'])
    old = state.reject { |key, _| key == 'refresh_token' }.merge('phase' => 'IN_FLIGHT', 'operation' => 'lost-process',
      'started_at' => Time.now.to_i - Refresh::WAIT_LIMIT - 1)
    record.with_lock { Refresh.write!(record, old, @proof['rails_session_id']) }
    refute allowed
    assert_empty @calls
  end

  def test_two_concurrent_own_session_checks_send_exactly_one_rotation
    entered = Queue.new; release = Queue.new
    @response_action = -> { entered << true; release.pop; @response }
    one = Thread.new { allowed }
    entered.pop
    two = Thread.new { allowed }
    sleep 0.1
    release << true
    assert one.value
    assert two.value
    assert_equal 1, @calls.length
  end

  def test_invalid_or_unknown_grant_denies_only_own_session
    other = @proof.merge('rails_session_id' => 'other-private-session', 'sid' => 'other-idp-session')
    @repo.seed(other['rails_session_id'], other)
    other_before = Marshal.dump(@repo.records.fetch(other['rails_session_id']))
    @response_action = -> { raise 'invalid_grant' }
    refute allowed
    assert_equal other_before, Marshal.dump(@repo.records.fetch(other['rails_session_id']))
    assert_equal 1, @calls.length
  end

  def test_ciphertext_is_purpose_bound_and_cannot_move_between_native_sessions
    other = @proof.merge('rails_session_id' => 'other-private-session')
    @repo.seed(other['rails_session_id'], other)
    @repo.records[other['rails_session_id']][:cipher] = @repo.records[@proof['rails_session_id']][:cipher]
    refute Refresh.allowed?(other['rails_session_id'], other)
    assert_empty @calls
    assert @repo.records.key?(@proof['rails_session_id'])
  end

  def test_ciphertext_tampering_missing_state_or_changed_sid_denies_before_grant
    [:tamper, :missing, :sid, :user, :proof, :token].each do |kind|
      setup unless kind == :tamper
      record = @repo.records.fetch(@proof['rails_session_id'])
      case kind
      when :tamper then record[:cipher] = record[:cipher].reverse
      when :missing then record[:cipher] = nil
      when :sid then record[:data]['oidc_sid'] = 'foreign'
      when :user then record[:data]['user_id'] = '20'
      when :proof then record[:data][Guard::PROOF] = @proof.merge('auth_time' => Time.now.to_i)
      when :token then record[:data]['oidc_id_token'] = 'foreign'
      end
      refute allowed, kind
      assert_empty @calls
      teardown unless kind == :token
    end
  end

  def test_provider_signature_and_all_identity_binding_failures_deny_without_retry
    variants = {
      issuer: { 'iss' => 'https://foreign.example.test' }, audience: { 'aud' => 'foreign' },
      subject: { 'sub' => 'foreign' }, sid: { 'sid' => 'foreign' }, nonce: { 'nonce' => 'foreign' },
      earlier_auth_time: { 'auth_time' => @proof['auth_time'] - 1 },
      future_auth_time: { 'auth_time' => Time.now.to_i + 60 },
      malformed_auth_time: { 'auth_time' => Time.now.to_i.to_s },
      negative_auth_time: { 'auth_time' => -1 }, azp: { 'azp' => 'foreign' },
      future_iat: { 'iat' => Time.now.to_i + 60 }, expired: { 'exp' => Time.now.to_i - 1 },
      multiple_aud_without_azp: { 'aud' => [CLIENT, 'foreign'] }, missing_sid: { 'sid' => nil }
    }
    variants.each_with_index do |(kind, changes), index|
      setup unless index.zero?
      @response['id_token'] = RefreshFixtures.sign(@claims.merge(changes))
      refute allowed, kind
      refute allowed, kind
      assert_equal 1, @calls.length, kind
      refute @repo.records.key?(@proof['rails_session_id']), kind
      teardown unless index == variants.length - 1
    end
  end

  def test_pinned_native_verification_exceptions_resolve_to_gem_standard_error_base
    native = OpenIDConnect::ResponseObject::IdToken
    assert_equal OpenIDConnect::Exception, native::InvalidToken.superclass
    assert_equal StandardError, OpenIDConnect::Exception.superclass
    [native::ExpiredToken, native::InvalidIssuer, native::InvalidNonce, native::InvalidAudience].each do |error|
      assert error < StandardError
    end
  end

  def test_client_configuration_or_endpoint_drift_refuses_before_any_credential_leaves
    variants = [
      ->(options) { options.issuer = 'https://foreign.example.test' },
      ->(options) { options.client_options.identifier = 'foreign' },
      ->(options) { options.client_options.token_endpoint = 'http://identity.example.test/token' },
      ->(options) { options.client_options.token_endpoint = 'https://foreign.example.test/token' },
      ->(options) { options.client_options.token_endpoint = ['https', '://', 'user', ':', 'password', '@', 'identity.example.test', '/', 'token'].join("") },
      ->(options) { options.client_options.token_endpoint += '#fragment' },
      ->(options) { options.client_options.secret = 'unsupported-secret' },
      ->(options) { options.client_auth_method = 'jwt_bearer' }
    ]
    variants.each_with_index do |change, index|
      setup unless index.zero?
      strategy = Strategy.new(nil)
      change.call(strategy.options)
      replace(OmniAuth::Strategies::OidcDatabase, :new) { |*_args| strategy }
      refute allowed
      assert_empty @calls
      teardown unless index == variants.length - 1
    end
  end

  def test_bad_signature_fails_and_refresh_nonce_can_be_omitted_or_match_original
    @response['id_token'] = RefreshFixtures.sign(@claims).sub(/.$/, '!')
    refute allowed
    assert_equal 1, @calls.length
  end

  def test_refresh_nonce_match_and_no_new_refresh_token_are_supported_standard_responses
    @response['id_token'] = RefreshFixtures.sign(@claims.merge('nonce' => @proof['nonce']))
    @response.delete('refresh_token')
    assert allowed
    assert_equal 'initial-refresh', state['refresh_token']
  end

  def test_backchannel_or_normal_signout_during_grant_cannot_resurrect_session
    @response_action = -> { @repo.records.delete(@proof['rails_session_id']); @response }
    refute allowed
    refute @repo.records.key?(@proof['rails_session_id'])
    assert_equal 1, @calls.length
  end

  def test_persistence_failure_after_success_never_reuses_old_credential
    @response_action = -> { @repo.fail_write = true; @response }
    refute allowed
    @repo.fail_write = false
    refute allowed
    assert_equal 1, @calls.length
  end

  def test_outer_transaction_denies_before_intent_or_network
    @repo.outer_transaction = true
    before = @repo.records[@proof['rails_session_id']][:cipher].dup
    refute allowed
    assert_empty @calls
    assert_equal before, @repo.records[@proof['rails_session_id']][:cipher]
  end

  def test_outer_transaction_can_read_a_fresh_validation_without_issuing_any_grant
    @repo.seed(@proof['rails_session_id'], @proof, checked_at: Time.now.to_i)
    @repo.outer_transaction = true
    assert allowed
    assert_empty @calls
  end

  def test_own_in_flight_does_not_poison_other_session_refresh
    other = @proof.merge('rails_session_id' => 'other-private-session', 'sid' => 'other-idp-session')
    @repo.seed(other['rails_session_id'], other)
    entered = Queue.new; release = Queue.new
    @response_action = lambda do
      if Thread.current[:first]
        entered << true; release.pop; @response
      else
        @response.merge('id_token' => RefreshFixtures.sign(@claims.merge('sid' => other['sid'])))
      end
    end
    first = Thread.new { Thread.current[:first] = true; allowed }
    entered.pop
    assert Refresh.allowed?(other['rails_session_id'], other)
    release << true
    assert first.value
    assert_equal 2, @calls.length
  end

  def test_valid_proof_still_obeys_original_policy_age_before_refresh
    user = OpenStruct.new(id: '19')
    membership = OpenStruct.new(subject: @proof['subject'])
    policy = { 'mfa_required' => true, 'session_timeout_minutes' => 15, 'policy_version' => 1,
      'subject' => @proof['subject'], 'mfa_amr_values' => ['mfa'], 'mfa_acr_values' => [] }
    stale = @proof.merge('auth_time' => Time.now.to_i - 901, 'amr' => ['mfa'])
    @repo.seed(stale['rails_session_id'], stale)
    stored = @repo.find_by(session_id: stale['rails_session_id'])
    replace(Guard, :stored_session) { |*_args| stored }
    refute Guard.allowed?(user, membership, { 'authentication_policy' => policy }, reference: stale['rails_session_id'])
    assert_empty @calls
    policy['mfa_required'] = false
    stale['native_authenticated_at'] = Time.now.to_i - 901
    refute Guard.allowed?(user, membership, { 'authentication_policy' => policy }, reference: stale['rails_session_id'])
    assert_empty @calls
  end

  def test_composed_guard_requires_liveness_for_managed_oidc_but_never_advances_mfa
    user = OpenStruct.new(id: '19')
    membership = OpenStruct.new(subject: @proof['subject'])
    policy = { 'mfa_required' => true, 'session_timeout_minutes' => 15, 'policy_version' => 1,
      'subject' => @proof['subject'], 'mfa_amr_values' => ['mfa'], 'mfa_acr_values' => [] }
    @proof['amr'] = ['mfa']
    @repo.seed(@proof['rails_session_id'], @proof)
    stored = @repo.find_by(session_id: @proof['rails_session_id'])
    replace(Guard, :stored_session) { |*_args| stored }
    assert Guard.allowed?(user, membership, { 'authentication_policy' => policy }, reference: @proof['rails_session_id'])
    assert_equal 1, @calls.length
    before = state['proof'].dup
    assert_equal @proof['auth_time'], before['auth_time']
    @proof['amr'] = ['pwd']
    refute Guard.allowed?(user, membership, { 'authentication_policy' => policy }, reference: @proof['rails_session_id'])
    assert_equal 1, @calls.length, 'refresh cannot manufacture a stronger original authentication'
  end

  def test_normal_native_save_precedes_enrollment_and_keeps_grant_out_of_session_data
    reference = @proof['rails_session_id']
    @repo.records[reference][:cipher] = nil
    data = @repo.records[reference][:data]
    request = OpenStruct.new(env: { Refresh::PENDING => { 'proof' => @proof, 'refresh_token' => 'initial-refresh' } })
    writer = Class.new(NativeWriter) { prepend Refresh::Store }.new(@repo, reference)
    sid = OpenStruct.new(private_id: reference)
    assert_same sid, writer.send(:write_session, request, sid, data, {})
    assert_equal 1, writer.save_calls
    refute request.env.key?(Refresh::PENDING)
    assert_equal 'initial-refresh', state['refresh_token']
    refute_includes JSON.generate(writer.saved_data), 'initial-refresh'
    refute_includes @repo.records[reference][:cipher], 'initial-refresh'
    assert_empty @calls
  end

  def test_ordinary_native_whole_data_save_does_not_overwrite_a_rotated_private_column
    reference = @proof['rails_session_id']
    old_data = Marshal.load(Marshal.dump(@repo.records[reference][:data]))
    assert allowed
    ciphertext = @repo.records[reference][:cipher].dup
    writer = Class.new(NativeWriter) { prepend Refresh::Store }.new(@repo, reference)
    request = OpenStruct.new(env: {})
    writer.send(:write_session, request, OpenStruct.new(private_id: reference), old_data.merge('ping' => true), {})
    assert_equal ciphertext, @repo.records[reference][:cipher]
    assert_equal 'rotated-refresh', state['refresh_token']
  end

  def test_failed_native_save_cannot_enroll_and_duplicate_enrollment_never_replaces_existing_grant
    reference = @proof['rails_session_id']
    before = @repo.records[reference][:cipher].dup
    writer = Class.new(NativeWriter) { prepend Refresh::Store }.new(@repo, reference, native_result: false)
    request = OpenStruct.new(env: { Refresh::PENDING => { 'proof' => @proof, 'refresh_token' => 'initial-refresh' } })
    refute writer.send(:write_session, request, OpenStruct.new(private_id: reference), @repo.records[reference][:data], {})
    assert_equal before, @repo.records[reference][:cipher]
    refute Refresh.enroll!(reference, { 'proof' => @proof, 'refresh_token' => 'substitute' })
    refute @repo.records.key?(reference)
    assert_empty @calls
  end

  def test_actual_http_request_is_sole_bounded_tls_refresh_and_has_no_proxy_or_redirect
    original = @restore.fetch([Refresh, :token_response])
    response = Response.new('200', ['{"token_type":"Bearer",', '"id_token":"fixture"}'])
    http = Http.new(response)
    constructor = nil
    replace(Net::HTTP, :new) { |*args| constructor = args; http }
    result = original.call(URI("#{ISSUER}/protocol/openid-connect/token"), CLIENT, 'refresh-credential')
    assert_equal ['identity.example.test', 443, nil], constructor
    assert_equal 1, http.requests.length
    request = http.requests.first
    assert_instance_of Net::HTTP::Post, request
    assert_equal({ 'grant_type' => 'refresh_token', 'client_id' => CLIENT, 'refresh_token' => 'refresh-credential' }, URI.decode_www_form(request.body).to_h)
    refute request.key?('Authorization')
    assert http.use_ssl
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert_equal [Refresh::NETWORK_LIMIT] * 3, [http.open_timeout, http.read_timeout, http.write_timeout]
    assert_equal 0, http.max_retries
    assert http.closed
    assert_equal 'fixture', result['id_token']
  end

  def test_actual_http_refusal_redirect_or_oversized_body_raises_after_one_post
    original = @restore.fetch([Refresh, :token_response])
    [Response.new('400', []), Response.new('302', []), Response.new('200', ['x' * (Refresh::LIMIT + 1)]),
     Response.new('200', ['{"token_type":"foreign"}'])].each do |response|
      http = Http.new(response)
      replace(Net::HTTP, :new) { |*_args| http }
      assert_raises(StandardError) { original.call(URI("#{ISSUER}/protocol/openid-connect/token"), CLIENT, 'refresh') }
      assert_equal 1, http.requests.length
      assert http.closed
    end
  end

  def test_credential_byte_limit_rejects_multibyte_oversize_before_any_grant
    assert Refresh.credential?('a' * 32_768)
    refute Refresh.credential?('a' * 32_769)
    refute Refresh.credential?("\u00e9" * 20_000)
    reference = @proof['rails_session_id']
    @repo.records[reference][:cipher] = nil
    refute Refresh.enroll!(reference, { 'proof' => @proof, 'refresh_token' => "\u00e9" * 20_000 })
    assert_empty @calls
  end

  def test_exact_pinned_ar_update_filter_preserves_private_cipher_even_with_full_attribute_write
    columns = ReadonlyNativeRow.column_names
    filtered = ReadonlyNativeRow.new.attributes_for_update(columns)
    refute_includes filtered, Refresh::COLUMN
    assert_includes filtered, 'data'
    assert_includes filtered, 'session_id'
  end

  def test_completed_refresh_does_not_resurrect_or_merge_old_omniauth_nonce_fields
    reference = @proof['rails_session_id']
    data = @repo.records[reference][:data]
    data['omniauth.state'] = 'new-state'
    data['omniauth.nonce'] = 'new-nonce'
    before = Marshal.dump(data)
    assert allowed
    assert_equal before, Marshal.dump(@repo.records[reference][:data])
    refute state.key?('omniauth.state')
    refute state.key?('omniauth.nonce')
  end
end

# New ciphertext surfaces use the native serializer/options contract. Actual
# Rails/PG execution is separately qualified by the pinned dependency driver.
module RefreshSurfaceFixtures
  Column = Struct.new(:name, :type, :null, :default, :default_function, keyword_init: true)

  class Model
    class << self
      def filter_attributes
        return @filter_attributes if defined?(@filter_attributes)
        superclass.respond_to?(:filter_attributes) ? superclass.filter_attributes : []
      end
      def filter_attributes=(value); @filter_attributes = value; end
      def attr_readonly(name); @readonly = (readonly_attributes + [name]).uniq; end
      def readonly_attributes
        return @readonly if defined?(@readonly)
        superclass.respond_to?(:readonly_attributes) ? superclass.readonly_attributes : []
      end
    end
    attr_reader :attributes, :received_options
    def initialize(attributes); @attributes = attributes; end
    def read_attribute(name); attributes.fetch(name); end
    def label; 'native-label'; end
    def wasalx_oidc_refresh_state; read_attribute(Wasalx::SessionRefresh::COLUMN); end
    def serializable_hash(options = nil)
      @received_options = options
      names = attributes.keys
      names &= Array(options[:only]).map(&:to_s) if options && options[:only]
      names -= Array(options[:except]).map(&:to_s) if options && options[:except]
      names.to_h { |name| [name, read_attribute(name)] }.tap do |result|
        Array(options && options[:methods]).each { |name| result[name.to_s] = public_send(name) }
      end
    end
    def as_json(options = nil); serializable_hash(options); end
    def to_json(*arguments); as_json.to_json(*arguments); end
  end

  class Schema
    attr_accessor :column, :write_error, :read_error
    attr_reader :adds, :queries
    def initialize(column = nil); @column = column; @adds = []; @queries = []; end
    def connection; self; end
    def columns(table)
      @queries << table
      raise read_error if read_error
      [column].compact
    end
    def add_column(table, name, type, **options)
      @adds << [table, name, type, options]
      raise write_error if write_error
      @column = Column.new(name: name.to_s, type: type, null: options.fetch(:null), default: options.fetch(:default))
    end
  end
end

load File.join(ENV.fetch('WASALX_TEST_PACKAGE_ROOT', File.expand_path('../zammad-package', __dir__)),
               'db/addon/wasalx/202610170001_add_wasalx_session_refresh.rb')

class NativeRefreshSurfaceContract < Minitest::Test
  Refresh = Wasalx::SessionRefresh
  Column = RefreshSurfaceFixtures::Column
  MIGRATION = 'db/addon/wasalx/202610170001_add_wasalx_session_refresh.rb'

  def with_constant(owner, name, value)
    previous = owner.const_get(name, false) if owner.const_defined?(name, false)
    owner.send(:remove_const, name) if owner.const_defined?(name, false)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name) if owner.const_defined?(name, false)
    owner.const_set(name, previous) if previous
  end

  def with_models
    base = Class.new(RefreshSurfaceFixtures::Model)
    rows = Class.new(base)
    native = Class.new(rows)
    base.filter_attributes = ['base-secret']
    rows.filter_attributes = ['session-secret']
    native.filter_attributes = ['native-secret']
    with_constant(ActiveRecord, :Base, base) do
      with_constant(ActiveRecord::SessionStore, :Session, rows) do
        with_constant(Object, :Session, native) { yield base, rows, native }
      end
    end
  end

  def valid_column(**changes)
    Column.new(**{ name: Refresh::COLUMN, type: :text, null: true, default: nil, default_function: nil }.merge(changes))
  end

  def verify_schema(column, owned: true)
    rows = Class.new do
      class << self
        attr_accessor :column, :resets
        def reset_column_information; self.resets = (resets || 0) + 1; end
        def columns_hash
          raise 'schema cache was not reset' unless resets == 1
          column ? { Wasalx::SessionRefresh::COLUMN => column } : {}
        end
      end
    end
    rows.column = column
    source = File.read(File.expand_path('../infra/docker/full/zammad/verify-package.rb', __dir__))
    block = source.match(/^refresh_migration = [^\n]+\nif seen_locations\[refresh_migration\]\n.*?^end\n/m)
    raise 'conditional refresh verification block absent' unless block
    scope = binding
    scope.local_variable_set(:seen_locations, owned ? { MIGRATION => true } : {})
    with_constant(ActiveRecord::SessionStore, :Session, rows) { eval(block[0], scope, 'verify-package.rb', 1) }
    rows.resets
  end

  def test_default_admin_list_serialization_masks_ciphertext_but_internal_attributes_remain
    with_models do |_base, rows, native|
      Refresh.protect_models!
      [rows, native].each do |model|
        attributes = { 'id' => 7, 'data' => { 'user_id' => 19 }, Refresh::COLUMN => 'synthetic-encrypted-state' }
        row = model.new(attributes)
        assert_equal({ 'id' => 7, 'data' => { 'user_id' => 19 } }, row.serializable_hash)
        result = JSON.parse(JSON.generate(sessions: [row]))
        refute_includes JSON.generate(result), 'synthetic-encrypted-state'
        refute result.fetch('sessions').first.key?(Refresh::COLUMN)
        assert_same attributes, row.attributes
        assert_equal 'synthetic-encrypted-state', row.read_attribute(Refresh::COLUMN)
      end
    end
  end

  def test_serialization_options_and_explicit_method_cannot_reintroduce_ciphertext
    with_models do |_base, rows, _native|
      Refresh.protect_models!
      row = rows.new('id' => 7, 'data' => { 'user_id' => 19 }, Refresh::COLUMN => 'synthetic-encrypted-state')
      options = { only: [:id, Refresh::COLUMN.to_sym], methods: [:wasalx_oidc_refresh_state, :label], include: :unrelated }.freeze
      before = Marshal.dump(options)
      assert_equal({ 'id' => 7, 'label' => 'native-label' }, row.serializable_hash(options))
      assert_same options, row.received_options
      assert_equal before, Marshal.dump(options)
      assert_equal({ 'data' => { 'user_id' => 19 } }, row.serializable_hash(except: :id))
      assert_empty row.serializable_hash(only: Refresh::COLUMN)
    end
  end

  def test_prepare_registration_preserves_existing_filters_and_is_idempotent
    with_models do |base, rows, native|
      2.times { Refresh.protect_models! }
      [[base, 'base-secret'], [rows, 'session-secret'], [native, 'native-secret']].each do |model, existing|
        assert_includes model.filter_attributes, existing
        assert_equal 1, model.filter_attributes.count(Refresh::COLUMN)
      end
      [rows, native].each do |model|
        assert_includes model.readonly_attributes, Refresh::COLUMN
        assert_equal 1, model.ancestors.count(Refresh::Serialization)
      end
    end
  end

  def test_migration_adds_nullable_text_without_default_once_and_retains_ciphertext
    schema = RefreshSurfaceFixtures::Schema.new
    with_constant(ActiveRecord, :Migration, schema) do
      AddWasalxSessionRefresh.up
      original = schema.column
      AddWasalxSessionRefresh.up
      AddWasalxSessionRefresh.down
      assert_same original, schema.column
      assert_equal [[:sessions, :wasalx_oidc_refresh_state, :text, { null: true, default: nil }]], schema.adds
    end
  end

  def test_migration_refuses_existing_wrong_type_null_default_or_expression_without_write
    [valid_column(type: :string), valid_column(null: false), valid_column(default: 'unsafe'),
     valid_column(default_function: 'unsafe_expression()')].each do |column|
      schema = RefreshSurfaceFixtures::Schema.new(column)
      with_constant(ActiveRecord, :Migration, schema) do
        error = assert_raises(RuntimeError) { AddWasalxSessionRefresh.up }
        assert_equal 'WasalX native refresh storage is incompatible', error.message
        assert_empty schema.adds
        assert_same column, schema.column
      end
    end
  end

  def test_migration_schema_read_failure_propagates_without_schema_write
    schema = RefreshSurfaceFixtures::Schema.new
    schema.read_error = IOError.new('synthetic schema read failed')
    with_constant(ActiveRecord, :Migration, schema) do
      assert_same schema.read_error, assert_raises(IOError) { AddWasalxSessionRefresh.up }
      assert_empty schema.adds
    end
  end

  def test_migration_add_failure_propagates_without_false_success_or_automatic_retry
    schema = RefreshSurfaceFixtures::Schema.new
    schema.write_error = IOError.new('synthetic schema write failed')
    with_constant(ActiveRecord, :Migration, schema) do
      assert_same schema.write_error, assert_raises(IOError) { AddWasalxSessionRefresh.up }
      assert_equal 1, schema.adds.length
      assert_nil schema.column
    end
  end

  def test_owned_package_verification_resets_metadata_and_accepts_exact_storage
    assert_equal 1, verify_schema(valid_column)
  end

  def test_owned_package_verification_refuses_missing_or_incompatible_storage
    [nil, valid_column(type: :string), valid_column(null: false), valid_column(default: 'unsafe'),
     valid_column(default_function: 'unsafe_expression()')].each do |column|
      error = assert_raises(RuntimeError) { verify_schema(column) }
      assert_equal 'WasalX native refresh storage is unavailable', error.message
    end
  end

  def test_old_package_without_refresh_migration_does_not_require_new_schema
    assert_nil verify_schema(nil, owned: false)
  end
end

require_relative 'fixtures/native-session-state-contract'
