# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
# A browser retry must resolve the exact ticket article created by the first
# request. Article preferences are serialized and are not a safe unique key,
# so the package owns one small indexed operation key instead of scanning them.
class AddGroupWorkspaceOperationKey
  INDEX = 'ticket_articles_wasalx_operation_key_unique'

  def self.up
    if !Ticket::Article.column_names.include?('wasalx_operation_key')
      ActiveRecord::Migration.add_column(
        Ticket::Article.table_name,
        :wasalx_operation_key,
        :string,
        limit: 255,
        null: true
      )
    end
    if !ActiveRecord::Migration.connection.index_exists?(Ticket::Article.table_name, :wasalx_operation_key, name: INDEX)
      ActiveRecord::Migration.add_index(
        Ticket::Article.table_name,
        :wasalx_operation_key,
        unique: true,
        where: 'wasalx_operation_key IS NOT NULL',
        name: INDEX
      )
    end
    Ticket::Article.reset_column_information
  end

  # Downgrades retain the operation ledger and its ticket history.
  def self.down; end
end
