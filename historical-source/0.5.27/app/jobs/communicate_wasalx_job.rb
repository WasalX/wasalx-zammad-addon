# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 WasalX
class CommunicateWasalxJob < ApplicationJob
  retry_on Wasalx::Client::TemporaryRequestFailed, attempts: 4, wait: lambda { |executions|
    executions * 120.seconds
  }

  def perform(article_id)
    Service::Ticket::Article::Type::WasalxGroupMessage::Deliver.execute(article_id: article_id)
  end
end
