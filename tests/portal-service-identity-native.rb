# SPDX-License-Identifier: AGPL-3.0-only
# Execute only in the isolated native Rails runner; all fixture writes roll back.
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
raise 'Isolated native diagnostic required' unless ENV['WASALX_NATIVE_DIAGNOSTIC'] == 'true'
require 'securerandom'
require Rails.root.join('lib/wasalx/portal_service_identity')
assert = ->(value, message) { raise message unless value }
guard = Wasalx::ServiceIdentity
original_post = Wasalx::Client.method(:post)
original_actor = UserInfo.current_user_id
begin
  UserInfo.current_user_id = 1
  Transaction.execute do
    raise 'Existing identity receipt must not be replaced' if guard.handover_evidence?
    suffix = SecureRandom.hex(8)
    owner = User.create!(login: "fresh-owner-#{suffix}", email: "owner-#{suffix}@example.invalid", firstname: 'Synthetic Owner',
      active: true, verified: true, role_ids: Role.where(name: %w[Admin Agent]).pluck(:id), created_by_id: 1, updated_by_id: 1)
    subject = "fresh-owner-#{suffix}"
    Authorization.create!(user_id: owner.id, provider: 'openid_connect', uid: subject)
    tokens = guard::LEGACY_SCOPES.to_h do |purpose, scopes|
      [purpose, Token.create!(user_id: owner.id, action: 'api', persistent: true,
        name: purpose == 'runtime' ? 'WasalX Service' : 'WasalX Privacy', preferences: { permission: scopes })]
    end
    secrets = tokens.transform_values(&:token)
    before_users = User.count
    receipt = guard.provision_fresh!(owner: owner, subject: subject, email: owner.email, secrets: secrets)
    machine = User.find(receipt.fetch('automation_native_user_id'))
    assert.call(User.count == before_users + 1 && machine.id != owner.id, 'Exactly one separate machine required')
    assert.call(receipt['origin'] == 'FRESH' && !receipt.key?('legacy_native_user_id'), 'Fresh receipt invented a predecessor')
    assert.call(machine.group_ids_access_map.empty? && machine.password.blank? && !machine.permissions?('admin'), 'Machine received unapproved human authority')
    assert.call(tokens.all? { |purpose, token| token.reload.user_id == machine.id && token.token == secrets[purpose] }, 'Binding rotated values or changed token identity')
    guard.verify_startup!(receipt, secrets: secrets)
    before = [User.count, receipt, tokens.transform_values { |token| token.reload.attributes }]
    begin
      guard.provision_fresh!(owner: owner, subject: subject, email: owner.email, secrets: secrets)
      raise 'Fresh initialization was replayed'
    rescue guard::Conflict
    end
    assert.call(before == [User.count, guard.receipt, tokens.transform_values { |token| token.reload.attributes }], 'Rejected initialization mutated identity')
    portal_id = SecureRandom.uuid
    payload = { 'action' => 'APPLY', 'tenant_id' => ENV.fetch('WASALX_TENANT_ID'), 'instance_id' => ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'),
      'user_id' => portal_id, 'subject' => subject, 'email' => owner.email, 'name' => 'Synthetic Owner', 'role' => 'tenant_owner',
      'state' => 'ACTIVE', 'revision' => 1, 'native_user_id' => nil, 'adopt_user_id' => nil }
    projected = Wasalx::MembershipProjection.call(payload, service_user: machine)
    assert.call(projected[:state] == 'READY' && projected[:native_user_id] == owner.id.to_s, 'Configured real owner was not projected automatically')
    assert.call(Wasalx::MembershipProjection.call(payload, service_user: machine) == projected, 'Owner projection replay drifted identity')
    allowed = true
    Wasalx::Client.define_singleton_method(:post) do |path, input, scope:, **_options|
      raise 'Unexpected private request' unless path == '/internal/v1/zammad/membership/check' && scope == 'zammad:membership'
      { 'allowed' => allowed && input[:user_id] == portal_id, 'authentication_policy' => {
        'subject' => subject, 'mfa_required' => true, 'session_timeout_minutes' => 60, 'policy_version' => 1,
        'mfa_amr_values' => ['mfa'], 'mfa_acr_values' => [] } }
    end
    assert.call(guard.owner!(receipt).id == owner.id, 'Current owner proof failed')
    envelope = { 'tenant_id' => ENV.fetch('WASALX_TENANT_ID'), 'instance_id' => ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'),
      'actor' => { 'user_id' => portal_id, 'revision' => 1, 'native_user_id' => owner.id.to_s, 'subject' => subject, 'email' => owner.email }, 'operation' => 'IDENTITY_STATUS', 'input' => {
        'configured_runtime_sha256' => Digest::SHA256.hexdigest(secrets['runtime']),
        'configured_privacy_sha256' => Digest::SHA256.hexdigest(secrets['privacy']) } }
    invoke = ->(operation, input) do
      value = envelope.merge('operation' => operation, 'input' => envelope['input'].merge(input))
      Wasalx::PortalServiceIdentity.new(actor: owner, token: tokens['runtime'], envelope: value, authorizer: -> { guard.owner!(receipt) }).call
    end
    group = Group.create!(name: "Fresh service proof #{suffix}", active: true, created_by_id: owner.id, updated_by_id: owner.id)
    status = invoke.call('IDENTITY_STATUS', { 'teams_after' => (group.id - 1).to_s })
    item = status[:groups].find { |row| row[:id] == group.id.to_s }
    assert.call(status[:portal_ready] && !item[:enabled] && !status[:can_complete], 'Fresh readiness/grant/retirement semantics drifted')
    id = SecureRandom.uuid
    mutation = { 'request_id' => id, 'team_id' => group.id.to_s, 'expected_version' => item[:version], 'enabled' => true }
    result = invoke.call('IDENTITY_GRANT', mutation)
    assert.call(result[:state] == 'APPLIED' && machine.reload.group_ids_access_map[group.id] == ['full'], 'Explicit machine grant was not persisted')
    assert.call(invoke.call('IDENTITY_RECEIPT', { 'request_id' => id, 'kind' => 'IDENTITY_GRANT', 'team_id' => group.id.to_s, 'action' => 'LOOKUP' })['state'] == 'APPLIED', 'Lost grant response not recoverable')
    cancelled = SecureRandom.uuid
    cancel = { 'request_id' => cancelled, 'kind' => 'IDENTITY_GRANT', 'team_id' => group.id.to_s, 'action' => 'CANCEL_IF_UNADMITTED' }
    assert.call(invoke.call('IDENTITY_RECEIPT', cancel)[:state] == 'NOT_APPLIED', 'Explicit cancellation did not persist')
    begin
      invoke.call('IDENTITY_GRANT', mutation.merge('request_id' => cancelled, 'enabled' => false))
      raise 'Cancelled original admitted'
    rescue Wasalx::PortalServiceIdentity::Conflict
    end
    allowed = false
    begin
      invoke.call('IDENTITY_GRANT', mutation.merge('request_id' => SecureRandom.uuid, 'enabled' => false))
      raise 'Revoked owner admitted'
    rescue guard::Conflict
    end
    puts JSON.generate({ fixture: 'fresh-service-identity', owner_projected: true, no_native_browser: true,
      machine_separate: true, grant_saved: true, durable_recovery: true, cancellation_fenced: true, revoked_denied: true })
    raise ActiveRecord::Rollback
  end
ensure
  Wasalx::Client.define_singleton_method(:post, original_post)
  UserInfo.current_user_id = original_actor
end
