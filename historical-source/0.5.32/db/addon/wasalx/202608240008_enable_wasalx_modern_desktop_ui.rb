# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
# WasalX agent surfaces are compiled into Zammad's maintained desktop app.
# Enable Zammad's own availability switch for every eligible role; the legacy
# interface remains available as the supported fallback.
class EnableWasalxModernDesktopUi
  SETTINGS = {
    'ui_desktop_beta_switch' => true,
    'ui_desktop_beta_switch_role_ids' => []
  }.freeze

  def self.up
    UserInfo.current_user_id = 1
    SETTINGS.each do |name, value|
      raise "Missing supported Zammad desktop setting: #{name}" if !Setting.exists?(name: name)

      Setting.set(name, value)
    end
  end

  # Keep the supported desktop interface available after package rollback.
  def self.down; end
end
