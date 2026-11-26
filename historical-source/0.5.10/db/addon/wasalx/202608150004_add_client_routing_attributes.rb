# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
class AddClientRoutingAttributes
  ATTRIBUTES = {
    wasalx_client_routing_version_id: 'WasalX client routing version',
    wasalx_client_id: 'WasalX client',
    wasalx_client_route_status: 'WasalX client routing status',
    wasalx_client_route_matched_by: 'WasalX client routing match'
  }.freeze

  def self.up
    UserInfo.current_user_id = 1
    ATTRIBUTES.each do |name, display|
      ObjectManager::Attribute.add(
        force: true, object: 'Ticket', name: name.to_s, display: display, data_type: 'input',
        data_option: { type: 'text', maxlength: 255, null: true, translate: false }, editable: false,
        active: true, screens: { create: { '-all-' => { shown: false, required: false } },
                                edit: { '-all-' => { shown: false, required: false } },
                                view: { '-all-' => { shown: true } } },
        to_create: true, to_migrate: true, to_delete: false, position: 9910,
        created_by_id: 1, updated_by_id: 1
      )
    end
  end

  def self.down
    ATTRIBUTES.each_key { |name| ObjectManager::Attribute.get(object: 'Ticket', name: name.to_s)&.update(active: false) }
  end
end
