# SPDX-License-Identifier: AGPL-3.0-only
require Rails.root.join('lib/wasalx/portal_mailbox_administration')
# Copyright (c) 2026 WasalX
require Rails.root.join('lib/wasalx/mailbox_verification')
require Rails.root.join('lib/wasalx/required_smtp_tls')
require Rails.root.join('lib/wasalx/mailbox_address_draft')
# Delegated configuration includes write-only credentials. Redact the entire input at ingress.
Rails.application.config.filter_parameters += [:input]

Rails.application.config.to_prepare do
  Channel::Driver::Smtp.prepend(Wasalx::RequiredSmtpTLS) unless Channel::Driver::Smtp < Wasalx::RequiredSmtpTLS
  EmailAddress.prepend(Wasalx::MailboxAddressDraft) unless EmailAddress < Wasalx::MailboxAddressDraft
  Channel.filter_attributes |= [:options]
end
