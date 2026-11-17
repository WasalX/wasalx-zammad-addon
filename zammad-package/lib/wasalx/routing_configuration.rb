# SPDX-License-Identifier: AGPL-3.0-only
require 'digest'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'json'

module Wasalx
  class RoutingConfiguration
    class InvalidRequest < StandardError; end
    MAX_REVISION = 9_007_199_254_740_991
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    ID = /\A[1-9][0-9]{0,15}\z/
    SHA = /\A[0-9a-f]{64}\z/
    TRIGGER_FIELDS = %w[name active activator execution_condition_mode disable_notification condition perform].freeze

    def self.canonical(value)
      case value
      when Hash then value.sort.to_h.transform_values { |item| canonical(item) }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def self.canonical_manifest(value)
      canonical(value.merge(
        'group_references' => value.fetch('group_references').map { |item| item.merge('owner_ids' => item.fetch('owner_ids').sort) }.sort_by { |item| item.fetch('group_id') },
        'assignments' => value.fetch('assignments').sort_by { |item| [item.fetch('source_kind'), item.fetch('source_id'), item.fetch('key')] },
        'department_defaults' => value.fetch('department_defaults').sort_by { |item| item.fetch('key') },
        'client_routing' => value['client_routing'] && value['client_routing'].merge('support_group_ids' => value['client_routing'].fetch('support_group_ids').sort)
      ))
    end

    def self.digest(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def self.keys!(value, keys)
      raise InvalidRequest unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) } && value.keys.sort == keys.sort
    end

    def self.id!(value)
      raise InvalidRequest unless value.is_a?(String) && value.match?(ID) && value.to_i <= MAX_REVISION
    end

    def self.list!(value, maximum)
      raise InvalidRequest unless value.is_a?(Array) && value.length <= maximum
    end

    def self.revision!(value, zero: false)
      raise InvalidRequest unless value.is_a?(Integer) && value >= (zero ? 0 : 1) && value <= MAX_REVISION
    end

    def self.validate_manifest!(value)
      keys!(value, %w[group_references assignments department_defaults client_routing])
      list!(value['group_references'], 10_000)
      references = {}
      value['group_references'].each do |item|
        keys!(item, %w[group_id owner_ids]); id!(item['group_id']); list!(item['owner_ids'], 1000)
        item['owner_ids'].each { |owner_id| id!(owner_id) }
        raise InvalidRequest if references.key?(item['group_id']) || item['owner_ids'].uniq.length != item['owner_ids'].length
        references[item['group_id']] = item['owner_ids']
      end
      list!(value['assignments'], 10_000)
      assignment_keys = []
      value['assignments'].each do |item|
        keys!(item, %w[key source_kind source_id source_revision group_id owner_id])
        kind = item['source_kind']; source = item['source_id']
        valid_source = source.is_a?(String) && source.length <= 140 && case kind
          when 'GROUP_BINDING' then source.match?(UUID) && item['key'] == "group-binding:#{source}"
          when 'BOT_HANDOFF' then source.match?(/\A[0-9a-f-]{36}:[0-9a-f-]{36}:[a-z][a-z0-9_-]{0,63}\z/) && source.split(':').first(2).all? { |id| id.match?(UUID) } && item['key'] == "bot-handoff:#{source}"
          else false
        end
        raise InvalidRequest unless valid_source && item['source_revision'].is_a?(String) && item['source_revision'].match?(/\A[1-9][0-9]{0,15}\z/)
        revision!(item['source_revision'].to_i)
        id!(item['group_id']); id!(item['owner_id']) unless item['owner_id'].nil?
        raise InvalidRequest unless references.key?(item['group_id']) && (item['owner_id'].nil? || references[item['group_id']].include?(item['owner_id']))
        assignment_keys << item['key']
      end
      raise InvalidRequest unless assignment_keys.uniq.length == assignment_keys.length
      list!(value['department_defaults'], 100)
      policy_keys = []; policy_groups = []
      value['department_defaults'].each do |item|
        keys!(item, %w[key group_id owner_id enabled]); id!(item['group_id']); id!(item['owner_id'])
        raise InvalidRequest unless item['key'].is_a?(String) && item['key'].match?(UUID) && [true, false].include?(item['enabled']) && (!item['enabled'] || references[item['group_id']]&.include?(item['owner_id']))
        policy_keys << item['key']; policy_groups << item['group_id']
      end
      raise InvalidRequest unless policy_keys.uniq.length == policy_keys.length && policy_groups.uniq.length == policy_groups.length
      unless value['client_routing'].nil?
        routing = value['client_routing']; keys!(routing, %w[version_id snapshot_sha256 support_group_ids])
        raise InvalidRequest unless routing['version_id'].is_a?(String) && routing['version_id'].match?(UUID) && routing['snapshot_sha256'].is_a?(String) && routing['snapshot_sha256'].match?(SHA)
        list!(routing['support_group_ids'], 100)
        raise InvalidRequest unless routing['support_group_ids'].uniq.length == routing['support_group_ids'].length && routing['support_group_ids'].all? { |id| references.key?(id) }
      end
      canonical_manifest(value)
    end

    def self.call(payload, service_user:)
      keys!(payload, %w[schema_version action tenant_id instance_id revision desired_sha256 expected_native_revision manifest])
      raise InvalidRequest unless payload['schema_version'].is_a?(Integer) && payload['schema_version'] == 1 && %w[CHECK APPLY].include?(payload['action']) && payload['tenant_id'].is_a?(String) && payload['tenant_id'].match?(UUID) && payload['instance_id'].is_a?(String) && payload['instance_id'].match?(UUID) && payload['tenant_id'] == ENV.fetch('WASALX_TENANT_ID') && payload['instance_id'] == ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID')
      revision!(payload['revision']); revision!(payload['expected_native_revision'], zero: true)
      manifest = validate_manifest!(payload['manifest'])
      raise InvalidRequest unless payload['desired_sha256'].is_a?(String) && payload['desired_sha256'].match?(SHA) && digest(manifest) == payload['desired_sha256']
      new(payload, manifest, service_user).execute
    end

    def initialize(payload, manifest, service_user)
      @payload = payload; @manifest = manifest; @service_user = service_user
    end

    def execute
      WasalxRoutingConfiguration.transaction do
        # Also serializes the first apply, before a projection row exists.
        lock = Digest::SHA256.hexdigest("routing:#{@payload['tenant_id']}:#{@payload['instance_id']}")[0, 15].to_i(16)
        WasalxRoutingConfiguration.connection.execute("SELECT pg_advisory_xact_lock(#{lock})")
        row = WasalxRoutingConfiguration.lock.find_by(tenant_id: @payload['tenant_id'], instance_id: @payload['instance_id'])
        current = row && observe(row)
        references = row && @payload['desired_sha256'] == row.desired_sha256 ? current : observe_references(@manifest)
        if current && current[:drift]
          return response(row, 'DRIFT', current) unless !references[:drift] && safe_retirement?(row, current)
          # An explicit newer off-policy is safe to apply, but no old/native
          # drift is certified as the newly applied desired configuration.
          current = current.merge(items: current[:items].reject { |item| item[:state] == 'DRIFT' })
        end
        return response(row, 'DRIFT', references) if references[:drift]
        if row && @payload['revision'] == row.applied_revision
          return conflict(row, 'REVISION_CONFLICT', current) unless @payload['desired_sha256'] == row.desired_sha256
          return response(row, 'SYNCED', current)
        end
        return conflict(row, 'STALE_REVISION', current) if row && @payload['revision'] < row.applied_revision
        if @payload['action'] == 'CHECK'
          return conflict(row, row ? 'REVISION_AHEAD' : 'NOT_APPLIED', current)
        end
        return conflict(row, 'STALE_NATIVE_REVISION', current) unless @payload['expected_native_revision'] == (row&.applied_revision || 0)

        owned = row ? row.owned_triggers.deep_dup : {}
        policies = @manifest['department_defaults'].index_by { |item| item['key'] }
        # Check all display-name collisions before making any native change.
        policies.each do |key, policy|
          next unless policy['enabled']
          if owned[key]&.fetch('retired_missing', false)
            actual = { drift: true, items: [], snapshot: { 'missing_owned_trigger' => owned[key]['native_id'] } }
            return conflict(row, 'TRIGGER_MISSING', actual, state: 'DRIFT')
          end
          next if owned.key?(key)
          collision = Trigger.where('LOWER(name) = ?', trigger_fields(policy)['name'].downcase).first
          if collision
            actual = { drift: true, items: references[:items], snapshot: references[:snapshot].merge('ownership_conflict' => { 'key' => key, 'native_id' => collision.id.to_s }) }
            return conflict(row, 'OWNERSHIP_CONFLICT', actual, state: 'DRIFT')
          end
        end
        (owned.keys | policies.keys).sort.each do |key|
          policy = policies[key]
          receipt = owned[key]
          next if !receipt && !policy['enabled']
          fields = policy && policy['enabled'] ? trigger_fields(policy) : receipt.fetch('fields').merge('active' => false)
          trigger = receipt && Trigger.lock.find_by(id: receipt.fetch('native_id'))
          if receipt && !trigger
            raise InvalidRequest if policy && policy['enabled']
            owned[key] = receipt.merge('retired_missing' => true)
            next
          end
          if trigger
            trigger.update!(fields.merge('updated_by_id' => @service_user.id)) unless self.class.digest(trigger.attributes.slice(*TRIGGER_FIELDS)) == self.class.digest(fields)
          else
            trigger = Trigger.create!(fields.merge('created_by_id' => @service_user.id, 'updated_by_id' => @service_user.id))
          end
          owned[key] = { 'native_id' => trigger.id.to_s, 'fields' => fields, 'sha256' => self.class.digest(fields) }
        end
        row ||= WasalxRoutingConfiguration.new(tenant_id: @payload['tenant_id'], instance_id: @payload['instance_id'])
        row.assign_attributes(applied_revision: @payload['revision'], desired_sha256: @payload['desired_sha256'], manifest: @manifest, owned_triggers: owned)
        row.save!
        actual = observe(row)
        # A native callback changing the compiled contract must roll back the
        # entire apply, not leave a successful receipt for different effects.
        raise InvalidRequest if actual[:drift]
        response(row, 'SYNCED', actual)
      end
    end

    private

    def trigger_fields(policy, manifest = @manifest)
      conditions = {
        'ticket.action' => { 'operator' => 'is', 'value' => 'create' },
        'ticket.group_id' => { 'operator' => 'is', 'value' => [policy.fetch('group_id')] },
        'ticket.owner_id' => { 'operator' => 'is', 'value' => ['1'] }
      }
      # The postmaster callback already captured its assignment fence while
      # PENDING; a queue default must not masquerade as a later human edit.
      if manifest['client_routing']&.fetch('support_group_ids')&.include?(policy['group_id'])
        conditions['ticket.wasalx_client_route_status'] = { 'operator' => 'is not', 'value' => 'PENDING' }
      end
      { 'name' => "WasalX queue default #{policy.fetch('key')}", 'active' => policy.fetch('enabled'),
        'activator' => 'action', 'execution_condition_mode' => 'selective', 'disable_notification' => true,
        'condition' => conditions,
        'perform' => { 'ticket.owner_id' => { 'pre_condition' => 'specific', 'value' => policy.fetch('owner_id'), 'value_completion' => '' } } }
    end

    def observe_references(manifest)
      create_groups = @service_user.reload.group_ids_access('create').map(&:to_s)
      items = []; snapshot = []
      groups = Group.where(id: manifest['group_references'].map { |item| item['group_id'] }).order(:id).lock.index_by { |item| item.id.to_s }
      owner_ids = manifest['group_references'].flat_map { |item| item['owner_ids'] }.uniq
      owners_by_id = User.where(id: owner_ids).order(:id).lock.index_by { |item| item.id.to_s }
      eligible_groups = owners_by_id.transform_values do |owner|
        next [] unless owner.active && owner.id != @service_user.id && owner.permissions?('ticket.agent') && !ServiceIdentity.automation?(owner)
        owner.group_ids_access('full').map(&:to_s)
      end
      manifest.fetch('group_references').each do |reference|
        group = groups[reference.fetch('group_id')]
        code = if !group then 'GROUP_MISSING'
          elsif !group.active then 'GROUP_INACTIVE'
          elsif !create_groups.include?(group.id.to_s) then 'SERVICE_GROUP_ACCESS'
        end
        owners = reference.fetch('owner_ids').map do |id|
          eligible = eligible_groups.fetch(id, []).include?(reference['group_id'])
          code ||= 'OWNER_INELIGIBLE' unless eligible
          { 'id' => id, 'eligible' => !!eligible }
        end
        snapshot << { 'group_id' => reference['group_id'], 'exists' => !!group, 'active' => group&.active == true, 'service_create' => create_groups.include?(reference['group_id']), 'owners' => owners }
        items << { key: "group:#{reference['group_id']}", kind: 'GROUP_REFERENCE', native_id: group&.id&.to_s, state: code ? 'DRIFT' : 'SYNCED', **(code ? { error_code: code } : {}) }
      end
      { drift: items.any? { |item| item[:state] == 'DRIFT' }, items: items, snapshot: { 'references' => snapshot } }
    end

    def observe(row)
      manifest = self.class.validate_manifest!(row.manifest)
      self.class.revision!(row.applied_revision)
      references = observe_references(manifest)
      snapshot = references[:snapshot].merge('manifest' => manifest, 'triggers' => {})
      items = references[:items]
      drift = references[:drift] || self.class.digest(manifest) != row.desired_sha256
      if self.class.digest(manifest) != row.desired_sha256
        items << { key: 'configuration', kind: 'CONFIGURATION', native_id: nil, state: 'DRIFT', error_code: 'PROJECTION_INVALID' }
      end
      policies = manifest['department_defaults'].index_by { |item| item['key'] }
      row.owned_triggers.sort.each do |key, receipt|
        trigger = Trigger.lock.find_by(id: receipt.fetch('native_id'))
        fields = trigger&.attributes&.slice(*TRIGGER_FIELDS)
        expected = policies[key] && policies[key]['enabled'] ? trigger_fields(policies[key], manifest) : receipt.fetch('fields').merge('active' => false)
        intact_receipt = self.class.digest(receipt.fetch('fields')) == receipt.fetch('sha256')
        valid = if receipt['retired_missing']
          intact_receipt && !trigger && !(policies[key] && policies[key]['enabled'])
        else
          fields && intact_receipt && self.class.digest(fields) == receipt['sha256'] && self.class.digest(fields) == self.class.digest(expected)
        end
        snapshot['triggers'][key] = fields
        drift ||= !valid
        items << { key: key, kind: 'DEPARTMENT_DEFAULT', native_id: trigger&.id&.to_s, state: valid ? 'SYNCED' : 'DRIFT', **(valid ? {} : { error_code: trigger ? 'TRIGGER_MODIFIED' : 'TRIGGER_MISSING' }) }
      end
      manifest['department_defaults'].each do |policy|
        next if row.owned_triggers.key?(policy['key'])
        drift ||= policy['enabled']
        items << { key: policy['key'], kind: 'DEPARTMENT_DEFAULT', native_id: nil, state: policy['enabled'] ? 'DRIFT' : 'SYNCED', **(policy['enabled'] ? { error_code: 'TRIGGER_MISSING' } : {}) }
      end
      manifest['assignments'].each { |item| items << { key: item['key'], kind: item['source_kind'], native_id: item['group_id'], state: 'SYNCED' } }
      if manifest['client_routing']
        items << { key: "client-routing:#{manifest['client_routing']['version_id']}", kind: 'CLIENT_ROUTING', native_id: nil, state: 'SYNCED' }
      end
      { drift: drift, items: items, snapshot: snapshot }
    rescue InvalidRequest, KeyError, TypeError
      { drift: true, items: [{ key: 'configuration', kind: 'CONFIGURATION', native_id: nil, state: 'DRIFT', error_code: 'PROJECTION_INVALID' }], snapshot: { 'invalid_projection' => true } }
    end

    def safe_retirement?(row, observation)
      return false unless @payload['revision'] > row.applied_revision
      desired = @manifest['department_defaults'].index_by { |item| item['key'] }
      retiring = row.owned_triggers.keys.reject { |key| desired[key] && desired[key]['enabled'] }
      old_policies = row.manifest['department_defaults'].select { |item| retiring.include?(item['key']) }
      observation[:items].select { |item| item[:state] == 'DRIFT' }.all? do |item|
        case item[:error_code]
        when 'TRIGGER_MISSING' then retiring.include?(item[:key])
        when 'GROUP_MISSING', 'GROUP_INACTIVE', 'SERVICE_GROUP_ACCESS'
          old_policies.any? { |policy| "group:#{policy['group_id']}" == item[:key] }
        when 'OWNER_INELIGIBLE'
          reference = observation[:snapshot]['references'].find { |ref| "group:#{ref['group_id']}" == item[:key] }
          reference && reference['owners'].reject { |owner| owner['eligible'] }.all? do |owner|
            old_policies.any? { |policy| policy['group_id'] == reference['group_id'] && policy['owner_id'] == owner['id'] }
          end
        else false
        end
      end
    end

    def conflict(row, code, observation, state: 'CONFLICT')
      observation ||= { items: [], snapshot: {} }
      response(row, state, observation.merge(items: observation[:items] + [{ key: 'configuration', kind: 'CONFIGURATION', native_id: nil, state: state == 'DRIFT' ? 'DRIFT' : 'UNAPPLIED', error_code: code }]))
    end

    def response(row, state, observation)
      observed = if row && observation && !observation[:drift] then row.desired_sha256
        elsif observation && observation[:snapshot].any? then self.class.digest(observation[:snapshot])
      end
      { schema_version: 1, tenant_id: @payload['tenant_id'], instance_id: @payload['instance_id'], revision: @payload['revision'], desired_sha256: @payload['desired_sha256'],
        applied_revision: row&.applied_revision || 0, observed_sha256: observed, state: state, items: observation ? observation[:items] : [] }
    end
  end
end
