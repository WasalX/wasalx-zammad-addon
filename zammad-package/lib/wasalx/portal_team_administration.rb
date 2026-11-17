# SPDX-License-Identifier: AGPL-3.0-only
require 'digest'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'openssl'

module Wasalx
  class PortalTeamAdministration
    class Conflict < StandardError; end
    ACCESS = %w[read create change overview].freeze
    WRITES = %w[TEAM_CREATE TEAM_SAVE TEAM_GRANT_SAVE].freeze

    def initialize(actor:, envelope:, authorizer:)
      @actor, @envelope = actor, envelope
      @input = envelope.fetch('input')
      @kind = envelope.fetch('operation')
      @authorizer = authorizer
    end

    def call
      authorize!
      case @kind
      when 'TEAM_LIST'
        keys!(%w[before limit])
        limit = @input.fetch('limit', 50)
        raise ArgumentError unless limit.is_a?(Integer) && (1..100).cover?(limit)
        scope = Group.reorder(id: :asc)
        scope = scope.where('id > ?', id!(@input['before'])) if @input['before']
        rows = scope.limit(limit + 1).to_a
        { items: rows.first(limit).map { |group| summary(group) }, next_cursor: rows.length > limit ? rows[limit - 1].id.to_s : nil }
      when 'TEAM_SHOW'
        keys!(%w[team_id members_after])
        detail(Group.find(id!(@input['team_id'])))
      when *WRITES
        mutate
      when 'TEAM_RECEIPT'
        reconcile
      else
        raise ArgumentError
      end
    end

    private

    def authorize!
      fresh = @authorizer.call
      raise Exceptions::Forbidden unless fresh && fresh.id == @actor.id
      @actor = fresh
      @actor.reload.permissions!('admin.group')
    end

    def keys!(allowed)
      raise ArgumentError unless @input.is_a?(Hash) && (@input.keys - allowed).empty?
    end

    def id!(value)
      raise ArgumentError unless value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,15}\z/)
      value.to_i
    end

    def uuid!(value)
      raise ArgumentError unless value.is_a?(String) && PortalDelegation::UUID.match?(value)
      value.downcase
    end

    def text!(value, maximum, blank: false)
      raise ArgumentError unless value.is_a?(String) && value.length <= maximum && (blank || value.strip.present?) && !value.match?(/[[:cntrl:]]/)
      value.strip
    end

    def managed_members
      scope = WasalxMembership.where(tenant_id: @envelope.fetch('tenant_id'), instance_id: @envelope.fetch('instance_id'), member_state: 'ACTIVE').where.not(user_id: nil).order(:portal_user_id)
      scope = scope.where('portal_user_id > ?', uuid!(@input['members_after'])) if @input['members_after']
      rows = scope.limit(101).to_a
      members = rows.first(100).filter_map do |row|
        user = User.find_by(id: row.user_id)
        next unless user&.active && row.portal_role != 'auditor' && !ServiceIdentity.automation?(user)
        next unless MembershipProjection.native_access_matches?(user, row.portal_role, row.member_state)
        [row, user]
      end
      [members, rows.length > 100 ? rows[99].portal_user_id : nil]
    end

    def direct(user, group)
      UserGroup.where(user_id: user.id, group_id: group.id).order(:access).pluck(:access)
    end

    def version(group)
      digest_version([group.id, group.name, group.note, group.active, group.updated_at.utc.iso8601(6)])
    end

    def saved_map(user)
      # Native group_ids_access_map is direct-only, but hides inactive groups; keep their saved grants too.
      UserGroup.where(user_id: user.id).order(:group_id, :access).pluck(:group_id, :access).each_with_object({}) do |(id, access), result|
        (result[id.to_s] ||= []) << access
      end
    end

    def member_version(user, group)
      roles = user.role_ids.sort
      inherited = RoleGroup.where(group_id: group.id, role_id: roles).order(:role_id, :access).pluck(:role_id, :access)
      digest_version([version(group), user.id, user.active, roles, saved_map(user), inherited])
    end

    def digest_version(value)
      OpenSSL::HMAC.hexdigest('SHA256', ENV.fetch('WASALX_SERVICE_JWT_SECRET'), JSON.generate(value))
    end

    def summary(group)
      { id: group.id.to_s, name: group.name, note: group.note.to_s, active: group.active, version: version(group) }
    end

    def detail(group)
      members, next_cursor = managed_members
      summary(group).merge(can_manage: @actor.permissions?('admin.group'), can_grant: @actor.permissions?('admin.user'),
        members_next_cursor: next_cursor, members: members.map do |row, user|
          { id: row.portal_user_id, name: user.fullname, email: user.email, version: member_version(user, group), direct_access: direct(user, group),
            effective_access: ACCESS.select { |access| user.group_ids_access(access).include?(group.id) }, editable: @actor.permissions?('admin.user') }
        end)
    end

    def lock!(operation)
      Group.connection.execute("SELECT pg_advisory_xact_lock(#{Digest::SHA256.hexdigest("portal-admin:#{operation}")[0, 15].to_i(16)})")
    end

    def receipt!(operation, kind, team_id)
      row = WasalxAdminOperation.find_by(operation_id: operation)
      return unless row
      member_id = kind == 'TEAM_GRANT_SAVE' ? uuid!(@input['member_id']) : nil
      raise Conflict unless row.portal_user_id == @envelope['actor']['user_id'] && row.native_user_id == @actor.id &&
        row.kind == kind && row.target_id == team_id && row.result['member_id'] == member_id
      row
    end

    def record!(operation, kind, team_id, digest, result)
      WasalxAdminOperation.create!(operation_id: operation, portal_user_id: @envelope['actor']['user_id'], native_user_id: @actor.id,
        kind: kind, target_id: team_id, request_sha256: digest, result: result)
    end

    def mutate
      allowed = @kind == 'TEAM_CREATE' ? %w[operation_id name note] : @kind == 'TEAM_SAVE' ? %w[operation_id team_id expected_version name note active] : %w[operation_id team_id member_id expected_version access]
      keys!(allowed)
      operation = uuid!(@input['operation_id'])
      team_id = @kind == 'TEAM_CREATE' ? nil : id!(@input['team_id']).to_s
      digest = ServiceIdentity.digest({ operation: @kind, input: @input })
      Transaction.execute do
        lock!(operation)
        authorize!
        if (receipt = receipt!(operation, @kind, team_id))
          raise Conflict unless receipt.request_sha256 == digest && receipt.result['state'] == 'APPLIED'
          next receipt.result
        end
        group = team_id ? Group.lock.find(team_id) : nil
        raise Conflict if group && @kind != 'TEAM_GRANT_SAVE' && @input['expected_version'] != version(group)
        if @kind == 'TEAM_GRANT_SAVE'
          @actor.permissions!('admin.user')
          member_id = uuid!(@input['member_id'])
          row = WasalxMembership.lock.find_by!(portal_user_id: member_id, tenant_id: @envelope['tenant_id'], instance_id: @envelope['instance_id'], member_state: 'ACTIVE')
          user = User.lock.find(row.user_id)
          raise Conflict unless @input['expected_version'] == member_version(user, group)
          raise Exceptions::Forbidden unless user.active && row.portal_role != 'auditor' && !ServiceIdentity.automation?(user) && MembershipProjection.native_access_matches?(user, row.portal_role, row.member_state)
          access = @input['access']
          raise ArgumentError unless access.is_a?(Array) && access.uniq == access && (access == ['full'] || (access - ACCESS).empty?)
          map = saved_map(user)
          access.empty? ? map.delete(group.id.to_s) : map[group.id.to_s] = access
          # Preserve unrelated direct grants and all role-inherited access.
          assignments = { 'group_ids' => map }
          # Native execute mutates user_data and returns nil for admin.user; do not use its return as the map.
          Service::User::FilterPermissionAssignments.with_current_user(@actor).execute(user_data: assignments)
          raise Exceptions::Forbidden unless assignments['group_ids'] == map
          user.group_ids_access_map = map
          user.updated_by_id = @actor.id
          user.save!
        else
          attributes = { name: text!(@input['name'], 160), note: text!(@input.fetch('note', ''), 250, blank: true), updated_by_id: @actor.id }
          if group
            raise ArgumentError unless [true, false].include?(@input['active'])
            attributes[:active] = @input['active']
            group.screen = 'edit'
            group.update!(attributes)
          else
            group = Group.new(attributes.merge(active: true, created_by_id: @actor.id))
            group.screen = 'create'
            group.save!
          end
        end
        result = { state: 'APPLIED', team_id: group.id.to_s }
        result[:member_id] = uuid!(@input['member_id']) if @kind == 'TEAM_GRANT_SAVE'
        record!(operation, @kind, team_id, digest, result)
        result
      end
    end

    def reconcile
      keys!(%w[operation_id kind team_id member_id cancel_if_missing])
      operation = uuid!(@input['operation_id'])
      kind = @input['kind']
      raise ArgumentError unless WRITES.include?(kind) && [true, false].include?(@input.fetch('cancel_if_missing', false))
      team_id = kind == 'TEAM_CREATE' ? nil : id!(@input['team_id']).to_s
      Transaction.execute do
        lock!(operation)
        authorize!
        if (receipt = receipt!(operation, kind, team_id))
          next receipt.result
        end
        next({ state: 'UNKNOWN' }) unless @input['cancel_if_missing']
        @actor.permissions!('admin.user') if kind == 'TEAM_GRANT_SAVE'
        result = { state: 'CANCELLED' }
        result[:member_id] = uuid!(@input['member_id']) if kind == 'TEAM_GRANT_SAVE'
        record!(operation, kind, team_id, nil, result)
        result
      end
    end
  end
end
