# SPDX-License-Identifier: AGPL-3.0-only
module Wasalx
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
  # 7.1.3 EmailAddress callbacks implicitly select a sender for the sole initial
  # group. A saved WasalX mailbox draft must wait for explicit verified activation.
  module MailboxAddressDraft
    private

    def update_email_address_id
      configured = channel_id && Channel.find_by(id: channel_id)
      return if configured && !configured.active && configured.preferences['wasalx_mail_revision'].is_a?(Integer)
      super
    end
  end
end
