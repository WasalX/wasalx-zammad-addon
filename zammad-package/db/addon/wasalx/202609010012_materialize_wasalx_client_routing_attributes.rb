# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
# Object Manager metadata alone does not guarantee that these package-owned
# ticket columns exist after a package upgrade.
class MaterializeWasalxClientRoutingAttributes
  ATTRIBUTES = %w[
    wasalx_client_routing_version_id
    wasalx_client_id
    wasalx_client_route_status
    wasalx_client_route_matched_by
  ].freeze

  def self.up
    UserInfo.current_user_id = 1

    ATTRIBUTES.each do |name|
      attribute = ObjectManager::Attribute.get(object: 'Ticket', name: name)
      raise "Missing WasalX Object Manager attribute: #{name}" if attribute.nil?

      unless Ticket.column_names.include?(name)
        ActiveRecord::Migration.add_column(Ticket.table_name, name, :string, limit: 255, null: true)
      end

      attribute.update!(to_create: false, to_migrate: false, to_delete: false, to_config: false)
    end

    Ticket.reset_column_information
    missing = ATTRIBUTES - Ticket.column_names
    raise "WasalX client-routing columns were not materialized: #{missing.join(', ')}" if missing.any?
  end

  def self.down; end
end
