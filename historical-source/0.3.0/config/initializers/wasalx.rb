# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
# Package installation triggers a Zammad application restart. On each boot (and
# each development reload), attach the package-owned concern without modifying
# Zammad's Ticket::Article source file or its native WhatsApp concern.
require Rails.root.join('lib/wasalx/client')

Rails.application.config.to_prepare do
  concern = Ticket::Article::EnqueueCommunicateWasalxJob
  Ticket::Article.include(concern) if !(Ticket::Article < concern)
end
