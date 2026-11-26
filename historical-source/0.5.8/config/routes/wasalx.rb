# SPDX-License-Identifier: AGPL-3.0-only
Zammad::Application.routes.draw do
# Copyright (c) 2026 WasalX
  get '/api/v1/wasalx/tickets/:ticket_id/panel', to: 'api/v1/wasalx#panel'
  post '/api/v1/wasalx/tickets/:ticket_id/articles/:article_id/retry', to: 'api/v1/wasalx#retry_delivery'
  get '/api/v1/wasalx/group_workspace/groups', to: 'api/v1/wasalx#group_workspace_groups'
  get '/api/v1/wasalx/group_workspace/groups/:group_id/messages', to: 'api/v1/wasalx#group_workspace_messages'
  get '/api/v1/wasalx/group_workspace/groups/:group_id/messages/:message_id/context', to: 'api/v1/wasalx#group_workspace_context'
  get '/api/v1/wasalx/group_workspace/groups/:group_id/tickets', to: 'api/v1/wasalx#group_workspace_tickets'
  post '/api/v1/wasalx/group_workspace/groups/:group_id/read', to: 'api/v1/wasalx#group_workspace_read'
end
