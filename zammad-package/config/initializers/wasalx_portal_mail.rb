# SPDX-License-Identifier: AGPL-3.0-only
require Rails.root.join('lib/wasalx/portal_mail')
# Copyright (c) 2026 WasalX

Rails.application.config.to_prepare do
  target = NotificationFactory.singleton_class
  target.prepend(Wasalx::PortalMail::Templates) unless target < Wasalx::PortalMail::Templates
  mailer = NotificationFactory::Mailer.singleton_class
  mailer.prepend(Wasalx::PortalMail::InlineTemplates) unless mailer < Wasalx::PortalMail::InlineTemplates
end
