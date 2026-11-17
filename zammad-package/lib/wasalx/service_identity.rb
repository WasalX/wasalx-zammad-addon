# SPDX-License-Identifier: AGPL-3.0-only
require 'digest'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'json'

module Wasalx
  # This receipt binds two native API Tokens to one explicitly noninteractive
  # tenant account. Human membership and queue access keep their existing SSOTs.
  module ServiceIdentity
    SETTING = 'wasalx_service_identity'.freeze
    MARKER = 'wasalx_tenant_automation'.freeze
    LOGIN_PREFIX = 'tenant-automation-'.freeze
    SCOPES = { 'runtime' => %w[ticket.agent wasalx_service], 'privacy' => %w[wasalx_privacy] }.freeze
    LEGACY_SCOPES = {
      'runtime' => %w[admin.calendar admin.group admin.package admin.security admin.sla admin.system admin.user ticket.agent],
      'privacy' => %w[admin.data_privacy]
    }.freeze
    class Conflict < StandardError; end

    def self.digest(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def self.canonical(value)
      case value
      when Hash then value.transform_keys(&:to_s).sort.to_h.transform_values { |item| canonical(item) }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def self.receipt
      # Setting.get is cached; authorization and CAS must see the database value.
      row = Setting.find_by(name: SETTING)
      value = row&.state_current&.fetch('value', nil) || row&.state_current&.fetch(:value, nil)
      return nil if value.nil?
      value = canonical(value)
      fresh = value.is_a?(Hash) && value['schema_version'] == 2 && %w[FRESH OWNER_CONVERSION].include?(value['origin']) && value['phase'] == 'BOUND' &&
              %w[human_subject human_email].all? { |key| value[key].is_a?(String) && value[key].present? }
      legacy = value.is_a?(Hash) && value['schema_version'] == 1 && %w[PREPARED BOUND COMPLETE].include?(value['phase'])
      valid = (fresh || legacy) &&
              value['tenant_id'] == ENV.fetch('WASALX_TENANT_ID') && value['instance_id'] == ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID') &&
              value['revision'].is_a?(Integer) && value['revision'].positive? &&
              (%w[automation_native_user_id human_native_user_id runtime_token_id privacy_token_id] + (fresh ? [] : ['legacy_native_user_id'])).all? { |key| value[key].to_s.match?(/\A[1-9][0-9]{0,15}\z/) } &&
              value['automation_native_user_id'] != value['human_native_user_id'] &&
              value['runtime_token_id'] != value['privacy_token_id'] && value['automation_login'] == login &&
              value['runtime_scope_names'] == SCOPES['runtime'] && value['privacy_scope_names'] == SCOPES['privacy']
      raise Conflict, 'Service identity receipt is invalid' unless valid
      value
    end

    def self.login
      "#{LOGIN_PREFIX}#{Digest::SHA256.hexdigest("#{ENV.fetch('WASALX_TENANT_ID')}:#{ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID')}")[0, 32]}"
    end

    def self.automation?(user)
      return false unless user
      # Independent identity evidence survives a missing/malformed Setting. The
      # native UI cannot turn a prepared machine account into a human by renaming it.
      current = user.persisted? ? User.find_by(id: user.id) : user
      return false unless current
      current.login.to_s.start_with?(LOGIN_PREFIX) || current.preferences.to_h.with_indifferent_access[MARKER].present? ||
        current.permissions.pluck(:name).any? { |name| %w[wasalx_service wasalx_privacy].include?(name) } ||
        begin
          record = receipt
          record && record['automation_native_user_id'].to_s == current.id.to_s
        rescue Conflict
          # A corrupt receipt cannot confer interactive access to a machine role.
          current.permissions.pluck(:name).any? { |name| %w[wasalx_service wasalx_privacy].include?(name) }
        end
    end

    def self.handover_evidence?
      # Never silently return to the bootstrap password/token repair branch after
      # a lost receipt. These independent markers are not an alternative authority.
      Setting.find_by(name: SETTING)&.state_current.to_h.values.any? { |value| !value.nil? } ||
        User.where('login LIKE ?', "#{LOGIN_PREFIX}%").exists? ||
        User.joins(roles: :permissions).where(permissions: { name: %w[wasalx_service wasalx_privacy] }).exists? ||
        Token.where(action: 'api', name: ['WasalX Service', 'WasalX Privacy']).any? { |token| automation?(token.user) }
    end

    def self.legacy_bootstrap_allowed!
      raise Conflict, 'Service identity requires verified reconciliation' if handover_evidence?
      true
    end

    def self.machine_valid?(user, record)
      current = User.find_by(id: record.fetch('automation_native_user_id'))
      return false unless current && current.id == user.id && current.active && current.login == record.fetch('automation_login')
      marker = current.preferences.to_h.with_indifferent_access[MARKER]
      return false unless marker == { 'tenant_id' => record['tenant_id'], 'instance_id' => record['instance_id'] }
      names = current.permissions.pluck(:name)
      return false unless SCOPES.values.flatten.uniq.all? { |name| names.include?(name) }
      return false if names.any? { |name| name == 'admin' || name.start_with?('admin.') }
      return false if current.roles.any? { |role| role.name == 'Admin' } || Authorization.exists?(user_id: current.id)
      return false if current.password.present? || current.two_factor_preferences.exists?
      true
    end

    def self.token_allowed?(user, token, purpose)
      return false unless token && SCOPES.key?(purpose)
      record = receipt
      return false unless record && %w[BOUND COMPLETE].include?(record['phase']) && machine_valid?(user, record)
      current = Token.find_by(id: token.id)
      current && current.id.to_s == record.fetch("#{purpose}_token_id").to_s && current.user_id == user.id &&
        current.action == 'api' && current.persistent && !current.expired? &&
        Array(current.preferences.to_h.with_indifferent_access[:permission]).sort == SCOPES.fetch(purpose).sort
    rescue Conflict, KeyError
      false
    end

    def self.authorize!(user, token, purpose = 'runtime')
      record = receipt
      if record && record['phase'] == 'PREPARED'
        current = token && Token.find_by(id: token.id)
        valid = current && current.id.to_s == record.fetch("#{purpose}_token_id").to_s &&
                current.user_id.to_s == record['legacy_native_user_id'].to_s && current.user_id == user.id &&
                current.action == 'api' && current.persistent && !current.expired? &&
                Array(current.preferences.to_h.with_indifferent_access[:permission]).sort == LEGACY_SCOPES.fetch(purpose).sort
        raise Exceptions::Forbidden, 'Not authorized' unless valid
      elsif record
        raise Exceptions::Forbidden, 'Not authorized' unless token_allowed?(user, token, purpose)
      else
        raise Exceptions::Forbidden, 'Not authorized' if handover_evidence?
        # Default-off compatibility for untouched tenants. Exact token identity is
        # enforced from PREPARED; a native Admin alone never gains machine access.
        permission = purpose == 'runtime' ? 'admin.system' : 'admin.data_privacy'
        expected_name = purpose == 'runtime' ? 'WasalX Service' : 'WasalX Privacy'
        current = token && Token.find_by(id: token.id)
        valid = current && current.user_id == user.id && current.action == 'api' && current.persistent && !current.expired? &&
                current.name == expected_name && user.permissions?(permission)
        raise Exceptions::Forbidden, 'Not authorized' unless valid
      end
      true
    rescue Conflict
      raise Exceptions::Forbidden, 'Not authorized'
    end

    def self.native_owner!(record, exact_revision: false)
      row = %w[FRESH OWNER_CONVERSION].include?(record['origin']) ? WasalxMembership.find_by(user_id: record.fetch('human_native_user_id'), subject: record.fetch('human_subject')) : WasalxMembership.find_by(portal_user_id: record.fetch('human_portal_user_id'))
      user = row && User.find_by(id: row.user_id)
      valid = row && user && row.tenant_id == record.fetch('tenant_id') && row.instance_id == record.fetch('instance_id') &&
              row.user_id.to_s == record.fetch('human_native_user_id').to_s && row.subject == record.fetch('human_subject') &&
              row.portal_role == 'tenant_owner' && row.member_state == 'ACTIVE' &&
              (!exact_revision || row.revision == record.fetch('human_projection_revision_at_admission')) &&
              (!%w[FRESH OWNER_CONVERSION].include?(record['origin']) || row.email == record.fetch('human_email')) &&
              Authorization.where(user_id: user.id, provider: 'openid_connect', uid: row.subject).count == 1 &&
              MembershipProjection.native_access_matches?(user, 'tenant_owner', 'ACTIVE')
      raise Conflict, 'Current tenant owner is not verified' unless valid
      user
    end

    def self.owner!(record, exact_revision: false)
      user = native_owner!(record, exact_revision: exact_revision)
      raise Conflict, 'Current tenant owner is not verified' unless MembershipAccess.allowed?(user)
      user
    end

    def self.group_digest(user)
      digest(user.group_ids_access_map.transform_keys(&:to_s).transform_values { |value| Array(value).map(&:to_s).sort })
    end

    def self.verify_tokens!(record, secrets:)
      bound = record['phase'] != 'PREPARED'
      owner_id = record.fetch(bound ? 'automation_native_user_id' : 'legacy_native_user_id').to_i
      raise Conflict, 'Machine credentials must be distinct' if secrets.fetch('runtime') == secrets.fetch('privacy')
      SCOPES.each_key do |purpose|
        token = Token.lock.find_by(id: record.fetch("#{purpose}_token_id"))
        scopes = bound ? SCOPES.fetch(purpose) : LEGACY_SCOPES.fetch(purpose)
        valid = token && token.user_id == owner_id && token.action == 'api' && token.persistent && !token.expired? &&
                token.name == (purpose == 'runtime' ? 'WasalX Service' : 'WasalX Privacy') &&
                Array(token.preferences.to_h.with_indifferent_access[:permission]).sort == scopes.sort &&
                secrets.fetch(purpose).bytesize >= 16 && ActiveSupport::SecurityUtils.secure_compare(token.token, secrets.fetch(purpose))
        raise Conflict, 'Machine credential identity or scope changed' unless valid
      end
    end

    # Invoked only by the existing governed native bootstrap job with a reviewed
    # nonsecret input file. The receipt and both Token changes share one DB commit.
    def self.transition!(input, secrets:)
      input = canonical(input)
      raise Conflict, 'Unsupported service identity action' unless input.is_a?(Hash) && input['version'] == 1 && %w[PREPARE BIND COMPLETE RECONCILE].include?(input['action'])
      expected_keys = %w[version action operation_id expected_revision expected_receipt_sha256 tenant_id instance_id human_portal_user_id human_native_user_id human_subject human_projection_revision legacy_native_user_id legacy_oidc_authorization_id legacy_subject runtime_token_id privacy_token_id expected_runtime_scopes expected_privacy_scopes expected_group_grants_sha256 candidate_commit_sha candidate_tree_sha native_package_sha256 verification_receipt_sha256]
      raise Conflict, 'Unexpected service identity input' unless input.keys.sort == expected_keys.sort
      raise Conflict, 'Foreign service identity input' unless input['tenant_id'] == ENV.fetch('WASALX_TENANT_ID') && input['instance_id'] == ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID')
      raise Conflict, 'Unsupported machine scopes' unless input['expected_runtime_scopes'] == SCOPES['runtime'] && input['expected_privacy_scopes'] == SCOPES['privacy']
      raise Conflict, 'Invalid service identity operation' unless input['operation_id'].to_s.match?(MembershipProjection::UUID)
      raise Conflict, 'Invalid service identity revision' unless input['expected_revision'].is_a?(Integer) && input['expected_revision'] >= 0 && input['human_projection_revision'].is_a?(Integer) && input['human_projection_revision'].positive?
      %w[human_native_user_id legacy_native_user_id legacy_oidc_authorization_id runtime_token_id privacy_token_id].each do |key|
        raise Conflict, 'Invalid service identity identifier' unless input[key].is_a?(String) && input[key].match?(MembershipProjection::ID)
      end
      %w[candidate_commit_sha candidate_tree_sha].each { |key| raise Conflict, 'Invalid source identity' unless input[key].to_s.match?(/\A[0-9a-f]{40}\z/) }
      %w[native_package_sha256 expected_group_grants_sha256].each { |key| raise Conflict, 'Invalid artifact identity' unless input[key].to_s.match?(/\A[0-9a-f]{64}\z/) }
      raise Conflict, 'Identities must be distinct' unless [input['human_native_user_id'], input['legacy_native_user_id']].uniq.length == 2 && input['runtime_token_id'] != input['privacy_token_id']
      installed = InstalledPackage.verify!
      %w[candidate_commit_sha candidate_tree_sha native_package_sha256].each do |key|
        raise Conflict, 'Installed source does not match handover input' unless installed.fetch(key) == input.fetch(key)
      end
      request_sha = digest(input)
      Setting.transaction do
        Setting.connection.execute('SELECT pg_advisory_xact_lock(742831650)')
        setting = Setting.lock.find_by!(name: SETTING)
        record = receipt
        raise Conflict, 'Fresh identities do not have a legacy transition' if record && %w[FRESH OWNER_CONVERSION].include?(record['origin'])
        if record && record['request_sha256'] == request_sha
          verify_current!(record, secrets: secrets)
          next record # Readback after a lost response; no mutation replay.
        end
        if record
          raise Conflict, 'Service identity changed' unless record['revision'] == input['expected_revision'] && digest(record) == input['expected_receipt_sha256'] && record['operation_id'] == input['operation_id']
          immutable = %w[tenant_id instance_id human_portal_user_id human_native_user_id human_subject legacy_native_user_id legacy_oidc_authorization_id legacy_subject runtime_token_id privacy_token_id]
          raise Conflict, 'Service identity is immutable' unless immutable.all? { |key| record[key] == input[key] }
        else
          legacy_bootstrap_allowed!
          raise Conflict, 'Initial handover must prepare' unless input['action'] == 'PREPARE' && input['expected_revision'].zero? && input['expected_receipt_sha256'].nil?
          record = input.slice('operation_id', 'tenant_id', 'instance_id', 'human_portal_user_id', 'human_native_user_id', 'human_subject', 'legacy_native_user_id', 'legacy_oidc_authorization_id', 'legacy_subject', 'runtime_token_id', 'privacy_token_id')
          record.merge!('schema_version' => 1, 'revision' => 0, 'phase' => 'PREPARED', 'human_projection_revision_at_admission' => input['human_projection_revision'], 'automation_login' => login, 'runtime_scope_names' => SCOPES['runtime'], 'privacy_scope_names' => SCOPES['privacy'])
        end
        if %w[PREPARE BIND].include?(input['action']) && input['human_projection_revision'] != record['human_projection_revision_at_admission']
          raise Conflict, 'Prepared owner revision changed'
        end
        owner = owner!(record.merge('human_projection_revision_at_admission' => input['human_projection_revision']), exact_revision: true)
        User.where(id: [owner.id, record['legacy_native_user_id'], record['automation_native_user_id']].compact).order(:id).lock.load
        Token.where(id: [record['runtime_token_id'], record['privacy_token_id']]).order(:id).lock.load
        verify_tokens!(record, secrets: secrets)
        case input['action']
        when 'PREPARE'
          raise Conflict, 'Already prepared' unless record['revision'].zero?
          legacy = Authorization.find_by(id: record['legacy_oidc_authorization_id'], user_id: record['legacy_native_user_id'], provider: 'openid_connect', uid: record['legacy_subject'])
          raise Conflict, 'Legacy identity changed' unless legacy && legacy.user.active
          machine = create_machine!(owner)
          record['automation_native_user_id'] = machine.id.to_s
          record['prepared_at'] = Time.current.iso8601
        when 'BIND'
          raise Conflict, 'Only prepared credentials can bind' unless record['phase'] == 'PREPARED'
          machine = User.find(record['automation_native_user_id'])
          raise Conflict, 'Automation identity changed' unless machine_valid?(machine, record)
          raise Conflict, 'Approved queue grants changed' unless group_digest(machine) == input['expected_group_grants_sha256']
          SCOPES.each do |purpose, scopes|
            Token.find(record.fetch("#{purpose}_token_id")).update!(user_id: machine.id, preferences: { permission: scopes })
          end
          record['phase'] = 'BOUND'
          record['bound_at'] = Time.current.iso8601
        when 'COMPLETE'
          raise Conflict, 'Completion requires bound credentials and proof' unless record['phase'] == 'BOUND' && input['verification_receipt_sha256'].to_s.match?(/\A[0-9a-f]{64}\z/)
          verify_retirement!(record, owner)
          record['phase'] = 'COMPLETE'
          record['completed_at'] = Time.current.iso8601
        when 'RECONCILE'
          raise Conflict, 'Prepared credentials require reviewed binding' unless %w[BOUND COMPLETE].include?(record['phase'])
        end
        machine = User.find(record.fetch('automation_native_user_id'))
        raise Conflict, 'Automation identity changed' unless machine_valid?(machine, record)
        record.merge!(installed.slice('candidate_commit_sha', 'candidate_tree_sha', 'native_package_sha256'))
        record.merge!('revision' => record['revision'] + 1, 'request_sha256' => request_sha, 'prior_receipt_sha256' => input['expected_receipt_sha256'], 'expected_group_grants_sha256' => input['expected_group_grants_sha256'], 'verification_receipt_sha256' => input['verification_receipt_sha256'])
        setting.update!(state_current: { value: record })
        verify_current!(record, secrets: secrets)
        record
      end
    end

    def self.create_machine!(owner)
      agent = Role.find_by!(name: 'Agent', active: true)
      roles = SCOPES.values.flatten.uniq.grep(/\Awasalx_/).map do |permission|
        role = Role.find_or_initialize_by(name: "Tenant automation: #{permission == 'wasalx_service' ? 'runtime' : 'privacy'}")
        raise Conflict, 'Machine role already has unexpected permissions' if role.persisted? && role.permissions.pluck(:name) != [permission]
        role.assign_attributes(active: true, default_at_signup: false, note: 'Noninteractive tenant integration only', updated_by_id: owner.id, created_by_id: role.created_by_id || owner.id)
        role.save!
        role.permissions = [Permission.find_by!(name: permission, active: true)]
        raise Conflict, 'Machine role has inherited queue access' unless role.group_ids_access_map.empty?
        role
      end
      raise Conflict, 'Native Agent role inherits queue access' unless agent.group_ids_access_map.empty?
      machine = User.create!(login: login, email: '', firstname: 'Tenant', lastname: 'Automation', active: true, verified: true,
        preferences: { MARKER => { 'tenant_id' => ENV.fetch('WASALX_TENANT_ID'), 'instance_id' => ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID') } },
        created_by_id: owner.id, updated_by_id: owner.id, role_ids: ([agent] + roles).map(&:id))
      machine
    end

    # Fresh provisioning has no predecessor. Existing tenants keep their legacy transition.
    def self.provision_fresh!(owner:, subject:, email:, secrets:, origin: 'FRESH')
      raise Conflict, 'Unsupported initial binding' unless %w[FRESH OWNER_CONVERSION].include?(origin)
      installed = InstalledPackage.verify!
      Setting.transaction do
        Setting.connection.execute('SELECT pg_advisory_xact_lock(742831650)')
        setting = Setting.lock.find_by!(name: SETTING)
        legacy_bootstrap_allowed!
        raise Conflict, 'Fresh owner identity changed' unless owner.active && owner.email == email &&
          owner.permissions?('admin') && owner.permissions?('ticket.agent') &&
          Authorization.where(user_id: owner.id, provider: 'openid_connect', uid: subject).count == 1 &&
          !WasalxMembership.exists?(user_id: owner.id)
        tokens = SCOPES.keys.to_h do |purpose|
          name = purpose == 'runtime' ? 'WasalX Service' : 'WasalX Privacy'
          rows = Token.lock.where(user_id: owner.id, action: 'api', persistent: true, name: name).to_a
          raise Conflict, 'Fresh credentials are ambiguous' unless rows.one?
          [purpose, rows.first]
        end
        legacy = { 'phase' => 'PREPARED', 'legacy_native_user_id' => owner.id.to_s }
        tokens.each { |purpose, token| legacy["#{purpose}_token_id"] = token.id.to_s }
        verify_tokens!(legacy, secrets: secrets)
        machine = create_machine!(owner)
        tokens.each { |purpose, token| token.update!(user_id: machine.id, preferences: { permission: SCOPES.fetch(purpose) }) }
        record = { 'schema_version' => 2, 'origin' => origin, 'phase' => 'BOUND', 'revision' => 1,
          'tenant_id' => ENV.fetch('WASALX_TENANT_ID'), 'instance_id' => ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'),
          'human_native_user_id' => owner.id.to_s, 'human_subject' => subject, 'human_email' => email,
          'automation_native_user_id' => machine.id.to_s, 'automation_login' => login,
          'runtime_token_id' => tokens.fetch('runtime').id.to_s, 'privacy_token_id' => tokens.fetch('privacy').id.to_s,
          'runtime_scope_names' => SCOPES['runtime'], 'privacy_scope_names' => SCOPES['privacy'],
          'expected_group_grants_sha256' => group_digest(machine), 'bound_at' => Time.current.iso8601 }
        record.merge!(installed.slice('candidate_commit_sha', 'candidate_tree_sha', 'native_package_sha256'))
        setting.update!(state_current: { value: record })
        verify_startup!(receipt, secrets: secrets)
        record
      end
    end

    def self.fresh_owner_for_startup!(record)
      owner = User.find_by(id: record.fetch('human_native_user_id'))
      raise Conflict, 'Fresh owner identity changed' unless owner && owner.active && owner.email == record.fetch('human_email') &&
        Authorization.where(user_id: owner.id, provider: 'openid_connect', uid: record.fetch('human_subject')).count == 1 &&
        MembershipProjection.native_access_matches?(owner, 'tenant_owner', 'ACTIVE')
      # Unprojected seed ownership grants no portal access. A present managed row may never fall back.
      native_owner!(record) if WasalxMembership.exists?(user_id: owner.id)
      owner
    end

    def self.verify_current!(record, secrets:)
      owner = owner!(record)
      verify_machine!(record, secrets: secrets)
      verify_retirement!(record, owner) if record['phase'] == 'COMPLETE'
      record
    end

    # Startup is integrity-only: a suspended tenant may need this init job before
    # its fenced resume can become WORKING. No receipt, human or token is changed.
    # Every governed transition still uses verify_current! and live control checks.
    def self.verify_startup!(record, secrets:)
      owner = %w[FRESH OWNER_CONVERSION].include?(record['origin']) ? fresh_owner_for_startup!(record) : native_owner!(record)
      verify_machine!(record, secrets: secrets)
      verify_native_retirement!(record, owner) if record['phase'] == 'COMPLETE'
      record
    end

    def self.verify_machine!(record, secrets:)
      machine = User.find(record.fetch('automation_native_user_id'))
      raise Conflict, 'Automation identity changed' unless machine_valid?(machine, record)
      verify_tokens!(record, secrets: secrets)
    end

    def self.verify_native_retirement!(record, owner)
      old = User.find(record.fetch('legacy_native_user_id'))
      admins = User.where(active: true).joins(roles: :permissions).where(roles: { active: true }, permissions: { active: true })
        .where("permissions.name = 'admin' OR permissions.name LIKE 'admin.%'").distinct.pluck(:id)
      raise Conflict, 'Legacy human retirement is incomplete' if old.active || old.roles.any? { |role| role.name == 'Admin' } ||
        Authorization.exists?(user_id: old.id) || Token.exists?(user_id: old.id) || Session.find_each.any? { |session| session.data&.dig('user_id').to_s == old.id.to_s } ||
        Sessions.list.any? { |_id, data| data.dig(:user, 'id').to_s == old.id.to_s } || admins != [owner.id]
    end

    def self.verify_retirement!(record, owner)
      verify_native_retirement!(record, owner)
      result = Client.post('/internal/v1/zammad/membership/retired', { subject: record.fetch('legacy_subject') }, scope: 'zammad:membership')
      raise Conflict, 'Legacy portal membership is not retired' unless result.is_a?(Hash) && result['retired'] == true
    end

    module PasswordAuthentication
      def can_login?
        !Wasalx::ServiceIdentity.automation?(user) && super
      end
    end

    module Recovery
      def password_reset_new_token(username)
        return nil if Wasalx::ServiceIdentity.automation?(identify(username.to_s.strip))
        super
      end
      def by_reset_token(token)
        user = super
        Wasalx::ServiceIdentity.automation?(user) ? nil : user
      end
      def signup_new_token(user)
        return nil if Wasalx::ServiceIdentity.automation?(user)
        super
      end
    end

    # Model validations cover both old REST and modern GraphQL recovery/enrolment
    # services, including attempts made by another administrator.
    module UserCredentials
      extend ActiveSupport::Concern
      included do
        validate :wasalx_machine_credentials
      end
      def wasalx_machine_credentials
        return unless Wasalx::ServiceIdentity.automation?(self)
        errors.add(:base, 'Automation accounts cannot use interactive credentials') if will_save_change_to_password? && password.present?
        if persisted? && (will_save_change_to_login? || will_save_change_to_email? || will_save_change_to_preferences?)
          before = preferences_in_database.to_h.with_indifferent_access[MARKER]
          after = preferences.to_h.with_indifferent_access[MARKER]
          errors.add(:base, 'Automation identity is immutable') if will_save_change_to_login? || will_save_change_to_email? || before != after
        end
      end
      def auth_two_factor
        raise Exceptions::Forbidden, 'Automation accounts cannot enroll interactive credentials' if Wasalx::ServiceIdentity.automation?(self)
        super
      end
    end

    module HumanCredential
      extend ActiveSupport::Concern
      included do
        validate :wasalx_no_machine_human_credential
      end
      def wasalx_no_machine_human_credential
        return unless Wasalx::ServiceIdentity.automation?(user)
        errors.add(:base, 'Automation accounts cannot enroll interactive credentials')
      end
    end

    module TokenCredential
      extend ActiveSupport::Concern
      included do
        validate :wasalx_no_machine_token_enrollment
      end
      def wasalx_no_machine_token_enrollment
        return unless Wasalx::ServiceIdentity.automation?(user)
        errors.add(:base, 'Automation credentials require governed transfer') if new_record? || action != 'api'
      end
    end
  end
end
