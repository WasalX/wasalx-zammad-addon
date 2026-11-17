# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
# A database-owned revision detects assignment changes even when group/owner
# later return to their original values. It is intentionally not registered in
# Object Manager, so agents and API callers cannot set it.
class AddWasalxAssignmentRevision
  FUNCTION = 'wasalx_track_ticket_assignment_revision'
  TRIGGER = 'wasalx_track_ticket_assignment_revision_trigger'

  def self.up
    connection = ActiveRecord::Migration.connection
    unless Ticket.column_names.include?('wasalx_assignment_revision')
      ActiveRecord::Migration.add_column(
        Ticket.table_name, :wasalx_assignment_revision, :bigint, null: false, default: 0
      )
    end

    table = connection.quote_table_name(Ticket.table_name)
    connection.execute <<~SQL
      CREATE OR REPLACE FUNCTION #{FUNCTION}() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.group_id IS DISTINCT FROM OLD.group_id OR NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
          NEW.wasalx_assignment_revision := OLD.wasalx_assignment_revision + 1;
        ELSE
          NEW.wasalx_assignment_revision := OLD.wasalx_assignment_revision;
        END IF;
        RETURN NEW;
      END;
      $$;
      DROP TRIGGER IF EXISTS #{TRIGGER} ON #{table};
      CREATE TRIGGER #{TRIGGER}
        BEFORE UPDATE OF group_id, owner_id, wasalx_assignment_revision ON #{table}
        FOR EACH ROW EXECUTE FUNCTION #{FUNCTION}();
    SQL
    Ticket.reset_column_information
    raise 'WasalX assignment revision column was not materialized' unless Ticket.column_names.include?('wasalx_assignment_revision')
  end

  def self.down; end
end
