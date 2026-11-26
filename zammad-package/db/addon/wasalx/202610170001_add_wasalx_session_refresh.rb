# SPDX-License-Identifier: AGPL-3.0-only
class AddWasalxSessionRefresh
# Copyright (c) 2026 WasalX
  def self.up
    column = ActiveRecord::Migration.connection.columns(:sessions).find do |entry|
      entry.name == 'wasalx_oidc_refresh_state'
    end
    if column
      unless column.type == :text && column.null && column.default.nil? && column.default_function.nil?
        raise 'WasalX native refresh storage is incompatible'
      end
      return
    end

    ActiveRecord::Migration.add_column :sessions, :wasalx_oidc_refresh_state, :text, null: true, default: nil
  end

  def self.down; end
end
