# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
class AddDirectConversationState
  ATTRIBUTES = {
    wasalx_bot_conversation: 'WasalX direct conversation',
    wasalx_bot_state: 'WasalX conversation state'
  }.freeze

  def self.up
    UserInfo.current_user_id = 1
    ATTRIBUTES.each do |name, display|
      ObjectManager::Attribute.add(
        force: true, object: 'Ticket', name: name.to_s, display: display, data_type: 'input',
        data_option: { type: 'text', maxlength: 255, null: true, translate: false }, editable: false,
        active: true, screens: { create: { '-all-' => { shown: false, required: false } },
                                edit: { '-all-' => { shown: false, required: false } },
                                view: { '-all-' => { shown: false } } },
        to_create: false, to_migrate: false, to_delete: false, position: 9920,
        created_by_id: 1, updated_by_id: 1
      )

      unless Ticket.column_names.include?(name.to_s)
        ActiveRecord::Migration.add_column(Ticket.table_name, name, :string, limit: 255, null: true)
      end
      ObjectManager::Attribute.get(object: 'Ticket', name: name.to_s)&.update!(
        to_create: false, to_migrate: false, to_delete: false, to_config: false
      )
    end
    Ticket.reset_column_information
  end

  def self.down
    ATTRIBUTES.each_key do |name|
      ObjectManager::Attribute.get(object: 'Ticket', name: name.to_s)&.update(active: false)
    end
  end
end
