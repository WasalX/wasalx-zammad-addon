# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
# WasalX agent surfaces are compiled into Zammad's maintained desktop app and
# managed deployments open /desktop directly. Disable Zammad's optional beta
# switch banner so agents stay in that workspace without release-stage copy.
class EnableWasalxModernDesktopUi
  SETTINGS = {
    'ui_desktop_beta_switch' => false,
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
