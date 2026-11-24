# SPDX-License-Identifier: AGPL-3.0-only

class SyncWasalxTicketTemplateTranslations
  def self.up
    UserInfo.current_user_id = 1
    Translation.sync_locale_from_po('ar')
  end

  def self.down; end
end
