# SPDX-License-Identifier: AGPL-3.0-only
require 'uri'
# Copyright (c) 2026 WasalX
require 'ipaddr'

module Ticket::Article::NormalizeWasalxMessageId
  private

  def metadata_email_process_message_id
    generated = !message_id || Rails.env.production?
    super
    return if !generated

    authority = URI.parse("//#{Setting.get('fqdn')}")
    host = authority.hostname
    if !host || authority.userinfo || !authority.path.empty? || authority.query || authority.fragment
      raise ArgumentError, 'Invalid email Message-ID authority'
    end
    if host.include?(':')
      address = IPAddr.new(host)
      raise ArgumentError, 'Invalid email Message-ID authority' if !address.ipv6?
      host = "[IPv6:#{address}]"
    elsif host.length > 253 || !host.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/i)
      raise ArgumentError, 'Invalid email Message-ID authority'
    end
    self.message_id = message_id.sub(/@[^@]+>\z/, "@#{host}>")
    check_message_id_md5
  end
end
