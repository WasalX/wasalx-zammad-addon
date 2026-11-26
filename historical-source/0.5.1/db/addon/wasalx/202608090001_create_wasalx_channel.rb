# SPDX-License-Identifier: AGPL-3.0-only
class CreateWasalxChannel
# Copyright (c) 2026 WasalX
  ATTRIBUTES = {
    wasalx_reference: 'WasalX reference', wasalx_group_id: 'WasalX group ID',
    wasalx_group_name: 'WasalX group', wasalx_connection_id: 'WasalX connection ID',
    wasalx_provider: 'WasalX provider', wasalx_source_message_id: 'WasalX source message ID',
    wasalx_correlation_key: 'WasalX correlation key',
    wasalx_latest_external_message_id: 'WasalX latest external message ID',
    wasalx_rule_version: 'WasalX rule version', wasalx_correlation_status: 'WasalX correlation status',
    wasalx_delivery_status: 'WasalX delivery status'
  }.freeze

  def self.up
    UserInfo.current_user_id = 1
    Permission.create_if_not_exists(
      name: 'ticket.agent.wasalx_retry',
      label: 'WasalX delivery retry',
      description: 'Retry failed WasalX deliveries',
      preferences: {}
    )
    Ticket::Article::Type.create_if_not_exists(
      name: 'wasalx group message', communication: true, updated_by_id: 1, created_by_id: 1
    )
    ATTRIBUTES.each do |name, display|
      ObjectManager::Attribute.add(
        force: true, object: 'Ticket', name: name.to_s, display: display, data_type: 'input',
        data_option: { type: 'text', maxlength: 255, null: true, translate: false }, editable: false,
        active: true, screens: { create: { '-all-' => { shown: false, required: false } },
                                edit: { '-all-' => { shown: false, required: false } },
                                view: { '-all-' => { shown: true } } },
        to_create: false, to_migrate: false, to_delete: false, position: 9900,
        created_by_id: 1, updated_by_id: 1
      )
    end
  end

  def self.down
    ATTRIBUTES.each_key do |name|
      attribute = ObjectManager::Attribute.get(object: 'Ticket', name: name.to_s)
      attribute&.update(active: false)
    end
    Ticket::Article::Type.find_by(name: 'wasalx group message')&.update(active: false)
    Permission.find_by(name: 'ticket.agent.wasalx_retry')&.update(active: false)
  end
end
