# SPDX-License-Identifier: AGPL-3.0-only
require 'digest'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'openssl'

module Wasalx
  class PortalServiceIdentity
    class Conflict < StandardError; end
    class StorageError < StandardError; end
    WRITES = %w[IDENTITY_INITIALIZE IDENTITY_PREPARE IDENTITY_GRANT IDENTITY_BIND IDENTITY_COMPLETE].freeze
    def initialize(actor:, token:, envelope:, authorizer:, bootstrap_projection: nil)
      @actor, @token, @envelope, @authorizer = actor, token, envelope, authorizer
      @bootstrap_projection = bootstrap_projection
      @kind = envelope.fetch('operation')
      @proof = envelope.fetch('input').slice('configured_runtime_sha256', 'configured_privacy_sha256')
      @input = envelope.fetch('input').except(*@proof.keys)
    end

    def call
      WasalxAdminOperation.transaction(requires_new: true) do
      Transaction.execute do
        Setting.connection.execute('SELECT pg_advisory_xact_lock(742831650)')
        @actor = @authorizer.call
        @actor.permissions!('admin.group')
        tokens!
        @record = ServiceIdentity.receipt
        ServiceIdentity.verify_machine!(@record, secrets: @secrets) if @record
        @installed = InstalledPackage.verify!
        if @kind == 'IDENTITY_STATUS'
          keys!(%w[teams_after])
          status
        elsif @kind == 'IDENTITY_RECEIPT'
          reconcile
        else
          mutate
        end
      end
      end
    rescue ActiveRecord::ActiveRecordError
      raise StorageError, 'Service access storage is unavailable', cause: nil
    end

    private

    def keys!(allowed)
      raise ArgumentError unless (@input.keys - allowed).empty?
    end
    def uuid!(value)
      raise ArgumentError unless value.is_a?(String) && PortalDelegation::UUID.match?(value)
      value.downcase
    end
    def id!(value)
      raise ArgumentError unless value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,15}\z/)
      value.to_i
    end
    def version(value)
      OpenSSL::HMAC.hexdigest('SHA256', ENV.fetch('WASALX_SERVICE_JWT_SECRET'), JSON.generate(ServiceIdentity.canonical(value)))
    end
    def tokens!
      raise Exceptions::Forbidden unless @proof.keys.sort == %w[configured_privacy_sha256 configured_runtime_sha256] &&
        @proof.values.all? { |value| value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/) }
      current = Token.lock.find(@token.id)
      ServiceIdentity.authorize!(current.user, current)
      raise Exceptions::Forbidden unless Digest::SHA256.hexdigest(current.token) == @proof.fetch('configured_runtime_sha256')
      privacy = Token.where(action: 'api', name: 'WasalX Privacy', persistent: true).lock.to_a.select do |token|
        Digest::SHA256.hexdigest(token.token) == @proof.fetch('configured_privacy_sha256')
      end
      raise Exceptions::Forbidden unless privacy.one?
      unless ServiceIdentity.receipt
        raise Exceptions::Forbidden unless privacy.first.user_id == current.user_id &&
          Array(current.preferences.to_h.with_indifferent_access[:permission]).sort == ServiceIdentity::LEGACY_SCOPES['runtime'].sort &&
          Array(privacy.first.preferences.to_h.with_indifferent_access[:permission]).sort == ServiceIdentity::LEGACY_SCOPES['privacy'].sort && !privacy.first.expired?
      end
      @tokens = { 'runtime' => current, 'privacy' => privacy.first }
      @secrets = @tokens.transform_values(&:token)
    end
    def machine
      @record && User.lock.find(@record.fetch('automation_native_user_id'))
    end
    def binding
      { 'record' => @record && ServiceIdentity.digest(@record), 'installed' => @installed,
        'actor_id' => @actor.id, 'actor_revision' => @envelope.fetch('actor').fetch('revision'),
        'token_ids' => @tokens.transform_values(&:id), 'proof' => @proof,
        'groups' => machine && ServiceIdentity.group_digest(machine) }
    end
    def grant_version(group)
      target = machine
      version([@record && @record['automation_native_user_id'], group.id, group.name, group.active,
        target && target.role_ids.sort, target && UserGroup.where(user_id: target.id).order(:group_id, :access).pluck(:group_id, :access),
        target && RoleGroup.where(role_id: target.role_ids).order(:role_id, :group_id, :access).pluck(:role_id, :group_id, :access)])
    end
    def retired?
      return false unless @record && @record['schema_version'] == 1 && @record['phase'] == 'BOUND'
      result = Client.post('/internal/v1/zammad/membership/retired', { subject: @record.fetch('legacy_subject') }, scope: 'zammad:membership')
      result.is_a?(Hash) && result['retired'] == true
    end
    def status
      target = machine
      ready = false
      begin
        ready = @record && %w[BOUND COMPLETE].include?(@record['phase']) && !!ServiceIdentity.owner!(@record)
      rescue ServiceIdentity::Conflict
        # Seed ownership is not projected/current portal admission.
      end
      legacy = @record && @record['schema_version'] == 1 ? User.find(@record.fetch('legacy_native_user_id')) : @tokens.fetch('runtime').user
      can_prepare = !@record && legacy.id != @actor.id && legacy.active &&
        Authorization.where(user_id: legacy.id, provider: 'openid_connect').count == 1
      scope = Group.reorder(id: :asc)
      scope = scope.where('id > ?', id!(@input['teams_after'])) if @input['teams_after']
      groups = scope.limit(101).to_a
      retirement = retired?
      { mode: @record && %w[FRESH OWNER_CONVERSION].include?(@record['origin']) ? 'FRESH' : 'LEGACY', phase: @record ? @record['phase'] : 'UNCONFIGURED',
        portal_ready: ready == true, status_version: version(binding), operation_id: @record && @record['operation_id'],
        legacy_member: @record && %w[FRESH OWNER_CONVERSION].include?(@record['origin']) ? nil : { name: legacy.fullname, email: legacy.email.to_s },
        can_initialize: !@record && legacy.id == @actor.id && @envelope['actor']['native_user_id'].nil?,
        access_required: @envelope['actor']['native_user_id'].nil?, owner_projection: projection_proof,
        can_prepare: can_prepare == true, can_bind: !!(@record && @record['phase'] == 'PREPARED'),
        can_complete: retirement == true, legacy_retirement_ready: retirement == true,
        groups: groups.first(100).map { |group| { id: group.id.to_s, name: group.name, active: group.active,
          enabled: !!(target && UserGroup.where(user_id: target.id, group_id: group.id).pluck(:access) == ['full']), version: grant_version(group) } },
        groups_next_cursor: groups.length > 100 ? groups[99].id.to_s : nil }
    end
    def receipt!(request_id, kind, team_id)
      row = WasalxAdminOperation.find_by(operation_id: request_id)
      return unless row
      raise Conflict unless row.portal_user_id == @envelope['actor']['user_id'] && row.native_user_id == @actor.id && row.kind == kind && row.target_id == team_id
      row
    end
    def record!(request_id, kind, team_id, digest, result)
      WasalxAdminOperation.create!(operation_id: request_id, portal_user_id: @envelope['actor']['user_id'], native_user_id: @actor.id,
        kind: kind, target_id: team_id, request_sha256: digest, result: result)
    end
    def reconcile
      keys!(%w[request_id kind team_id action])
      request_id = uuid!(@input['request_id']); kind = @input['kind']
      raise ArgumentError unless WRITES.include?(kind) && %w[LOOKUP CANCEL_IF_UNADMITTED].include?(@input['action'])
      team_id = kind == 'IDENTITY_GRANT' ? id!(@input['team_id']).to_s : nil
      raise ArgumentError if kind != 'IDENTITY_GRANT' && @input['team_id']
      if (row = receipt!(request_id, kind, team_id))
        next_result = row.result.slice('state', 'terminal', 'owner_projection')
      elsif @input['action'] == 'CANCEL_IF_UNADMITTED'
        next_result = { state: 'NOT_APPLIED', terminal: true }
        record!(request_id, kind, team_id, ServiceIdentity.digest(['cancel', request_id, kind, team_id]), next_result)
      else
        next_result = { state: 'UNKNOWN', terminal: false }
      end
      next_result
    end
    def mutate
      raise ArgumentError unless WRITES.include?(@kind)
      grant = @kind == 'IDENTITY_GRANT'
      initialize_owner = @kind == 'IDENTITY_INITIALIZE'
      keys!(initialize_owner ? %w[request_id expected_status_version] : grant ? %w[request_id team_id expected_version enabled] : %w[request_id operation_id expected_status_version retire_legacy])
      request_id = uuid!(@input['request_id'])
      team_id = grant ? id!(@input['team_id']).to_s : nil
      digest = ServiceIdentity.digest([@kind, @input])
      if (row = receipt!(request_id, @kind, team_id))
        raise Conflict unless row.request_sha256 == digest && row.result['state'] == 'APPLIED'
        return row.result
      end
      if grant
        grant!
      else
        raise Conflict unless @input['expected_status_version'] == version(binding)
        initialize_owner ? initialize_owner! : transition!
      end
      result = { state: 'APPLIED', terminal: true }
      result[:owner_projection] = projection_proof if initialize_owner
      record!(request_id, @kind, team_id, digest, result)
      result
    end
    def projection_proof
      return unless @record && @record['origin'] == 'OWNER_CONVERSION'
      row = WasalxMembership.find_by(portal_user_id: @envelope['actor']['user_id'], user_id: @record['human_native_user_id'],
        tenant_id: @envelope['tenant_id'], instance_id: @envelope['instance_id'], subject: @envelope['actor']['subject'])
      return unless row && row.portal_role == 'tenant_owner' && row.member_state == 'ACTIVE'
      { portal_user_id: row.portal_user_id, native_user_id: row.user_id.to_s, revision: row.revision,
        subject_sha256: Digest::SHA256.hexdigest(row.subject), email_sha256: Digest::SHA256.hexdigest(row.email),
        identity_receipt_sha256: ServiceIdentity.digest(@record) }
    end
    def initialize_owner!
      projection = @bootstrap_projection.respond_to?(:call) ? @bootstrap_projection.call : @bootstrap_projection
      raise Conflict unless !@record && @tokens['runtime'].user_id == @actor.id && projection.is_a?(Hash)
      @record = ServiceIdentity.provision_fresh!(owner: @actor, subject: @envelope['actor']['subject'],
        email: @envelope['actor']['email'], secrets: @secrets, origin: 'OWNER_CONVERSION')
      result = MembershipProjection.call(projection, service_user: machine)
      raise Conflict unless result[:state] == 'READY' && result[:native_user_id] == @actor.id.to_s &&
        result[:revision] == @envelope['actor']['revision']
    end
    def grant!
      @actor.permissions!('admin.user')
      raise Conflict unless @record && [true, false].include?(@input['enabled'])
      group = Group.lock.find(id!(@input['team_id']))
      target = machine
      raise Conflict unless @input['expected_version'] == grant_version(group)
      raise Exceptions::Forbidden unless ServiceIdentity.machine_valid?(target, @record)
      map = UserGroup.where(user_id: target.id).order(:group_id, :access).pluck(:group_id, :access).each_with_object({}) do |(id, access), saved|
        (saved[id.to_s] ||= []) << access
      end
      @input['enabled'] ? map[group.id.to_s] = ['full'] : map.delete(group.id.to_s)
      assignments = { 'group_ids' => map }
      Service::User::FilterPermissionAssignments.with_current_user(@actor).execute(user_data: assignments)
      raise Exceptions::Forbidden unless assignments['group_ids'] == map
      target.group_ids_access_map = map
      target.updated_by_id = @actor.id
      target.save!
    end
    def transition!
      action = @kind.delete_prefix('IDENTITY_')
      raise Conflict if @record && %w[FRESH OWNER_CONVERSION].include?(@record['origin'])
      operation = uuid!(@input['operation_id'])
      legacy = @record ? User.lock.find(@record.fetch('legacy_native_user_id')) : @tokens.fetch('runtime').user
      authorization = @record ? @record.fetch('legacy_oidc_authorization_id') : Authorization.where(user_id: legacy.id, provider: 'openid_connect').sole.id.to_s
      subject = @record ? @record.fetch('legacy_subject') : Authorization.find(authorization).uid
      row = WasalxMembership.find_by!(user_id: @actor.id, portal_user_id: @envelope['actor']['user_id'])
      input = { 'version' => 1, 'action' => action, 'operation_id' => operation,
        'expected_revision' => @record ? @record.fetch('revision') : 0, 'expected_receipt_sha256' => @record && ServiceIdentity.digest(@record),
        'tenant_id' => @envelope['tenant_id'], 'instance_id' => @envelope['instance_id'],
        'human_portal_user_id' => row.portal_user_id, 'human_native_user_id' => @actor.id.to_s, 'human_subject' => row.subject,
        'human_projection_revision' => row.revision, 'legacy_native_user_id' => legacy.id.to_s,
        'legacy_oidc_authorization_id' => authorization, 'legacy_subject' => subject,
        'runtime_token_id' => @tokens.fetch('runtime').id.to_s, 'privacy_token_id' => @tokens.fetch('privacy').id.to_s,
        'expected_runtime_scopes' => ServiceIdentity::SCOPES['runtime'], 'expected_privacy_scopes' => ServiceIdentity::SCOPES['privacy'],
        'expected_group_grants_sha256' => machine ? ServiceIdentity.group_digest(machine) : ServiceIdentity.digest({}),
        'verification_receipt_sha256' => nil }.merge(@installed.slice('candidate_commit_sha', 'candidate_tree_sha', 'native_package_sha256'))
      if action == 'COMPLETE'
        raise Conflict unless @input['retire_legacy'] == true && retired?
        # Only the receipt-bound predecessor is retired, after current portal removal.
        legacy.update!(active: false, role_ids: legacy.roles.reject { |role| role.name == 'Admin' }.map(&:id), updated_by_id: @actor.id)
        Authorization.where(user_id: legacy.id).find_each(&:destroy!)
        Token.where(user_id: legacy.id).find_each(&:destroy!)
        MembershipProjection.revoke_sessions(legacy)
        ServiceIdentity.verify_retirement!(@record, @actor)
        input['verification_receipt_sha256'] = ServiceIdentity.digest([binding, 'owner-approved-retirement', legacy.id])
      elsif @input.key?('retire_legacy')
        raise ArgumentError
      end
      ServiceIdentity.transition!(input, secrets: @secrets)
    end
  end
end
