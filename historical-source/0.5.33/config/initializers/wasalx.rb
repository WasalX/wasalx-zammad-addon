# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
# Package installation triggers a Zammad application restart. On each boot (and
# each development reload), attach the package-owned concern without modifying
# Zammad's Ticket::Article source file or its native WhatsApp concern.
require Rails.root.join('lib/wasalx/client')

Rails.application.config.to_prepare do
  article_concern = Ticket::Article::EnqueueCommunicateWasalxJob
  Ticket::Article.include(article_concern) if !(Ticket::Article < article_concern)
  ticket_concern = Ticket::EnqueueWasalxTicketStateJob
  Ticket.include(ticket_concern) if !(Ticket < ticket_concern)
end
