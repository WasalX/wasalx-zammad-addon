# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
class HideWasalxClientRoutingAttributes
  ATTRIBUTES = %w[
    wasalx_client_routing_version_id
    wasalx_client_id
    wasalx_client_route_status
    wasalx_client_route_matched_by
  ].freeze

  def self.up
    UserInfo.current_user_id = 1
    ObjectManager::Attribute.transaction do
      attributes = ATTRIBUTES.to_h { |name| [name, ObjectManager::Attribute.get(object: 'Ticket', name: name)] }
      missing = attributes.select { |_name, attribute| attribute.nil? }.keys
      raise "Missing WasalX Object Manager attributes: #{missing.join(', ')}" if missing.any?

      references = ObjectManager::Attribute.attribute_to_references_hash
      referenced = attributes.keys.filter_map do |name|
        next if !ObjectManager::Attribute.attribute_used_by_references?('Ticket', name, references)

        "#{name} (#{ObjectManager::Attribute.attribute_used_by_references_humaniced('Ticket', name, references)})"
      end
      raise "Referenced WasalX client-routing attributes cannot be hidden: #{referenced.join('; ')}" if referenced.any?

      attributes.each_value do |attribute|
        attribute.update!(
          active: false,
          editable: false,
          screens: {
            create: { '-all-' => { shown: false, required: false } },
            edit: { '-all-' => { shown: false, required: false } },
            view: { '-all-' => { shown: false } }
          },
          to_create: false, to_migrate: false, to_delete: false, to_config: false
        )
      end
    end
  end

  def self.down; end
end
