# SPDX-License-Identifier: AGPL-3.0-only
class AddWasalxRoutingConfigurations
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
  def self.up
    return if ActiveRecord::Migration.table_exists?(:wasalx_routing_configurations)

    ActiveRecord::Migration.create_table :wasalx_routing_configurations do |table|
      table.string :tenant_id, null: false
      table.string :instance_id, null: false
      table.bigint :applied_revision, null: false
      table.string :desired_sha256, null: false
      table.jsonb :manifest, null: false, default: {}
      table.jsonb :owned_triggers, null: false, default: {}
      table.timestamps null: false
    end
    ActiveRecord::Migration.add_index :wasalx_routing_configurations, [:tenant_id, :instance_id],
      unique: true, name: 'index_wasalx_routing_configuration_identity'
  end

  # Keep ownership and retired trigger receipts; package removal is not an undo.
  def self.down; end
end
