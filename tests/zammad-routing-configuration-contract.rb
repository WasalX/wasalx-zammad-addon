# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 WasalX
require 'openssl'
# Reuse the real exact-token guard and its existing noninteractive fixtures.
load File.expand_path('zammad-service-identity-contract.rb', __dir__)

class Hash
  def deep_dup; Marshal.load(Marshal.dump(self)); end
end
class Array
  def index_by; to_h { |item| [yield(item), item] }; end
end
class NativeRoutingRows < Array
  def order(*); self; end
  def lock; self; end
end
class NativeUser
  attr_accessor :routing_groups
  def reload; User.find(id); end
  def group_ids_access(permission)
    (routing_groups || {}).filter_map { |id, access| id if access.include?(permission) || access.include?('full') }
  end
end
class User
  class << self
    alias_method :service_identity_where, :where
    def where(*args, **kwargs)
      return NativeRoutingRows.new(records.values.select { |row| kwargs[:id].map(&:to_s).include?(row.id.to_s) }) if kwargs.key?(:id)
      service_identity_where(*args, **kwargs)
    end
  end
end
class Group
  class << self
    attr_accessor :records
    def where(id:); NativeRoutingRows.new(records.values.select { |row| id.include?(row.id.to_s) }); end
  end
end
class Trigger
  attr_accessor :id, :attributes
  class << self
    attr_accessor :records, :sequence, :fail_create
    def lock; self; end
    def find_by(id:); records[id.to_i]; end
    def where(_query, name); records.values.select { |row| row.attributes['name'].downcase == name }; end
    def create!(fields)
      raise 'Synthetic native validation failure' if fail_create
      self.sequence += 1
      value = new; value.id = sequence; value.attributes = fields.deep_dup
      records[value.id] = value
      value
    end
  end
  def update!(fields); attributes.merge!(fields); end
end
module ActiveRecord
  class Base
    def self.table_name=(_value); end
  end
end
package_root = ENV.fetch('WASALX_TEST_PACKAGE_ROOT', File.expand_path('../zammad-package', __dir__))
load File.join(package_root, 'app/models/wasalx_routing_configuration.rb')
class WasalxRoutingConfiguration
  attr_accessor :tenant_id, :instance_id, :applied_revision, :desired_sha256, :manifest, :owned_triggers
  class << self
    attr_accessor :records, :writes, :locks
    def lock; self; end
    def connection; self; end
    def execute(sql); locks << sql; end
    def find_by(tenant_id:, instance_id:); records[[tenant_id, instance_id]]; end
    def transaction
      before = Marshal.dump([records, writes, Trigger.records, Trigger.sequence])
      yield
    rescue Exception
      self.records, self.writes, Trigger.records, Trigger.sequence = Marshal.load(before)
      raise
    end
  end
  def initialize(**fields); assign_attributes(**fields); end
  def assign_attributes(**fields); fields.each { |key, value| public_send("#{key}=", value) }; end
  def save!; self.class.records[[tenant_id, instance_id]] = self; self.class.writes += 1; end
end
module ActiveSupport::SecurityUtils
  def self.secure_compare(left, right); OpenSSL.fixed_length_secure_compare(left, right); end
end
class ApplicationController
  def self.prepend_before_action(_name); end
  attr_accessor :request, :current_user, :response
  def render(json:, status: :ok); self.response = [status, json]; end
end
module Api
  module V1; end
end
load File.join(package_root, 'lib/wasalx/routing_configuration.rb')
load File.join(package_root, 'app/controllers/api/v1/wasalx_routing_configurations_controller.rb')

class NativeRoutingConfigurationContract < Minitest::Test
  Config = Wasalx::RoutingConfiguration
  GROUP_BINDING = '10000000-0000-4000-8000-000000000001'
  POLICY = '20000000-0000-4000-8000-000000000002'
  VECTOR = '{"assignments":[{"group_id":"2","key":"group-binding:10000000-0000-4000-8000-000000000001","owner_id":"7","source_id":"10000000-0000-4000-8000-000000000001","source_kind":"GROUP_BINDING","source_revision":"3"}],"client_routing":null,"department_defaults":[{"enabled":true,"group_id":"2","key":"20000000-0000-4000-8000-000000000002","owner_id":"7"}],"group_references":[{"group_id":"10","owner_ids":[]},{"group_id":"2","owner_ids":["10","7"]}]}'

  def setup
    identity = TenantServiceIdentityContract.new('fixture')
    identity.setup
    %w[human machine runtime privacy receipt].each { |name| instance_variable_set("@#{name}", identity.instance_variable_get("@#{name}")) }
    WasalxRoutingConfiguration.records = {}; WasalxRoutingConfiguration.writes = 0; WasalxRoutingConfiguration.locks = []
    Trigger.records = {}; Trigger.sequence = 20; Trigger.fail_create = false
    Group.records = [2, 10].to_h { |id| [id, OpenStruct.new(id: id, active: true, name: "Queue #{id}")] }
    @machine.routing_groups = { 2 => ['create'], 10 => ['full'] }
    [7, 10].each do |id|
      owner = NativeUser.new(id); owner.permission_names = ['ticket.agent']; owner.role_names = ['Agent']; owner.routing_groups = { 2 => ['full'], 10 => ['full'] }
      User.records[id] = owner
    end
    ENV['WASALX_SERVICE_JWT_SECRET'] = 'fixture-only-shared-hmac-secret'
    @manifest = JSON.parse(VECTOR)
  end

  def payload(revision = 1, manifest = @manifest, expected = revision - 1, action = 'APPLY')
    { 'schema_version' => 1, 'action' => action, 'tenant_id' => ENV['WASALX_TENANT_ID'], 'instance_id' => ENV['WASALX_ZAMMAD_INSTANCE_ID'],
      'revision' => revision, 'desired_sha256' => Config.digest(Config.canonical_manifest(manifest)), 'expected_native_revision' => expected, 'manifest' => manifest.deep_dup }
  end
  def call(value = payload); Config.call(value, service_user: @machine); end
  def state; WasalxRoutingConfiguration.records.values.first; end
  def snapshot; Marshal.dump([WasalxRoutingConfiguration.records, WasalxRoutingConfiguration.writes, Trigger.records, Trigger.sequence, @machine.routing_groups, User.records.transform_values(&:routing_groups), Group.records]); end
  def controller(body = JSON.generate(payload), token: @runtime, user: @machine, timestamp: Time.now.to_i.to_s, signature: nil)
    signature ||= OpenSSL::HMAC.hexdigest('SHA256', ENV['WASALX_SERVICE_JWT_SECRET'], "#{timestamp}\n#{body}")
    c = Api::V1::WasalxRoutingConfigurationsController.new
    c.current_user = user; c.instance_variable_set(:@_token, token)
    c.request = OpenStruct.new(raw_post: body, headers: { 'X-Wasalx-Timestamp' => timestamp, 'X-Wasalx-Signature' => signature })
    c
  end

  def test_shared_backend_canonical_vector_and_ascii_array_order
    reordered = @manifest.deep_dup; reordered['group_references'].reverse!; reordered['group_references'][0]['owner_ids'].reverse!
    canonical = Config.validate_manifest!(reordered)
    assert_equal VECTOR, JSON.generate(canonical)
    assert_equal '7d4b40e0810bdb3c1f1b4b3284c932df990c56eb0f7825fdbd870002fba94500', Config.digest(canonical)
  end

  def test_signed_bound_runtime_request_creates_only_one_explicit_assignment_trigger
    groups = Marshal.dump(Group.records); grants = Marshal.dump(User.records.transform_values(&:routing_groups))
    c = controller; c.create
    assert_equal :ok, c.response[0]; assert_equal 'SYNCED', c.response[1][:state]
    assert_equal 1, Trigger.records.length
    fields = Trigger.records.values.first.attributes
    assert_equal({ 'pre_condition' => 'specific', 'value' => '7', 'value_completion' => '' }, fields['perform'].fetch('ticket.owner_id'))
    assert_equal ['ticket.owner_id'], fields['perform'].keys
    assert_equal({ 'operator' => 'is', 'value' => 'create' }, fields['condition']['ticket.action'])
    assert_equal({ 'operator' => 'is', 'value' => ['2'] }, fields['condition']['ticket.group_id'])
    assert_equal({ 'operator' => 'is', 'value' => ['1'] }, fields['condition']['ticket.owner_id'])
    assert fields['disable_notification']; assert_equal 'action', fields['activator']
    assert_equal @machine.id, fields['created_by_id']
    assert_equal groups, Marshal.dump(Group.records); assert_equal grants, Marshal.dump(User.records.transform_values(&:routing_groups))
    assert_match(/SELECT pg_advisory_xact_lock\([0-9]+\)/, WasalxRoutingConfiguration.locks.last)
  end

  def test_no_department_policy_means_no_inferred_fallback_binding_or_handoff_trigger
    @manifest['department_defaults'] = []
    @manifest['assignments'] << { 'key' => "bot-handoff:#{GROUP_BINDING}:#{POLICY}:finance", 'source_kind' => 'BOT_HANDOFF',
      'source_id' => "#{GROUP_BINDING}:#{POLICY}:finance", 'source_revision' => '2', 'group_id' => '2', 'owner_id' => nil }
    @manifest['client_routing'] = { 'version_id' => POLICY, 'snapshot_sha256' => 'a' * 64, 'support_group_ids' => ['2'] }
    result = call
    assert_equal 'SYNCED', result[:state]; assert_empty Trigger.records
    assert_equal %w[BOT_HANDOFF CLIENT_ROUTING GROUP_BINDING GROUP_REFERENCE], result[:items].map { |item| item[:kind] }.uniq.sort
  end

  def test_default_update_disable_remove_and_reenable_reuse_exact_owned_identity
    call; id = Trigger.records.keys.first
    @manifest['department_defaults'][0]['owner_id'] = '10'
    assert_equal 'SYNCED', call(payload(2))[:state]; assert_equal [id], Trigger.records.keys
    assert_equal '10', Trigger.records[id].attributes['perform']['ticket.owner_id']['value']
    @manifest['department_defaults'][0]['enabled'] = false
    assert_equal 'SYNCED', call(payload(3))[:state]; refute Trigger.records[id].attributes['active']
    @manifest['department_defaults'] = []
    assert_equal 'SYNCED', call(payload(4))[:state]; refute Trigger.records[id].attributes['active']
    assert state.owned_triggers.key?(POLICY)
    @manifest['department_defaults'] = [{ 'key' => POLICY, 'group_id' => '2', 'owner_id' => '7', 'enabled' => true }]
    assert_equal 'SYNCED', call(payload(5))[:state]; assert_equal [id], Trigger.records.keys; assert Trigger.records[id].attributes['active']
  end

  def test_initial_check_and_lost_response_check_never_apply_again
    before = snapshot
    result = call(payload(1, @manifest, 0, 'CHECK'))
    assert_equal 'CONFLICT', result[:state]; assert_equal 0, result[:applied_revision]; assert_nil result[:observed_sha256]
    assert_equal 'NOT_APPLIED', result[:items].last[:error_code]; assert_equal before, snapshot
    accepted = call; before = snapshot
    checked = call(payload(1, @manifest, 0, 'CHECK'))
    assert_equal accepted, checked; assert_equal before, snapshot
    assert_equal accepted, call(payload(1, @manifest, 0)); assert_equal before, snapshot
  end

  def test_revision_hash_cas_and_supersession_never_certify_a_different_desired_revision
    call; before = snapshot
    changed = @manifest.deep_dup; changed['department_defaults'][0]['enabled'] = false
    assert_equal 'REVISION_CONFLICT', call(payload(1, changed, 1))[:items].last[:error_code]
    assert_equal 'STALE_NATIVE_REVISION', call(payload(2, changed, 0))[:items].last[:error_code]
    ahead = call(payload(2, changed, 1, 'CHECK'))
    assert_equal 'CONFLICT', ahead[:state]; assert_equal 1, ahead[:applied_revision]; assert_equal 'REVISION_AHEAD', ahead[:items].last[:error_code]
    assert_equal before, snapshot
    assert_equal 'SYNCED', call(payload(2, changed))[:state]
    old = call(payload(1)); assert_equal 'CONFLICT', old[:state]; assert_equal 2, old[:applied_revision]
    assert_equal 'STALE_REVISION', old[:items].last[:error_code]
  end

  def test_owned_native_edits_and_deletion_are_drift_and_cannot_be_overwritten
    call; id = Trigger.records.keys.first
    Trigger.records[id].attributes['perform']['ticket.owner_id']['value'] = '10'
    before = snapshot; result = call(payload(2))
    assert_equal 'DRIFT', result[:state]; refute_equal result[:desired_sha256], result[:observed_sha256]
    assert result[:items].any? { |item| item[:error_code] == 'TRIGGER_MODIFIED' }; assert_equal before, snapshot
    Trigger.records.delete(id); before = snapshot
    assert call(payload(2))[:items].any? { |item| item[:error_code] == 'TRIGGER_MISSING' }; assert_equal before, snapshot
  end

  def test_retired_owned_trigger_reactivation_is_drift
    call; @manifest['department_defaults'] = []; call(payload(2))
    Trigger.records.values.first.attributes['active'] = true
    before = snapshot; assert_equal 'DRIFT', call(payload(3))[:state]; assert_equal before, snapshot
  end

  def test_new_explicit_disable_can_retire_an_unavailable_target_without_rewriting_its_fields
    call; id = Trigger.records.keys.first
    original = Trigger.records[id].attributes.deep_dup
    User.records[7].active = false; Group.records[2].active = false
    assert_equal 'DRIFT', call(payload(1, @manifest, 1, 'CHECK'))[:state]
    disabled = @manifest.deep_dup; disabled['department_defaults'][0]['enabled'] = false
    disabled['group_references'] = []; disabled['assignments'] = []
    before = snapshot
    checked = call(payload(2, disabled, 1, 'CHECK'))
    assert_equal 'CONFLICT', checked[:state]; assert_equal 'REVISION_AHEAD', checked[:items].last[:error_code]
    refute checked[:items].any? { |item| item[:state] == 'DRIFT' }; assert_equal before, snapshot
    assert_equal 'SYNCED', call(payload(2, disabled))[:state]
    assert_equal original.merge('active' => false), Trigger.records[id].attributes
    assert_equal 'SYNCED', call(payload(2, disabled, 1, 'CHECK'))[:state]
  end

  def test_explicit_missing_policy_removal_records_absence_without_recreating_or_adopting
    call; id = Trigger.records.keys.first
    receipt = state.owned_triggers[POLICY].deep_dup
    Trigger.records.delete(id)
    removed = @manifest.deep_dup; removed['department_defaults'] = []; removed['group_references'] = []; removed['assignments'] = []
    checked = call(payload(2, removed, 1, 'CHECK'))
    assert_equal 'CONFLICT', checked[:state]; assert_equal 'REVISION_AHEAD', checked[:items].last[:error_code]
    assert_equal 'SYNCED', call(payload(2, removed))[:state]; assert_empty Trigger.records
    assert_equal receipt.merge('retired_missing' => true), state.owned_triggers[POLICY]
    assert_equal 'SYNCED', call(payload(2, removed, 1, 'CHECK'))[:state]
    assert_equal 'DRIFT', call(payload(3, @manifest))[:state]; assert_empty Trigger.records
  end

  def test_never_applied_disabled_policy_needs_no_live_target_and_creates_no_inactive_orphan
    @manifest['department_defaults'][0]['enabled'] = false
    @manifest['group_references'] = []; @manifest['assignments'] = []
    Group.records.clear; User.records[7].active = false
    assert_equal 'SYNCED', call[:state]; assert_empty Trigger.records
    assert_empty state.owned_triggers
  end

  def test_explicit_disable_still_refuses_native_trigger_edit_or_other_active_invalid_reference
    call; id = Trigger.records.keys.first
    disabled = @manifest.deep_dup; disabled['department_defaults'][0]['enabled'] = false
    disabled['assignments'] = []; disabled['group_references'] = []
    Trigger.records[id].attributes['perform']['ticket.owner_id']['value'] = '10'
    before = snapshot; assert_equal 'DRIFT', call(payload(2, disabled))[:state]; assert_equal before, snapshot
    setup; call
    disabled['group_references'] = [{ 'group_id' => '10', 'owner_ids' => [] }]
    Group.records[10].active = false
    before = snapshot; assert_equal 'DRIFT', call(payload(2, disabled))[:state]; assert_equal before, snapshot
  end

  def test_new_unrelated_revision_cannot_acknowledge_an_active_invalid_reference
    call; User.records[7].active = false
    @manifest['department_defaults'] = []
    # The owner is still used by the active source binding; retiring the queue
    # default cannot bypass that current mapping's eligibility check.
    before = snapshot; assert_equal 'DRIFT', call(payload(2))[:state]; assert_equal before, snapshot
  end

  def test_support_scope_change_updates_only_its_owned_default_template
    call; id = Trigger.records.keys.first
    assert_nil Trigger.records[id].attributes['condition']['ticket.wasalx_client_route_status']
    @manifest['client_routing'] = { 'version_id' => POLICY, 'snapshot_sha256' => 'a' * 64, 'support_group_ids' => ['2'] }
    assert_equal 'SYNCED', call(payload(2))[:state]; assert_equal [id], Trigger.records.keys
    assert_equal({ 'operator' => 'is not', 'value' => 'PENDING' }, Trigger.records[id].attributes['condition']['ticket.wasalx_client_route_status'])
    @manifest['client_routing'] = nil
    assert_equal 'SYNCED', call(payload(3))[:state]
    assert_nil Trigger.records[id].attributes['condition']['ticket.wasalx_client_route_status']
  end

  def test_invalid_group_grant_owner_and_machine_targets_produce_drift_without_writes
    changes = [-> { Group.records.delete(2) }, -> { Group.records[2].active = false },
      -> { @machine.routing_groups.delete(2) }, -> { User.records[7].active = false },
      -> { User.records[7].routing_groups[2] = ['read'] }, -> { User.records[7].permission_names = [] },
      -> { User.records[7].login = 'tenant-automation-other' }]
    changes.each do |change|
      setup; change.call; before = snapshot
      result = call; assert_equal 'DRIFT', result[:state]; refute_nil result[:observed_sha256]; assert_equal before, snapshot
    end
  end

  def test_queue_rename_and_unrelated_trigger_changes_are_not_owned_drift
    unrelated = Trigger.create!('name' => 'Unmanaged', 'active' => true, 'perform' => { 'ticket.priority_id' => { 'value' => '3' } })
    call; Group.records[2].name = 'Human queue rename'
    unrelated.attributes['perform']['ticket.priority_id']['value'] = '1'
    before = snapshot; assert_equal 'SYNCED', call(payload(1, @manifest, 0, 'CHECK'))[:state]; assert_equal before, snapshot
  end

  def test_same_display_name_is_never_adopted_even_with_matching_fields
    Trigger.create!('name' => "wasalx queue default #{POLICY}", 'active' => true)
    before = snapshot; result = call
    assert_equal 'DRIFT', result[:state]; assert_equal 'OWNERSHIP_CONFLICT', result[:items].last[:error_code]
    refute_nil result[:observed_sha256]; assert_equal before, snapshot
  end

  def test_unsigned_stale_wrong_token_and_prepared_admin_requests_never_write
    probes = [-> { controller(signature: '0' * 64) }, -> { controller(timestamp: (Time.now.to_i - 31).to_s) },
      -> { controller(token: @privacy) }, -> { controller(token: nil) }, -> { controller(user: @human) },
      -> { @receipt['phase'] = 'PREPARED'; controller }, -> { @machine.permission_names << 'admin.group'; controller }]
    probes.each do |probe|
      setup; c = probe.call; before = snapshot
      assert_raises(Exceptions::Forbidden) { c.create }; assert_equal before, snapshot
    end
    setup; body = JSON.generate(payload); timestamp = Time.now.to_i.to_s
    signature = OpenSSL::HMAC.hexdigest('SHA256', ENV['WASALX_SERVICE_JWT_SECRET'], "#{timestamp}\n#{body}")
    c = controller(body + ' ', timestamp: timestamp, signature: signature)
    assert_raises(Exceptions::Forbidden) { c.create }; assert_empty WasalxRoutingConfiguration.records
  end

  def test_oversized_and_future_signed_requests_are_rejected_without_writes
    [controller(' ' * (5 * 1024 * 1024 + 1)), controller(timestamp: (Time.now.to_i + 60).to_s)].each do |c|
      before = snapshot
      assert_raises(Exceptions::Forbidden) { c.create }; assert_equal before, snapshot
    end
  end

  def test_foreign_unknown_keys_bad_hash_and_ambiguous_defaults_are_rejected_before_native_writes
    invalid = [->(p) { p['tenant_id'] = POLICY }, ->(p) { p['instance_id'] = GROUP_BINDING },
      ->(p) { p['revision'] = 0 }, ->(p) { p['revision'] = Config::MAX_REVISION + 1 }, ->(p) { p['revision'] = 1.5 },
      ->(p) { p['expected_native_revision'] = -1 }, ->(p) { p['desired_sha256'] = 'a' * 64 },
      ->(p) { p['manifest']['department_defaults'] << p['manifest']['department_defaults'].first.merge('key' => GROUP_BINDING) },
      ->(p) { p['manifest']['department_defaults'][0]['perform'] = {} }, ->(p) { p['manifest']['client_routing'] = false },
      ->(p) { p['manifest']['assignments'][0]['source_revision'] = '9007199254740992' },
      ->(p) { p['manifest']['group_references'][0]['owner_ids'] << '9007199254740992' }]
    invalid.each do |mutate|
      p = payload; mutate.call(p); before = snapshot
      assert_raises(Config::InvalidRequest) { call(p) }; assert_equal before, snapshot
    end
    c = controller('{'); c.create; assert_equal [:bad_request, { error_code: 'ROUTING_CONFIGURATION_INVALID' }], c.response
  end

  def test_failure_after_an_owned_update_rolls_back_every_native_change
    call
    changed = @manifest.deep_dup; changed['department_defaults'][0]['owner_id'] = '10'
    changed['department_defaults'] << { 'key' => 'f0000000-0000-4000-8000-000000000001', 'group_id' => '10', 'owner_id' => '7', 'enabled' => true }
    changed['group_references'].find { |item| item['group_id'] == '10' }['owner_ids'] = ['7']
    before = snapshot; Trigger.fail_create = true
    assert_raises(RuntimeError) { call(payload(2, changed)) }; assert_equal before, snapshot
  end
end
