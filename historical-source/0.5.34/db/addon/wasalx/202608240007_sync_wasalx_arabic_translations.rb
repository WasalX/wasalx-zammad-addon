# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
class SyncWasalxArabicTranslations
  TRANSLATION_FILE = 'i18n/wasalx.ar.po'

  def self.up
    UserInfo.current_user_id = 1
    Translation.sync_locale_from_po('ar')
  end

  def self.down
    UserInfo.current_user_id = 1
    Translation.where(locale: 'ar', synchronized_from_translation_file: TRANSLATION_FILE).find_each do |translation|
      if translation.target == translation.target_initial
        translation.destroy!
      else
        translation.update!(
          is_synchronized_from_codebase: false,
          synchronized_from_translation_file: nil,
          updated_by_id: 1
        )
      end
    end
  end
end
