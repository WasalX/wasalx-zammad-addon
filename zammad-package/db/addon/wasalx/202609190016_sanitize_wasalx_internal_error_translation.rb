# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
class SanitizeWasalxInternalErrorTranslation
  SOURCE = 'Something went wrong. Received message: %s'
  TARGETS = {
    'en-us' => 'Something went wrong. Go back and try again.',
    'ar'    => 'حدث خطأ ما. ارجع وحاول مرة أخرى.',
  }.freeze

  def self.up
    UserInfo.current_user_id = 1
    current = TARGETS.to_h do |locale, target|
      translation = Translation.find_source(locale, SOURCE)
      raise "Internal error translation contract changed for #{locale}" if !translation
      if translation.target != translation.target_initial && translation.target != target
        raise "Internal error translation already customized for #{locale}"
      end
      [locale, translation]
    end

    TARGETS.each do |locale, target|
      next if current.fetch(locale).target == target
      Service::Translation::Upsert.execute(locale: locale, source: SOURCE, target: target)
      raise "Internal error translation update failed for #{locale}" if Translation.find_source(locale, SOURCE)&.target != target
    end
  end

  def self.down
    UserInfo.current_user_id = 1
    TARGETS.each do |locale, target|
      translation = Translation.find_source(locale, SOURCE)
      translation.reset if translation&.target == target
    end
  end
end
