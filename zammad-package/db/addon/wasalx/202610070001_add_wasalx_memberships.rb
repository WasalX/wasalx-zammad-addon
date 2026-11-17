# SPDX-License-Identifier: AGPL-3.0-only
class AddWasalxMemberships
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
  def self.up
    return if ActiveRecord::Migration.table_exists?(:wasalx_memberships)

    ActiveRecord::Migration.create_table :wasalx_memberships do |table|
      table.string :tenant_id, null: false
      table.string :instance_id, null: false
      table.string :portal_user_id, null: false
      table.string :subject, null: false
      table.string :email, null: false
      table.bigint :user_id
      table.bigint :revision, null: false, default: 0
      table.string :payload_sha256
      table.string :member_state, null: false, default: 'REMOVED'
      table.string :portal_role, null: false
      table.timestamps null: false
    end
    ActiveRecord::Migration.add_index :wasalx_memberships, :portal_user_id, unique: true
    ActiveRecord::Migration.add_index :wasalx_memberships, :subject, unique: true
    ActiveRecord::Migration.add_index :wasalx_memberships, :user_id, unique: true
    ActiveRecord::Migration.add_foreign_key :wasalx_memberships, :users
  end

  # Bindings and tombstones are operational history and survive package removal.
  def self.down; end
end
