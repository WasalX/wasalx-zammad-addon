# SPDX-License-Identifier: AGPL-3.0-only
module Wasalx
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
  module RequiredSmtpTLS
    def build_smtp_params(options)
      result = super
      return result unless options[:wasalx_require_starttls] == true
      raise ArgumentError, 'Secure email settings are required' if options[:ssl] || options[:ssl_verify] != true || options[:openssl_verify_mode].to_s != 'peer'
      # Native SMTP forwards opportunistic STARTTLS only; Mail supports mandatory STARTTLS.
      result.delete(:enable_starttls_auto)
      result[:enable_starttls] = :always
      result
    end
  end
end
