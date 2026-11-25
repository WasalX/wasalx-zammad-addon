# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
# Kept separate from the initial package migration so existing tenant
# workspaces receive the routing fields when upgrading WasalX.
class AddWasalxRoutingAttributes
  ATTRIBUTES = {
    wasalx_assignment_mode: 'WasalX assignment mode',
    wasalx_default_priority: 'WasalX default priority',
    wasalx_sla_policy_id: 'WasalX SLA policy',
    wasalx_business_hours_mode: 'WasalX business hours mode',
    wasalx_business_hours_calendar_id: 'WasalX business hours calendar'
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
        to_create: false, to_migrate: false, to_delete: false, position: 9900,
        created_by_id: 1, updated_by_id: 1
      )
    end
  end

  def self.down
    ATTRIBUTES.each_key do |name|
      ObjectManager::Attribute.get(object: 'Ticket', name: name.to_s)&.update(active: false)
    end
  end
end
