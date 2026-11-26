# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
# Schedules WasalX communication only for a committed, public article that an
# agent deliberately created with the WasalX article type. Inbound customer
# articles, system articles, notes, and imports are deliberately non-communicative.
module Ticket::Article::EnqueueCommunicateWasalxJob
  extend ActiveSupport::Concern

  included do
    after_create_commit :ticket_article_enqueue_communicate_wasalx_job
  end

  private

  def ticket_article_enqueue_communicate_wasalx_job
    return true if Setting.get('import_mode')
    return true if internal != false
    return true if !sender_id || !type_id
    return true if wasalx_provider_origin?

    sender = Ticket::Article::Sender.lookup(id: sender_id)
    return true if sender.nil? || sender.name != 'Agent'

    type = Ticket::Article::Type.lookup(id: type_id)
    return true if type.nil? || type.name != 'wasalx group message'

    CommunicateWasalxJob.perform_later(id)
  end

  def wasalx_provider_origin?
    origin = (preferences || {})['wasalx_origin'] || (preferences || {})[:wasalx_origin]
    origin == 'provider' || subject == 'Sent from WhatsApp device'
  end
end
