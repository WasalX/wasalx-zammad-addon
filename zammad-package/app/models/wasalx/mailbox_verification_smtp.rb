# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
# Reuse the native SMTP transport while keeping this explicit probe's sole
# recipient fixed. Ordinary customer mail retains the native system BCC rule.
class Wasalx::MailboxVerificationSmtp < Channel::Driver::Smtp
  private

  def prepare_bcc_header(_attributes)
    nil
  end
end
