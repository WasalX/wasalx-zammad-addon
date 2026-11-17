# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
# Package 0.5.1 registered the Object Manager metadata with migration flags
# disabled, leaving new installations without the corresponding ticket columns.
# This migration repairs existing tenants and is also the final materialization
# step for fresh installs. It touches only WasalX-owned columns rather than
# executing unrelated pending Object Manager changes.
class MaterializeWasalxTicketAttributes
  ATTRIBUTES = %w[
    wasalx_reference
    wasalx_group_id
    wasalx_group_name
    wasalx_connection_id
    wasalx_provider
    wasalx_source_message_id
    wasalx_correlation_key
    wasalx_latest_external_message_id
    wasalx_rule_version
    wasalx_correlation_status
    wasalx_delivery_status
    wasalx_assignment_mode
    wasalx_default_priority
    wasalx_sla_policy_id
    wasalx_business_hours_mode
    wasalx_business_hours_calendar_id
  ].freeze

  def self.up
    UserInfo.current_user_id = 1

    ATTRIBUTES.each do |name|
      attribute = ObjectManager::Attribute.get(object: 'Ticket', name: name)
      raise "Missing WasalX Object Manager attribute: #{name}" if attribute.nil?

      unless Ticket.column_names.include?(name)
        ActiveRecord::Migration.add_column(
          Ticket.table_name,
          name,
          :string,
          limit: 255,
          null: true
        )
      end

      attribute.update!(
        to_create: false,
        to_migrate: false,
        to_delete: false,
        to_config: false
      )
    end

    Ticket.reset_column_information
    missing = ATTRIBUTES - Ticket.column_names
    raise "WasalX ticket columns were not materialized: #{missing.join(', ')}" if missing.any?
  end

  # Downgrades retain ticket data. The earlier package migrations deactivate
  # their metadata without destructively dropping operational case history.
  def self.down; end
end
