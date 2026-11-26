# SPDX-License-Identifier: AGPL-3.0-only
require 'digest'
# Copyright (c) 2026 WasalX

module Wasalx
  class MembershipProjection
    UUID = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i
    ID = /\A[1-9][0-9]{0,15}\z/
    KEYS = %w[action tenant_id instance_id user_id subject email name role state revision native_user_id adopt_user_id].sort.freeze
    ROLES = %w[tenant_owner tenant_admin supervisor agent auditor].freeze

    def self.call(payload, service_user:)
      validate!(payload)
      # Serializes first binding, email adoption, and OIDC authorization creation.
      # The package never modifies native group grants or unrelated accounts.
      WasalxMembership.transaction do
        WasalxMembership.connection.execute("SELECT pg_advisory_xact_lock(742831650)")
        row = WasalxMembership.lock.find_by(portal_user_id: payload.fetch('user_id'))
        next { state: 'CONFLICT' } if row && !same_identity?(row, payload)
        next { state: 'CONFLICT' } if row && payload.fetch('revision') < row.revision

        digest = Digest::SHA256.hexdigest(JSON.generate(payload.except('action', 'native_user_id', 'adopt_user_id')))
        next { state: 'CONFLICT' } if row&.user_id && [payload['native_user_id'], payload['adopt_user_id']].compact.any? { |value| value != row.user_id.to_s }
        if row && payload.fetch('revision') == row.revision
          next { state: 'CONFLICT' } if row.payload_sha256 != digest
          next { state: 'CONFLICT' } if row.user && !native_access_matches?(row.user, row.portal_role, row.member_state)
          revoke_sessions(row.user) if payload['action'] == 'APPLY' && row.user
          next ready(row)
        end
        bound = Authorization.where(provider: 'openid_connect', uid: payload.fetch('subject')).to_a
        next { state: 'CONFLICT' } if bound.length > 1
        user = row&.user || bound.first&.user
        if payload['native_user_id'] && (!user || user.id.to_s != payload['native_user_id'])
          next { state: 'CONFLICT' }
        end
        matches = User.where('lower(email) = ?', payload.fetch('email').downcase).order(:id).limit(21).to_a
        if user
          next { state: 'CONFLICT' } unless user.email.to_s.downcase == payload.fetch('email').downcase
          next { state: 'CONFLICT' } if matches.any? { |match| match.id != user.id }
        elsif payload['adopt_user_id']
          user = matches.find { |match| match.id.to_s == payload['adopt_user_id'] }
          next { state: 'CONFLICT' } unless user && matches.length == 1
        elsif matches.any?
          candidates = matches.reject { |match| match.id == service_user.id }.map do |match|
            { id: match.id.to_s, name: [match.firstname, match.lastname].compact.join(' '), email: match.email, active: match.active }
          end
          next { state: matches.any? { |match| match.id == service_user.id } ? 'PROTECTED' : 'ADOPTION_REQUIRED', candidates: candidates }
        end
        next { state: 'PROTECTED' } if user && user.id == service_user.id
        # Initial adoption may not silently remove independently managed native
        # administration. Later lifecycle changes affect only an already-bound row.
        next { state: 'PROTECTED' } if user && !row && user.roles.any? { |role| role.name == 'Admin' } && !%w[tenant_owner tenant_admin].include?(payload.fetch('role'))
        if user
          next { state: 'CONFLICT' } if WasalxMembership.where(user_id: user.id).where.not(portal_user_id: payload.fetch('user_id')).exists?
          next { state: 'CONFLICT' } if user.authorizations.any? { |auth| auth.provider != 'openid_connect' || auth.uid != payload.fetch('subject') }
        end
        next { state: 'READY', candidates: [] } if payload['action'] == 'DISCOVER'

        row ||= WasalxMembership.new(tenant_id: payload.fetch('tenant_id'), instance_id: payload.fetch('instance_id'), portal_user_id: payload.fetch('user_id'), subject: payload.fetch('subject'), email: payload.fetch('email'), portal_role: payload.fetch('role'))
        # A member removed before first native provisioning needs only a tombstone.
        if !user && payload.fetch('state') == 'ACTIVE' && payload.fetch('role') != 'auditor'
          user = User.new(login: "wasalx-#{payload.fetch('user_id')}", email: payload.fetch('email'), firstname: payload.fetch('name'), lastname: '', active: true, created_by_id: service_user.id, updated_by_id: service_user.id)
        end
        if user
          user.lock! if user.persisted?
          admin = %w[tenant_owner tenant_admin].include?(payload.fetch('role'))
          access = payload.fetch('state') == 'ACTIVE' && payload.fetch('role') != 'auditor'
          managed_roles = Role.where(name: %w[Admin Agent]).to_a
          raise 'Native staff roles are unavailable' if managed_roles.length != 2
          desired = managed_roles.select { |role| access && (role.name == 'Agent' || admin) }
          user.roles = user.roles.reject { |role| %w[Admin Agent].include?(role.name) } | desired
          user.active = access
          user.updated_by_id = service_user.id
          user.save!
          Authorization.find_or_create_by!(provider: 'openid_connect', uid: payload.fetch('subject'), user_id: user.id)
          row.user_id = user.id
        end
        row.assign_attributes(revision: payload.fetch('revision'), payload_sha256: digest, member_state: payload.fetch('state'), portal_role: payload.fetch('role'))
        row.save!
        revoke_sessions(user) if user
        ready(row)
      end
    end

    def self.same_identity?(row, payload)
      row.tenant_id == payload['tenant_id'] && row.instance_id == payload['instance_id'] && row.subject == payload['subject'] && row.email == payload['email']
    end

    def self.ready(row)
      { state: 'READY', native_user_id: row.user_id&.to_s, revision: row.revision }
    end

    def self.native_access_matches?(user, role, state)
      # GraphQL subscriptions retain their admitted User object and associations.
      # Native role edits do not advance the portal revision, so read fresh roles.
      user = User.find_by(id: user.id)
      return false unless user
      access = state == 'ACTIVE' && role != 'auditor'
      expected = access ? (%w[tenant_owner tenant_admin].include?(role) ? %w[Admin Agent] : ['Agent']) : []
      user.active == access && user.roles.select { |value| %w[Admin Agent].include?(value.name) }.map(&:name).sort == expected
    end

    def self.revoke_sessions(user)
      # Session#data uses the pinned native serializer; never inspect raw cookies.
      Session.find_each { |session| session.destroy! if session.data&.fetch('user_id', nil).to_s == user.id.to_s }
      Sessions.list.each { |client_id, data| Sessions.destroy(client_id) if data.dig(:user, 'id').to_s == user.id.to_s }
      # Existing modern sockets are fenced at execute/transmit and close on their
      # next frame; deleting the native session prevents reconnect with that cookie.
    end

    def self.validate!(payload)
      raise ArgumentError unless payload.is_a?(Hash) && payload.keys.sort == KEYS
      raise ArgumentError unless %w[APPLY DISCOVER].include?(payload['action']) && ROLES.include?(payload['role']) && %w[ACTIVE SUSPENDED REMOVED].include?(payload['state'])
      raise ArgumentError unless %w[tenant_id instance_id user_id].all? { |key| payload[key].is_a?(String) && UUID.match?(payload[key]) }
      raise ArgumentError unless payload['tenant_id'] == ENV.fetch('WASALX_TENANT_ID') && payload['instance_id'] == ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID')
      raise ArgumentError unless payload['revision'].is_a?(Integer) && payload['revision'].positive? && payload['revision'] <= 9_007_199_254_740_991
      raise ArgumentError unless %w[native_user_id adopt_user_id].all? { |key| payload[key].nil? || (payload[key].is_a?(String) && ID.match?(payload[key])) }
      raise ArgumentError unless %w[subject email name].all? { |key| payload[key].is_a?(String) && payload[key].length.between?(1, key == 'name' ? 160 : 320) && payload[key] == payload[key].strip && !payload[key].match?(/[[:cntrl:]]/) }
      raise ArgumentError unless payload['email'].match?(/\A[^\s@]+@[^\s@]+\z/) && payload['email'] == payload['email'].downcase
    end
  end
end
