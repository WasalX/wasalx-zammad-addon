# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
module Wasalx
  module NativeIdentifiers
    private

    def bounded_limit!(value)
      return 50 if value.blank?

      limit = Integer(value, exception: false)
      raise ActionController::BadRequest, __('Invalid message limit') if !limit || limit < 1 || limit > 100

      limit
    end

    def positive_identifier!(value, label)
      text = value.to_s
      raise ActionController::BadRequest, __("Invalid #{label} identifier") if !text.match?(/\A[1-9][0-9]{0,15}\z/)

      text
    end

    def uuid!(value, label)
      text = value.to_s
      pattern = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
      raise ActionController::BadRequest, __("Invalid #{label} identifier") if !text.match?(pattern)

      text.downcase
    end

  end
end
