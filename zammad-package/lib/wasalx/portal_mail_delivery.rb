# SPDX-License-Identifier: AGPL-3.0-only
require 'date'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
module Wasalx
  module PortalMailDelivery
    module_function
    def preferences(record)
      record&.preferences.to_h.transform_keys(&:to_s)
    end
    def notice?(article)
      article.internal == true && article.sender&.name == 'System' && preferences(article)['delivery_message'] == true
    end
    def article(article)
      data = preferences(article)
      if notice?(article)
        return { state: 'UNCONFIRMED', attempts: nil, automatic_attempts_ended: true, notice: true }
      end
      return nil unless article.internal == false && article.type&.name == 'email' && %w[Agent System].include?(article.sender&.name)
      attempts = data['delivery_retry']
      attempts = nil unless attempts.is_a?(Integer) && (0..1_000_000).cover?(attempts)
      { state: data['delivery_status'] == 'success' ? 'SENT' : 'UNCONFIRMED', attempts: attempts,
        automatic_attempts_ended: data['delivery_status'] == 'fail' && !attempts.nil? && attempts >= 4, notice: false }
    end
    # Same native61day window without User#mail_delivery_failed_blocked_days resetting/saving the user.
    def recipient(user, today: Time.current.to_date)
      data = preferences(user)
      return { state: 'CLEAR', reason: nil } unless data['mail_delivery_failed'] == true
      observed = data['mail_delivery_failed_data']
      return { state: 'UNCONFIRMED', reason: nil } if observed.nil? || observed.to_s.empty?
      date = observed.respond_to?(:to_date) ? observed.to_date : Date.parse(observed.to_s)
      return { state: 'UNCONFIRMED', reason: nil } if date > today
      return { state: 'CLEAR', reason: nil } unless (date - today).to_i + 61 > 0
      { state: 'RECENT_FAILURE', reason: data['mail_delivery_failed_reason'] == 'invalid email' ? 'INVALID_ADDRESS' : 'BOUNCE_OR_DELIVERY_FAILURE' }
    rescue ArgumentError, TypeError
      { state: 'UNCONFIRMED', reason: nil }
    end
  end
end
