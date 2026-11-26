# SPDX-License-Identifier: AGPL-3.0-only
Zammad::Application.routes.draw do
# Copyright (c) 2026 WasalX
  post '/api/v1/wasalx/tickets/:ticket_id/articles/:article_id/retry', to: 'api/v1/wasalx#retry_delivery'
end
