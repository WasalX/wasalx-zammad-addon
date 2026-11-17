// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
import type { FormRef } from '#shared/components/Form/types.ts'
import type { FieldEditorContext } from '#shared/components/Form/fields/FieldEditor/types.ts'
import type { TicketById } from '#shared/entities/ticket/types.ts'
import type { FormKitNode } from '@formkit/core'

type PreviewResponse = { text: string; replyToMessageId?: string | null; quoteLabel?: string | null }
type PreviewBinding = { form: FormRef; ticketId: string; dispose: () => void; refresh: () => void }
const bindings = new WeakMap<object, PreviewBinding>()

export const detachWasalxReplyPreview = (context: FieldEditorContext) => bindings.get(context)?.dispose()

export const attachWasalxReplyPreview = (
  ticket: TicketById,
  context: FieldEditorContext,
  form: FormRef | undefined,
  options: { restoredDraft?: boolean } = {},
) => {
  const existing = bindings.get(context)
  const ticketId = String(ticket.internalId ?? '')
  // Keep the sidebar's cleanup valid when a manual hook refreshes its editor.
  if (existing && existing.form === form && existing.ticketId === ticketId) {
    existing.refresh()
    return existing.dispose
  }
  // Manual composer hooks already own a live draft; never relabel one as a
  // restored initial value when the sidebar also discovers the same editor.
  let restoredDraft = options.restoredDraft === true && !existing
  detachWasalxReplyPreview(context)
  const body = form?.getNodeByName('body')
  const articleType = form?.getNodeByName('articleType')
  const internal = form?.getNodeByName('internal')
  const inReplyTo = form?.getNodeByName('inReplyTo')
  const attachments = form?.getNodeByName('attachments')
  if (!form || !body || !articleType || !internal || !inReplyTo) return
  if (!/^[1-9][0-9]{0,15}$/.test(ticketId)) return

  const savedHelp = body.props.help
  const savedHelpClass = body.props.helpClass
  const helpClass = 'whitespace-pre-wrap break-words text-start'
  const receipts: Array<[FormKitNode, string]> = []
  let timer: ReturnType<typeof setTimeout> | undefined
  let request: AbortController | undefined
  let generation = 0
  let disposed = false
  let ownedHelp: string | undefined
  const restore = () => {
    if (body.props.help === ownedHelp) body.props.help = savedHelp
    if (body.props.helpClass === helpClass) body.props.helpClass = savedHelpClass
    ownedHelp = undefined
  }
  const show = (text: string) => {
    ownedHelp = text
    body.props.help = text
    body.props.helpClass = helpClass
  }
  const permitted = () => articleType.value === 'wasalx group message' && internal.value === false
  const refresh = async (version: number) => {
    if (disposed || version !== generation || !permitted()) return
    const controller = new AbortController()
    request = controller
    const initialRestoredDraft = restoredDraft
    restoredDraft = false
    const csrf = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content
    try {
      const response = await fetch(`/api/v1/wasalx/tickets/${ticketId}/reply-preview`, {
        method: 'POST', credentials: 'same-origin', signal: controller.signal,
        headers: { Accept: 'application/json', 'Content-Type': 'application/json', ...(csrf ? { 'X-CSRF-Token': csrf } : {}) },
        body: JSON.stringify({ body: context.getEditorValue('text/plain'), in_reply_to: inReplyTo.value || null, internal: false, has_attachments: Array.isArray(attachments?.value) && attachments.value.length > 0,
          ...(initialRestoredDraft ? { restored_draft: true } : {}) }),
      })
      if (!response.ok) throw new Error('Preview unavailable')
      const value = await response.json() as PreviewResponse
      if (typeof value.text !== 'string' || value.text.length > 65_536 ||
        (value.quoteLabel != null && (typeof value.quoteLabel !== 'string' || value.quoteLabel.length > 512)) ||
        (value.replyToMessageId != null && typeof value.replyToMessageId !== 'string')) throw new Error('Invalid preview')
      if (disposed || version !== generation || !permitted()) return
      const quote = value.replyToMessageId
        ? value.quoteLabel || __('Replying to a linked ticket message')
        : __('No quoted message')
      show(`${__('Outgoing WhatsApp preview')}\n${quote}\n\n${value.text}`)
    } catch {
      if (!controller.signal.aborted && !disposed && version === generation && permitted()) {
        show(__('Outgoing preview is unavailable. Your draft is unchanged.'))
      }
    }
  }
  const schedule = () => {
    generation += 1
    if (timer) clearTimeout(timer)
    request?.abort()
    if (!permitted()) { restore(); return }
    if (!String(body.value ?? '').trim() && (!Array.isArray(attachments?.value) || attachments.value.length === 0)) { restore(); return }
    show(__('Updating outgoing WhatsApp preview…'))
    const version = generation
    timer = setTimeout(() => { void refresh(version) }, 250)
  }
  const dispose = () => {
    if (disposed) return
    disposed = true
    generation += 1
    if (timer) clearTimeout(timer)
    request?.abort()
    for (const [node, receipt] of receipts) node.off(receipt)
    restore()
    bindings.delete(context)
  }
  for (const node of [body, articleType, internal, inReplyTo, attachments]) {
    if (node) receipts.push([node, node.on('commit', () => { restoredDraft = false; schedule() })])
  }
  receipts.push([body, body.on('destroying', dispose)])
  bindings.set(context, { form, ticketId, dispose, refresh: () => { restoredDraft = false; schedule() } })
  schedule()
  return dispose
}
