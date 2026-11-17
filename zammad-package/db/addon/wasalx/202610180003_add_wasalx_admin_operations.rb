# SPDX-License-Identifier: AGPL-3.0-only
class AddWasalxAdminOperations
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
  def self.up
    return if ActiveRecord::Migration.table_exists?(:wasalx_admin_operations)
    ActiveRecord::Migration.create_table :wasalx_admin_operations do |table|
      table.string :operation_id, null: false
      table.string :portal_user_id, null: false
      table.bigint :native_user_id, null: false
      table.string :kind, null: false
      table.string :target_id
      table.string :request_sha256
      table.jsonb :result, null: false
      table.timestamps null: false
    end
    ActiveRecord::Migration.add_index :wasalx_admin_operations, :operation_id, unique: true
  end
  # Preserve cancellation and replay fences after package removal.
  def self.down; end
end
