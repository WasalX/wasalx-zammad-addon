# SPDX-License-Identifier: AGPL-3.0-only
require 'uri'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'openssl'
require Rails.root.join('lib/zammad/service/redis')

# Use the supported Ruby driver to verify both the CA and URL hostname.
module WasalxRedisTls
  def config
    options = super
    return options unless options[:url]&.start_with?('rediss:')

    begin
      uri = URI.parse(options.fetch(:url))
      ca = ENV.fetch('SSL_CERT_FILE')
      raise ArgumentError unless uri.scheme == 'rediss' && uri.hostname && !uri.hostname.empty?
      raise ArgumentError unless File.absolute_path(ca) == ca && File.file?(ca) && File.readable?(ca)
    rescue ArgumentError, KeyError, URI::Error
      raise ArgumentError, 'Invalid Zammad Redis TLS configuration', cause: nil
    end
    options.merge(driver: :ruby, ssl_params: options.fetch(:ssl_params, {}).merge(
      ca_file: ca, verify_mode: OpenSSL::SSL::VERIFY_PEER, verify_hostname: true
    ))
  end
end

Zammad::Service::Redis.singleton_class.prepend(WasalxRedisTls)
