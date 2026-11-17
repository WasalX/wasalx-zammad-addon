# SPDX-License-Identifier: AGPL-3.0-only
Zammad::Application.routes.draw do
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
  get '/api/v1/wasalx/tickets/:ticket_id/panel', to: 'api/v1/wasalx#panel'
  post '/api/v1/wasalx/tickets/:ticket_id/articles/:article_id/retry', to: 'api/v1/wasalx#retry_delivery'
  get '/api/v1/wasalx/group_workspace/groups', to: 'api/v1/wasalx#group_workspace_groups'
  get '/api/v1/wasalx/group_workspace/groups/:group_id/messages', to: 'api/v1/wasalx#group_workspace_messages'
  get '/api/v1/wasalx/group_workspace/groups/:group_id/participants', to: 'api/v1/wasalx#group_workspace_participants'
  get '/api/v1/wasalx/group_workspace/groups/:group_id/messages/:message_id/context', to: 'api/v1/wasalx#group_workspace_context'
  get '/api/v1/wasalx/group_workspace/groups/:group_id/tickets', to: 'api/v1/wasalx#group_workspace_tickets'
  get '/api/v1/wasalx/group_workspace/ticket_groups', to: 'api/v1/wasalx#group_workspace_ticket_groups'
  post '/api/v1/wasalx/group_workspace/groups/:group_id/messages/:message_id/tickets', to: 'api/v1/wasalx#group_workspace_create_ticket'
  post '/api/v1/wasalx/group_workspace/groups/:group_id/messages/:message_id/ticket_links', to: 'api/v1/wasalx#group_workspace_link_ticket'
  post '/api/v1/wasalx/group_workspace/groups/:group_id/read', to: 'api/v1/wasalx#group_workspace_read'
  post '/api/v1/wasalx/group_workspace/groups/:group_id/send', to: 'api/v1/wasalx#group_workspace_send'
  get '/api/v1/wasalx/group_workspace/groups/:group_id/messages/:message_id/media', to: 'api/v1/wasalx#group_workspace_message_media'
  get '/api/v1/wasalx/group_workspace/uploads/:upload_id/:store_id', to: 'api/v1/wasalx#group_workspace_upload'
  delete '/api/v1/wasalx/group_workspace/uploads/:upload_id/:store_id', to: 'api/v1/wasalx#group_workspace_upload_destroy'
end
