# SPDX-License-Identifier: AGPL-3.0-only
class ExtendWasalxTicketOperationCancellation
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
  CONSTRAINT = 'wasalx_ticket_operations_ticket_presence'.freeze

  def self.up
    migration = ActiveRecord::Migration
    unless migration.check_constraint_exists?(:wasalx_ticket_operations, name: CONSTRAINT)
      migration.add_check_constraint :wasalx_ticket_operations,
        "ticket_id IS NOT NULL OR kind IN ('CANCELLED_GROUP_CREATE','CANCELLED_GROUP_LINK','CANCELLED_CREATE_TICKET')",
        name: CONSTRAINT
    end
    migration.change_column_null :wasalx_ticket_operations, :ticket_id, true
  end

  # Durable receipts and cancellation fences survive package removal.
  def self.down; end
end
