# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
class SyncWasalxAgentUiTranslations
  def self.up
    UserInfo.current_user_id = 1
    Translation.sync_locale_from_po('ar')
  end

  # Translations are shared by every WasalX package revision.
  def self.down; end
end
