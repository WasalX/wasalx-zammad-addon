# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
class SyncWasalxDeliveryFailureTranslations
  def self.up
    UserInfo.current_user_id = 1
    Translation.sync_locale_from_po('ar')
  end

  def self.down; end
end
