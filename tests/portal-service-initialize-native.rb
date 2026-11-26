# SPDX-License-Identifier: AGPL-3.0-only
raise 'Isolated native diagnostic required' unless ENV['WASALX_NATIVE_DIAGNOSTIC'] == 'true'
# Copyright (c) 2026 WasalX
require Rails.root.join('lib/wasalx/portal_service_identity')
require Rails.root.join('app/controllers/api/v1/wasalx_service_identities_controller')
assert = ->(value, message) { raise message unless value }
deny = lambda do |error, &block|
  begin
    block.call
  rescue error
    next
  end
  raise 'Denied service access unexpectedly succeeded'
end
guard = Wasalx::ServiceIdentity
original_post = Wasalx::Client.method(:post)
original_actor = UserInfo.current_user_id
begin
  UserInfo.current_user_id = 1
  Transaction.execute do
    raise 'Existing service receipt cannot be replaced' if guard.handover_evidence?
    suffix = SecureRandom.hex(8)
    owner = User.create!(login: "convert-owner-#{suffix}", email: "convert-#{suffix}@example.invalid", firstname: 'Synthetic Owner',
      active: true, verified: true, role_ids: Role.where(name: %w[Admin Agent]).pluck(:id), created_by_id: 1, updated_by_id: 1)
    subject = "convert-owner-#{suffix}"; portal_id = SecureRandom.uuid
    Authorization.create!(user_id: owner.id, provider: 'openid_connect', uid: subject)
    tokens = guard::LEGACY_SCOPES.to_h do |purpose, scopes|
      [purpose, Token.create!(user_id: owner.id, action: 'api', persistent: true,
        name: purpose == 'runtime' ? 'WasalX Service' : 'WasalX Privacy', preferences: { permission: scopes })]
    end
    secrets = tokens.transform_values(&:token)
    source = { 'issuer' => 'https://identity.example.invalid', 'audience' => 'wasalx-api' }
    policy = { 'subject' => subject, 'mfa_required' => true, 'session_timeout_minutes' => 60, 'policy_version' => 1,
      'mfa_amr_values' => ['mfa'], 'mfa_acr_values' => [] }
    projection = { 'action' => 'APPLY', 'tenant_id' => ENV.fetch('WASALX_TENANT_ID'), 'instance_id' => ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'),
      'user_id' => portal_id, 'subject' => subject, 'email' => owner.email, 'name' => owner.fullname,
      'role' => 'tenant_owner', 'state' => 'ACTIVE', 'revision' => 4, 'native_user_id' => nil, 'adopt_user_id' => nil }
    allowed = true
    Wasalx::Client.define_singleton_method(:post) do |path, input, scope:, **_options|
      raise 'Unexpected signed control request' unless scope == 'zammad:membership' && path == '/internal/v1/zammad/membership/bootstrap-check'
      current = allowed && input[:user_id] == portal_id && input[:subject] == subject && input[:email] == owner.email && input[:revision] == 4
      { 'allowed' => current, 'authentication_policy' => policy, 'portal_source' => source,
        'privileged_reauth_minutes' => 15, 'projection' => projection }
    end
    envelope = { 'purpose' => Wasalx::PortalDelegation::IDENTITY_PURPOSE, 'tenant_id' => ENV.fetch('WASALX_TENANT_ID'),
      'instance_id' => ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'), 'source' => source,
      'actor' => { 'user_id' => portal_id, 'subject' => subject, 'email' => owner.email, 'revision' => 4, 'native_user_id' => nil },
      'assurance' => { 'auth_time' => Time.now.to_i, 'amr' => ['mfa'], 'acr' => nil }, 'operation' => 'IDENTITY_STATUS',
      'input' => { 'configured_runtime_sha256' => Digest::SHA256.hexdigest(secrets['runtime']), 'configured_privacy_sha256' => Digest::SHA256.hexdigest(secrets['privacy']) } }
    invoke = lambda do |operation, input, override = {}, after_lock = nil|
      value = envelope.merge('operation' => operation, 'input' => envelope['input'].merge(input)).merge(override)
      controller = Api::V1::WasalxServiceIdentitiesController.new
      controller.instance_variable_set(:@envelope, value)
      controller.define_singleton_method(:current_user) { Token.find(tokens['runtime'].id).user }
      actor = controller.send(:identity_actor!)
      Wasalx::PortalServiceIdentity.new(actor: actor, token: tokens['runtime'], envelope: value,
        authorizer: -> { after_lock&.call; controller.send(:identity_actor!) },
        bootstrap_projection: -> { controller.instance_variable_get(:@bootstrap_projection) }).call
    end
    status = invoke.call('IDENTITY_STATUS', {})
    assert.call(status[:can_initialize] && status[:access_required] && !status[:portal_ready], 'Protected owner setup status missing')
    id = SecureRandom.uuid
    input = { 'request_id' => id, 'expected_status_version' => status[:status_version] }
    deny.call(Exceptions::Forbidden) { invoke.call('IDENTITY_INITIALIZE', input, 'assurance' => envelope['assurance'].merge('amr' => [])) }
    deny.call(Api::V1::WasalxPortalWorkspaceController::ReauthenticationRequired) do
      invoke.call('IDENTITY_INITIALIZE', input, 'assurance' => envelope['assurance'].merge('auth_time' => Time.now.to_i - 16 * 60))
    end
    deny.call(Exceptions::Forbidden) { invoke.call('IDENTITY_INITIALIZE', input, 'source' => source.merge('audience' => 'foreign')) }
    deny.call(Exceptions::Forbidden) { invoke.call('IDENTITY_INITIALIZE', input, 'actor' => envelope['actor'].merge('email' => 'foreign@example.invalid')) }
    assert.call(!guard.handover_evidence? && !WasalxMembership.exists?(portal_user_id: portal_id), 'Denied setup mutated identity')
    deny.call(Exceptions::Forbidden) do
      invoke.call('IDENTITY_INITIALIZE', input, {}, -> { tokens['runtime'].update!(expires_at: 1.hour.ago) })
    end
    tokens['runtime'].update!(expires_at: nil)
    cancelled = SecureRandom.uuid
    cancel = { 'request_id' => cancelled.upcase, 'kind' => 'IDENTITY_INITIALIZE', 'action' => 'CANCEL_IF_UNADMITTED' }
    assert.call(invoke.call('IDENTITY_RECEIPT', cancel)[:state] == 'NOT_APPLIED', 'Setup cancellation did not persist')
    deny.call(Wasalx::PortalServiceIdentity::Conflict) { invoke.call('IDENTITY_INITIALIZE', input.merge('request_id' => cancelled.downcase)) }
    assert.call(!guard.handover_evidence?, 'Delayed cancelled setup admitted')
    snapshot = -> { [User.count, guard.receipt, tokens.transform_values { |token| token.reload.attributes },
      WasalxMembership.where(portal_user_id: portal_id).map(&:attributes),
      WasalxAdminOperation.where(operation_id: id).map(&:attributes), Delayed::Job.count] }
    before_failure = snapshot.call
    original_create = WasalxAdminOperation.method(:create!)
    begin
      WasalxAdminOperation.define_singleton_method(:create!) do |*args, **attributes|
        raise ActiveRecord::RecordInvalid.new(WasalxAdminOperation.new) if attributes[:kind] == 'IDENTITY_INITIALIZE'
        original_create.call(*args, **attributes)
      end
      deny.call(Wasalx::PortalServiceIdentity::StorageError) { invoke.call('IDENTITY_INITIALIZE', input) }
    ensure
      WasalxAdminOperation.define_singleton_method(:create!, original_create)
    end
    assert.call(snapshot.call == before_failure, 'Failed receipt leaked machine, membership, token, setting or delayed-job changes')
    applied = invoke.call('IDENTITY_INITIALIZE', input)
    receipt = guard.receipt
    assert.call(receipt['origin'] == 'OWNER_CONVERSION' && !receipt.key?('legacy_native_user_id'), 'Conversion fabricated retired predecessor')
    machine = User.find(receipt['automation_native_user_id'])
    member = WasalxMembership.find_by!(portal_user_id: portal_id)
    assert.call(machine.id != owner.id && machine.group_ids_access_map.empty? && machine.password.blank?, 'Conversion admitted human machine identity or default grants')
    assert.call(member.user_id == owner.id && member.revision == 4 && member.subject == subject, 'Conversion owner projection mismatch')
    assert.call(applied[:owner_projection][:native_user_id] == owner.id.to_s && applied[:owner_projection][:revision] == 4, 'Private settlement proof missing')
    # Simulate the response being lost: read the exact action receipt, never replay initialization.
    before = [User.count, guard.receipt, member.attributes, tokens.transform_values { |token| token.reload.attributes }]
    recovered = invoke.call('IDENTITY_RECEIPT', { 'request_id' => id.upcase, 'kind' => 'IDENTITY_INITIALIZE', 'action' => 'LOOKUP' })
    assert.call(recovered['state'] == 'APPLIED' && recovered['owner_projection']['native_user_id'] == owner.id.to_s, 'Lost conversion response not recoverable from PROTECTED state')
    assert.call(before == [User.count, guard.receipt, member.reload.attributes, tokens.transform_values { |token| token.reload.attributes }], 'Receipt lookup mutated native effects')
    auth = Authorization.find_by!(user_id: owner.id, provider: 'openid_connect', uid: subject)
    begin
      auth.update_columns(uid: subject + '-changed')
      deny.call(Exceptions::Forbidden) do
        invoke.call('IDENTITY_STATUS', {}, 'actor' => envelope['actor'].merge('subject' => subject + '-changed'))
      end
    ensure
      auth.update_columns(uid: subject)
    end
    original_email = owner.email
    begin
      owner.update_columns(email: 'changed-' + original_email)
      deny.call(Exceptions::Forbidden) do
        invoke.call('IDENTITY_STATUS', {}, 'actor' => envelope['actor'].merge('email' => 'changed-' + original_email))
      end
    ensure
      owner.update_columns(email: original_email)
    end
    allowed = false
    deny.call(Exceptions::Forbidden) { invoke.call('IDENTITY_RECEIPT', { 'request_id' => id, 'kind' => 'IDENTITY_INITIALIZE', 'action' => 'LOOKUP' }) }
    puts JSON.generate({ fixture: 'owner-service-initialize', mfa_denials: true, source_denials: true, post_lock_token_expiry_denied: true, failed_effect_rolled_back: true, changed_identity_denied: true,
      no_native_browser: true, zero_default_grants: true, durable_unknown_readback: true, cancellation_case_fenced: true })
    raise ActiveRecord::Rollback
  end
ensure
  Wasalx::Client.define_singleton_method(:post, original_post)
  UserInfo.current_user_id = original_actor
end
