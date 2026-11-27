# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 WasalX

class SyncWasalxTicketTemplateRecoveryTranslation
  def self.up
    UserInfo.with_user_id(1) { Translation.sync_locale_from_po('ar') }
  end

  def self.down; end
end
