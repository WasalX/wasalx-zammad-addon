# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 WasalX

require 'minitest/autorun'

ROOT = File.expand_path('..', __dir__)
MIGRATION = File.join(ROOT, 'zammad-package/db/addon/wasalx/202609190016_sanitize_wasalx_internal_error_translation.rb')

TranslationRow = Struct.new(:target, :target_initial, :reset_count) do
  def reset
    self.target = target_initial
    self.reset_count = reset_count.to_i + 1
  end
end

class UserInfo
  class << self
    attr_accessor :current_user_id
  end
end

class Translation
  class << self
    attr_accessor :rows

    def find_source(locale, source)
      raise 'Unexpected source' unless source == SanitizeWasalxInternalErrorTranslation::SOURCE
      rows[locale]
    end
  end
end

class Service
  class Translation
    class Upsert
      def self.execute(locale:, source:, target:)
        row = ::Translation.find_source(locale, source)
        row.target = target
      end
    end
  end
end

load MIGRATION

class ZammadInternalErrorTranslationContractTest < Minitest::Test
  SOURCE = SanitizeWasalxInternalErrorTranslation::SOURCE
  TARGETS = SanitizeWasalxInternalErrorTranslation::TARGETS

  def setup
    UserInfo.current_user_id = nil
    Translation.rows = {
      'en-us' => TranslationRow.new(SOURCE, SOURCE, 0),
      'ar'    => TranslationRow.new('', '', 0),
    }
  end

  def test_up_uses_supported_local_translations_and_drops_the_raw_placeholder
    SanitizeWasalxInternalErrorTranslation.up

    assert_equal 1, UserInfo.current_user_id
    TARGETS.each do |locale, target|
      assert_equal target, Translation.rows.fetch(locale).target
      refute_includes target.sub('%s', 'SIMULATED_PRIVATE_SENTINEL'), 'SIMULATED_PRIVATE_SENTINEL'
      assert_match(/try again|حاول مرة أخرى/, target)
    end
  end

  def test_up_fails_before_writing_when_an_operator_translation_exists
    Translation.rows.fetch('ar').target = 'operator wording'

    error = assert_raises(RuntimeError) { SanitizeWasalxInternalErrorTranslation.up }
    assert_match(/already customized for ar/, error.message)
    assert_equal SOURCE, Translation.rows.fetch('en-us').target
    assert_equal 'operator wording', Translation.rows.fetch('ar').target
  end

  def test_down_resets_only_unchanged_package_targets
    SanitizeWasalxInternalErrorTranslation.up
    Translation.rows.fetch('ar').target = 'later operator wording'

    SanitizeWasalxInternalErrorTranslation.down

    assert_equal SOURCE, Translation.rows.fetch('en-us').target
    assert_equal 1, Translation.rows.fetch('en-us').reset_count
    assert_equal 'later operator wording', Translation.rows.fetch('ar').target
    assert_equal 0, Translation.rows.fetch('ar').reset_count
  end
end
