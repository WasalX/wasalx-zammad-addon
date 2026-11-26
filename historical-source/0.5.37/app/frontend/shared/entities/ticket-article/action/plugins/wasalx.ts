// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX

import type { TicketById } from '#shared/entities/ticket/types.ts'
import { EnumTicketArticleSenderName } from '#shared/graphql/types.ts'
import { getAcceptableFileTypesString } from '#shared/utils/files.ts'

import type {
  TicketArticleAction,
  TicketArticleActionPlugin,
  TicketArticleType,
} from './types.ts'

const ARTICLE_TYPE = 'wasalx group message'

// This is the deliberately conservative intersection of the media types and
// sizes accepted by WasalX's scanner and both provider adapters. Agents get a
// useful validation error before an unsupported file becomes a terminal
// delivery failure.
const allowedFiles = [
  { label: __('Image file'), types: ['image/jpeg', 'image/png'], size: 5 * 1024 * 1024 },
  {
    label: __('Audio file'),
    types: ['audio/mp4', 'audio/mpeg', 'audio/ogg'],
    size: 16 * 1024 * 1024,
  },
  { label: __('Video file'), types: ['video/mp4'], size: 16 * 1024 * 1024 },
  {
    label: __('Document file'),
    types: [
      'application/pdf',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    ],
    size: 25 * 1024 * 1024,
  },
]
const acceptableFileTypes = getAcceptableFileTypesString(allowedFiles)

const isBoundWasalxTicket = (ticket: TicketById) => {
  const values = ticket.objectAttributeValues || []
  const attributes = new Map(values.map((item) => [item.attribute.name, item.value]))
  return Boolean(attributes.get('wasalx_connection_id') && attributes.get('wasalx_group_id'))
}

const actionPlugin: TicketArticleActionPlugin = {
  order: 350,

  addActions(ticket, article) {
    if (!isBoundWasalxTicket(ticket)) return []
    if (article.type?.name !== ARTICLE_TYPE) return []
    if (article.sender?.name !== EnumTicketArticleSenderName.Customer) return []

    const action: TicketArticleAction = {
      apps: ['mobile', 'desktop'],
      label: __('Reply on WhatsApp'),
      name: ARTICLE_TYPE,
      icon: 'reply',
      alwaysVisible: true,
      view: { agent: ['change'] },
      perform(_ticket, currentArticle, { openReplyForm }) {
        openReplyForm({
          articleType: ARTICLE_TYPE,
          inReplyTo: currentArticle.messageId,
          internal: false,
        })
      },
    }
    return [action]
  },

  addTypes(ticket) {
    if (!isBoundWasalxTicket(ticket)) return []

    const type: TicketArticleType = {
      apps: ['mobile', 'desktop'],
      value: ARTICLE_TYPE,
      label: __('WhatsApp'),
      buttonLabel: __('Send on WhatsApp'),
      icon: 'whatsapp',
      view: { agent: ['change'] },
      fields: {
        body: {
          required: false,
          validation: 'require_one:attachments|length:1,4096',
        },
        attachments: {
          validation: 'require_one:body',
          accept: acceptableFileTypes,
          multiple: true,
          allowedFiles,
        },
      },
      internal: false,
      contentType: 'text/plain',
      editorMeta: {
        footer: {
          maxlength: 4096,
          allowExceedMaxLength: false,
        },
      },
    }
    return [type]
  },
}

export default actionPlugin
