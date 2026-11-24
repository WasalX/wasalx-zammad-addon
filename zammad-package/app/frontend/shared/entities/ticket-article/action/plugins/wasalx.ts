// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>

import type { TicketArticle, TicketById } from '#shared/entities/ticket/types.ts'
import { EnumTicketArticleSenderName } from '#shared/graphql/types.ts'
import { getAcceptableFileTypesString } from '#shared/utils/files.ts'

import { observeWasalxValidationRemoval } from '../../../../form/validation/rules/wasalx-require-one.ts'

import { openWasalxTemplateDialog } from '../wasalxTemplateDialog.ts'
import { attachWasalxReplyPreview, detachWasalxReplyPreview } from '../wasalxReplyPreview.ts'

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

const ticketAttributes = (ticket: TicketById) => {
  const values = ticket.objectAttributeValues || []
  return new Map(values.map((item) => [item.attribute.name, item.value]))
}

const canUseWasalxComposer = (ticket: TicketById) => {
  const attributes = ticketAttributes(ticket)
  if (!attributes.get('wasalx_connection_id') || !attributes.get('wasalx_group_id')) return false

  const marker = attributes.get('wasalx_bot_conversation')
  const state = attributes.get('wasalx_bot_state')
  const direct = marker === true || String(marker).toLowerCase() === 'true' || Boolean(state)
  return !direct || state === 'HUMAN' || (state === 'BOT' && attributes.get('wasalx_bot_keep_open') === 'true')
}

const replyIdentity = (article: TicketArticle): string | undefined => {
  if (article.messageId) return article.messageId
  const id = String(article.internalId ?? '')
  return /^[1-9][0-9]{0,15}$/.test(id) ? `wasalx-article:${id}` : undefined
}

const prepareWasalxComposer: NonNullable<TicketArticleType['onOpened']> = (ticket, { body }, form) => {
  observeWasalxValidationRemoval(form?.getNodeByName('body'))
  observeWasalxValidationRemoval(form?.getNodeByName('attachments'))
  attachWasalxReplyPreview(ticket, body, form)
}

const actionPlugin: TicketArticleActionPlugin = {
  order: 350,

  addActions(ticket, article) {
    if (!canUseWasalxComposer(ticket)) return []
    if (article.type?.name !== ARTICLE_TYPE) return []
    if (article.internal !== false || !replyIdentity(article)) return []
    if (article.sender?.name !== EnumTicketArticleSenderName.Customer &&
      article.sender?.name !== EnumTicketArticleSenderName.Agent) return []

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
          inReplyTo: replyIdentity(currentArticle),
          internal: false,
        })
      },
    }
    const attributes = ticketAttributes(ticket)
    if (attributes.get('wasalx_bot_state') !== 'HUMAN' || attributes.get('wasalx_provider') !== 'META') return [action]

    return [action, {
      apps: ['mobile', 'desktop'],
      label: __('Send WhatsApp template'),
      name: 'wasalx-template',
      icon: 'whatsapp',
      view: { agent: ['change'] },
      perform(currentTicket) {
        void openWasalxTemplateDialog(String(currentTicket.internalId ?? ''))
      },
    }]
  },

  addTypes(ticket) {
    if (!canUseWasalxComposer(ticket)) return []

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
          validation: 'wasalx_require_one:attachments|length:1,4096',
        },
        attachments: {
          validation: 'wasalx_require_one:body',
          accept: acceptableFileTypes,
          multiple: true,
          allowedFiles,
        },
      },
      internal: false,
      contentType: 'text/plain',
      onOpened: prepareWasalxComposer,
      onSelected: prepareWasalxComposer,
      onDeselected: (_currentTicket, { body }) => detachWasalxReplyPreview(body),
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
