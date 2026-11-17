<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com> -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'

import CommonButton from '#desktop/components/CommonButton/CommonButton.vue'
import CommonLoader from '#desktop/components/CommonLoader/CommonLoader.vue'
import LayoutContent from '#desktop/components/layout/LayoutContent.vue'

import {
  clearGroupSendRecovery, composerRecoveryScope, readGroupSendRecovery, writeGroupSendRecovery,
  type GroupSendRecovery, type RecoveredAttachment,
} from '../composerRecovery'

type Group = {
  id: string
  name: string
  access_scope: 'MY' | 'TEAM' | 'UNASSIGNED' | 'ALL'
  unread_count: number
  send_available: boolean
  media_capabilities?: {
    accepted: Array<{ mime_type: string, maximum_bytes: number }>
    voice_recording: boolean
    maximum_files?: number
    maximum_total_bytes?: number
  }
}
type Message = {
  id: string
  external_message_id?: string | null
  delivery_id?: string | null
  quoted_external_message_id?: string | null
  participant_name: string | null
  sender_phone?: string | null
  message_text: string | null
  from_me: boolean
  provider_timestamp: string
  latest_mutation: 'EDITED' | 'REVOKED' | null
  quote_allowed: boolean
  ticket_creatable: boolean
  linked_to_ticket: boolean
  source_kind?: 'MESSAGE' | 'DELIVERY'
  delivery_state?: 'QUEUED' | 'CLAIMED' | 'SENDING' | 'SENT' | 'DELIVERED' | 'READ' | 'FAILED_RETRYABLE' | 'FAILED_TERMINAL' | 'OUTCOME_UNKNOWN' | 'BLOCKED' | null
  media_filename?: string | null
  media_mime_type?: string | null
  media_kind?: 'image' | 'video' | 'audio' | 'document' | null
  media_available?: boolean
}
type ComposerAttachment = RecoveredAttachment
type QuotedMessage = Pick<Message, 'id' | 'message_text'>
type Participant = { id: string, name: string }
type Ticket = {
  ticket_id: string
  ticket_number: string
  reference: string
  state_category: 'OPEN' | 'CLOSED'
  links: Array<{ article_id: string | null, message_id: string }>
}
type TicketPage = { items: Ticket[], next_cursor: string | null }
type TicketGroup = { id: string, name: string }
type TicketResult = { ticket_id: string, ticket_number: string, article_id: string }

const route = useRoute()
const router = useRouter()
const groups = ref<Group[]>([])
const messages = ref<Message[]>([])
const tickets = ref<Ticket[]>([])
const selectedGroupId = ref<string | null>(null)
const filter = ref<'MY' | 'TEAM' | 'UNASSIGNED' | 'ALL'>('MY')
const loadingGroups = ref(true)
const loadingConversation = ref(false)
const loadingOlder = ref(false)
const hasOlder = ref(true)
const olderFailure = ref<string | null>(null)
const failure = ref<string | null>(null)
const highlightedMessageId = ref<string | null>(null)
const draft = ref('')
const composer = ref<HTMLTextAreaElement | null>(null)
const mentionOptions = ref<Participant[]>([])
const selectedMentionIds = ref<string[]>([])
const mentionOpen = ref(false)
const mentionLoading = ref(false)
const mentionActiveIndex = ref(0)
let mentionStart = 0
let mentionEnd = 0
let mentionTimer: number | undefined
let mentionRequest: AbortController | undefined
const quotedMessage = ref<QuotedMessage | null>(null)
const sending = ref(false)
const sendFailure = ref<string | null>(null)
const attachments = ref<ComposerAttachment[]>([])
const attachmentInput = ref<HTMLInputElement | null>(null)
const uploadCacheId = ref(globalThis.crypto.randomUUID())
const uploading = ref(false)
const removingAttachmentIds = ref(new Set<number>())
const recording = ref(false)
let recordingGeneration = 0
let composerGeneration = 0
let voiceStarting = false
let unmounted = false
let activeRecording: { recorder: MediaRecorder, stream: MediaStream, groupId: string, generation: number, discard: boolean } | undefined
const ticketFilter = ref<'OPEN' | 'CLOSED' | 'ALL'>('OPEN')
const ticketLimit = ref(25)
const ticketCursor = ref<string | null>(null)
const loadingMoreTickets = ref(false)
const newMessageCount = ref(0)
const timeline = ref<HTMLElement | null>(null)
const ticketGroups = ref<TicketGroup[]>([])
const ticketActionMessage = ref<Message | null>(null)
const ticketActionMode = ref<'create' | 'link'>('create')
const ticketTitle = ref('')
const targetTicketGroupId = ref('')
const ticketNumber = ref('')
const ticketActionPending = ref(false)
const ticketActionFailure = ref<string | null>(null)
const ticketResult = ref<TicketResult | null>(null)
let refreshTimer: number | undefined
let request: AbortController | undefined
let requestGroupId: string | undefined
let retryableSend: { signature: string, token: string } | undefined
let refreshCount = 0
const recoveryScope = composerRecoveryScope(document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content)

const selectedGroup = computed(() => groups.value.find((group) => group.id === selectedGroupId.value) ?? null)
const selectedMediaCapabilities = computed(() => selectedGroup.value?.media_capabilities?.accepted ?? [])
const selectedMediaRules = computed(() => new Map(selectedMediaCapabilities.value.map((item) => [item.mime_type, item.maximum_bytes])))
const acceptedMediaTypes = computed(() => [...selectedMediaRules.value.keys()].join(','))
const maximumAttachmentFiles = computed(() => selectedGroup.value?.media_capabilities?.maximum_files ?? 10)
const maximumAttachmentBytes = computed(() => selectedGroup.value?.media_capabilities?.maximum_total_bytes ?? 250_000_000)
const attachmentBytes = computed(() => attachments.value.reduce((total, item) => total + item.size, 0))
const formatBytes = (value: number) => {
  const [unit, divisor] = value >= 1_000_000 ? ['megabyte', 1_000_000] : value >= 1_000 ? ['kilobyte', 1_000] : ['byte', 1]
  return new Intl.NumberFormat(undefined, {
    style: 'unit', unit, unitDisplay: 'short', maximumFractionDigits: 1,
  }).format(value / divisor)
}
const browserVoiceMimeType = () => typeof globalThis.MediaRecorder === 'undefined' || typeof globalThis.MediaRecorder.isTypeSupported !== 'function' ? undefined
  : ['audio/webm;codecs=opus', 'audio/webm'].find((type) => globalThis.MediaRecorder.isTypeSupported(type))
const voiceRecordingAvailable = computed(() => selectedGroup.value?.media_capabilities?.voice_recording === true
  && typeof navigator.mediaDevices?.getUserMedia === 'function' && Boolean(browserVoiceMimeType()))
const visibleGroups = computed(() => filter.value === 'ALL'
  ? groups.value
  : groups.value.filter((group) => group.access_scope === filter.value))
const chronologicalMessages = computed(() => [...messages.value].reverse())
const messagesByExternalId = computed(() => {
  const indexed = new Map<string, Message>()
  for (const message of messages.value) if (message.external_message_id) indexed.set(message.external_message_id, message)
  return indexed
})
const visibleTickets = computed(() => tickets.value
  .filter((ticket) => ticketFilter.value === 'ALL' || ticket.state_category === ticketFilter.value)
  .slice(0, ticketLimit.value))
const filteredTicketCount = computed(() => tickets.value.filter((ticket) => ticketFilter.value === 'ALL' || ticket.state_category === ticketFilter.value).length)

const mergeTickets = (current: Ticket[], incoming: Ticket[]) => {
  const merged = new Map<string, Ticket>()
  for (const ticket of [...current, ...incoming]) {
    const existing = merged.get(ticket.ticket_id)
    if (!existing) { merged.set(ticket.ticket_id, { ...ticket, links: [...ticket.links] }); continue }
    const links = new Map([...existing.links, ...ticket.links].map((link) => [`${link.message_id}:${link.article_id || ''}`, link]))
    merged.set(ticket.ticket_id, { ...ticket, links: [...links.values()] })
  }
  return [...merged.values()]
}

const filters = [
  { value: 'MY' as const, label: __('My Groups') },
  { value: 'TEAM' as const, label: __('My Team') },
  { value: 'UNASSIGNED' as const, label: __('Unassigned') },
  { value: 'ALL' as const, label: __('All Accessible') },
]
const ticketFilters = [
  { value: 'OPEN' as const, label: __('Open') },
  { value: 'CLOSED' as const, label: __('Closed') },
  { value: 'ALL' as const, label: __('All') },
]

const json = async <T,>(path: string, init?: RequestInit): Promise<T> => {
  const headers = new Headers(init?.headers)
  headers.set('Accept', 'application/json')
  if (init?.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json')
  if (init?.method && !['GET', 'HEAD'].includes(init.method.toUpperCase())) {
    const token = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content
    if (token && !headers.has('X-CSRF-Token')) headers.set('X-CSRF-Token', token)
  }
  const response = await fetch(path, {
    ...init,
    credentials: 'same-origin',
    headers,
  })
  if (!response.ok) throw Object.assign(new Error(__('WhatsApp groups could not be loaded.')), { status: response.status })
  return response.json() as Promise<T>
}

const positiveInteger = (value: unknown) => {
  const parsed = typeof value === 'number' ? value : typeof value === 'string' && /^[1-9]\d*$/u.test(value) ? Number(value) : NaN
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null
}

const destroyUploadCache = (cacheId: string) => json<{ success: true }>(`/api/v1/upload_caches/${cacheId}`, { method: 'DELETE' })
const destroyUploadCacheItem = (cacheId: string, storeId: number) => json<{ success: true }>(
  `/api/v1/upload_caches/${cacheId}/items/${storeId}`, { method: 'DELETE' },
)

const uploadFiles = async (files: File[]) => {
  if (!files.length || uploading.value) return
  const groupId = selectedGroupId.value
  const generation = composerGeneration
  const cacheId = uploadCacheId.value
  const mediaRules = new Map(selectedMediaRules.value)
  if (!groupId || !mediaRules.size) { sendFailure.value = __('Attachments are unavailable for this group.'); return }
  if (attachments.value.length + files.length > maximumAttachmentFiles.value) {
    sendFailure.value = __('You have reached the attachment limit for this group.'); return
  }
  if (attachmentBytes.value + files.reduce((total, file) => total + file.size, 0) > maximumAttachmentBytes.value) {
    sendFailure.value = __('These files exceed the total upload limit for this group.'); return
  }
  for (const file of files) {
    const mimeType = file.type.split(';', 1)[0]?.trim().toLowerCase() || ''
    const maximumBytes = mediaRules.get(mimeType)
    if (!maximumBytes || file.size < 1 || file.size > maximumBytes) {
      sendFailure.value = __('This file type or size is not supported for this group.'); return
    }
  }
  uploading.value = true
  sendFailure.value = null
  try {
    for (const file of files) {
      const body = new FormData(); body.append('File', file, file.name)
      const headers = new Headers({ Accept: 'application/json' })
      const token = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content
      if (token) headers.set('X-CSRF-Token', token)
      const response = await fetch(`/api/v1/upload_caches/${cacheId}`, { method: 'POST', body, headers, credentials: 'same-origin' })
      if (!response.ok) throw new Error(__('Attachment could not be uploaded.'))
      const value = await response.json() as { data?: { id?: unknown, filename?: string, size?: unknown, contentType?: string } }
      const item = value.data
      const id = positiveInteger(item?.id)
      const size = positiveInteger(item?.size)
      const contentType = item?.contentType?.split(';', 1)[0]?.trim().toLowerCase() || ''
      const maximumBytes = mediaRules.get(contentType)
      if (!item || id === null || !item.filename || size === null || !maximumBytes || size > maximumBytes
        || attachmentBytes.value + size > maximumAttachmentBytes.value) {
        if (id !== null) await destroyUploadCacheItem(cacheId, id).catch(() => undefined)
        throw new Error(__('Attachment could not be uploaded.'))
      }
      if (unmounted || composerGeneration !== generation || selectedGroupId.value !== groupId || uploadCacheId.value !== cacheId) {
        await destroyUploadCacheItem(cacheId, id).catch(() => undefined)
        return
      }
      attachments.value.push({ id, filename: item.filename, size, contentType })
    }
  } catch (error) {
    if (!unmounted && composerGeneration === generation && selectedGroupId.value === groupId) {
      sendFailure.value = error instanceof Error ? error.message : __('Attachment could not be uploaded.')
    }
  } finally {
    if (!unmounted && composerGeneration === generation && selectedGroupId.value === groupId) {
      uploading.value = false
      if (attachmentInput.value) attachmentInput.value.value = ''
    }
  }
}

const chooseFiles = (event: Event) => void uploadFiles([...((event.target as HTMLInputElement).files ?? [])])
const mentionNumber = (id: string) => id.slice(0, id.indexOf('@'))
const mentionIdentity = (id: string) => id.endsWith('@lid') ? __('WhatsApp ID') : `+${mentionNumber(id)}`
const usedMentions = (message: string) => selectedMentionIds.value.filter((id) =>
  new RegExp(`(^|[^0-9])@${mentionNumber(id)}(?![0-9])`, 'u').test(message))
const sendSignature = (groupId: string, message: string, mentions: string[], cacheId = uploadCacheId.value,
  stagedAttachments = attachments.value) => JSON.stringify({
  groupId,
  message,
  replyToMessageId: quotedMessage.value?.id ?? null,
  mentions,
  uploadCacheId: cacheId,
  attachments: stagedAttachments,
})
const resetComposer = () => {
  draft.value = ''
  quotedMessage.value = null
  selectedMentionIds.value = []
  attachments.value = []
  uploadCacheId.value = globalThis.crypto.randomUUID()
  retryableSend = undefined
  sendFailure.value = null
  sending.value = false
  uploading.value = false
  removingAttachmentIds.value = new Set()
}
const abandonComposer = (groupId: string | null) => {
  const cacheId = uploadCacheId.value
  const hadUpload = attachments.value.length > 0 || uploading.value
  const message = draft.value.trim()
  const mentions = usedMentions(message)
  const recovery = groupId ? readGroupSendRecovery(recoveryScope, groupId) : undefined
  const exactRecovery = Boolean(groupId && recovery && retryableSend?.token === recovery.token
    && recovery.uploadCacheId === cacheId && recovery.signature === sendSignature(groupId, message, mentions))
  composerGeneration += 1
  cancelVoiceRecording()
  closeMentions()
  if (groupId && !exactRecovery) clearGroupSendRecovery(recoveryScope, groupId)
  if (hadUpload && !exactRecovery) void destroyUploadCache(cacheId).catch(() => undefined)
  resetComposer()
}
const restoreComposer = (groupId: string) => {
  const recovery = readGroupSendRecovery(recoveryScope, groupId)
  if (!recovery) return
  const mediaRules = selectedMediaRules.value
  const valid = Boolean(recovery.message || recovery.attachments.length)
    && recovery.attachments.length <= maximumAttachmentFiles.value
    && recovery.attachments.reduce((total, item) => total + item.size, 0) <= maximumAttachmentBytes.value
    && recovery.attachments.every((item) => {
      const maximum = mediaRules.get(item.contentType)
      return Boolean(maximum && item.size > 0 && item.size <= maximum)
    })
  if (!valid) {
    clearGroupSendRecovery(recoveryScope, groupId, recovery.token)
    void destroyUploadCache(recovery.uploadCacheId).catch(() => undefined)
    return
  }
  draft.value = recovery.message
  quotedMessage.value = recovery.replyToMessage
    ? { id: recovery.replyToMessage.id, message_text: recovery.replyToMessage.messageText }
    : null
  selectedMentionIds.value = [...recovery.mentions]
  attachments.value = recovery.attachments
  uploadCacheId.value = recovery.uploadCacheId
  retryableSend = { signature: recovery.signature, token: recovery.token }
  sendFailure.value = __('Delivery could not be confirmed. Retry the unchanged message safely; it will not be sent twice.')
}
const removeAttachment = async (attachment: ComposerAttachment) => {
  const groupId = selectedGroupId.value
  const generation = composerGeneration
  const cacheId = uploadCacheId.value
  if (!groupId || removingAttachmentIds.value.has(attachment.id)) return
  removingAttachmentIds.value = new Set([...removingAttachmentIds.value, attachment.id])
  sendFailure.value = null
  try {
    await destroyUploadCacheItem(cacheId, attachment.id)
    if (unmounted || composerGeneration !== generation || selectedGroupId.value !== groupId || uploadCacheId.value !== cacheId) return
    clearGroupSendRecovery(recoveryScope, groupId)
    retryableSend = undefined
    attachments.value = attachments.value.filter((item) => item.id !== attachment.id)
  } catch {
    if (!unmounted && composerGeneration === generation && selectedGroupId.value === groupId) {
      sendFailure.value = __('Attachment could not be removed. Try again.')
    }
  } finally {
    if (!unmounted && composerGeneration === generation && selectedGroupId.value === groupId) {
      const next = new Set(removingAttachmentIds.value); next.delete(attachment.id); removingAttachmentIds.value = next
    }
  }
}
const closeMentions = () => {
  mentionOpen.value = false
  mentionOptions.value = []
  mentionActiveIndex.value = 0
  mentionRequest?.abort()
  if (mentionTimer) window.clearTimeout(mentionTimer)
}
const clearConversationState = () => {
  request?.abort()
  request = undefined
  requestGroupId = undefined
  messages.value = []
  tickets.value = []
  hasOlder.value = true
  olderFailure.value = null
  ticketCursor.value = null
  ticketLimit.value = 25
  newMessageCount.value = 0
  highlightedMessageId.value = null
  ticketActionMessage.value = null
  cancelVoiceRecording()
  closeMentions()
}
const deniedStatus = (error: unknown) => error instanceof Error && [401, 403, 404].includes(Number((error as Error & { status?: number }).status))
const mentionToken = () => {
  const end = composer.value?.selectionStart ?? draft.value.length
  const match = /(?:^|\s)@([^@\n]{0,80})$/u.exec(draft.value.slice(0, end))
  if (!match) return null
  return { start: end - (match[1]?.length ?? 0) - 1, end, query: (match[1] ?? '').trim() }
}
const loadMentions = async (groupId: string, query: string) => {
  mentionRequest?.abort(); mentionRequest = new AbortController(); mentionLoading.value = true
  try {
    const params = new URLSearchParams({ q: query })
    const value = await json<Participant[]>(`/api/v1/wasalx/group_workspace/groups/${groupId}/participants?${params}`, { signal: mentionRequest.signal })
    if (mentionOpen.value) { mentionOptions.value = value; mentionActiveIndex.value = 0 }
  } catch (error) {
    if (!(error instanceof DOMException && error.name === 'AbortError')) mentionOptions.value = []
  } finally { mentionLoading.value = false }
}
const updateMentionMenu = () => {
  const groupId = selectedGroupId.value
  const token = mentionToken()
  if (!groupId || !token) { closeMentions(); return }
  mentionStart = token.start; mentionEnd = token.end; mentionOpen.value = true
  if (mentionTimer) window.clearTimeout(mentionTimer)
  mentionTimer = window.setTimeout(() => void loadMentions(groupId, token.query), 160)
}
const selectMention = async (participant: Participant) => {
  const insertion = `@${mentionNumber(participant.id)} `
  draft.value = `${draft.value.slice(0, mentionStart)}${insertion}${draft.value.slice(mentionEnd)}`
  selectedMentionIds.value = [...new Set([...selectedMentionIds.value, participant.id])]
  closeMentions(); await nextTick()
  const cursor = mentionStart + insertion.length
  composer.value?.focus(); composer.value?.setSelectionRange(cursor, cursor)
}
const composerKeydown = (event: KeyboardEvent) => {
  if (!mentionOpen.value) return
  if (event.key === 'Escape') { event.preventDefault(); closeMentions(); return }
  if (!mentionOptions.value.length) return
  if (event.key === 'ArrowDown') { event.preventDefault(); mentionActiveIndex.value = (mentionActiveIndex.value + 1) % mentionOptions.value.length }
  else if (event.key === 'ArrowUp') { event.preventDefault(); mentionActiveIndex.value = (mentionActiveIndex.value - 1 + mentionOptions.value.length) % mentionOptions.value.length }
  else if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); void selectMention(mentionOptions.value[mentionActiveIndex.value]!) }
}
const cancelVoiceRecording = () => {
  recordingGeneration += 1
  voiceStarting = false
  const session = activeRecording
  activeRecording = undefined
  recording.value = false
  if (!session) return
  session.discard = true
  session.stream.getTracks().forEach((track) => track.stop())
  if (session.recorder.state === 'recording') session.recorder.stop()
}
const startVoice = async () => {
  if (recording.value || uploading.value || voiceStarting) return
  const groupId = selectedGroupId.value
  const generation = ++recordingGeneration
  let stream: MediaStream | undefined
  voiceStarting = true
  try {
    if (!groupId || !selectedGroup.value?.media_capabilities?.voice_recording) throw new Error(__('Voice recording is unavailable for this group.'))
    const mimeType = browserVoiceMimeType()
    if (!mimeType) throw new Error(__('Voice recording is not supported in this browser.'))
    stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    if (unmounted || generation !== recordingGeneration || selectedGroupId.value !== groupId) {
      stream.getTracks().forEach((track) => track.stop())
      return
    }
    const chunks: Blob[] = []
    const recorder = new MediaRecorder(stream, { mimeType })
    const session = { recorder, stream, groupId, generation, discard: false }
    activeRecording = session
    recorder.addEventListener('dataavailable', (event) => { if (event.data.size) chunks.push(event.data) })
    recorder.addEventListener('stop', () => {
      session.stream.getTracks().forEach((track) => track.stop())
      if (activeRecording === session) { activeRecording = undefined; recording.value = false }
      const blob = new Blob(chunks, { type: 'audio/webm' })
      if (!session.discard && !unmounted && session.generation === recordingGeneration && selectedGroupId.value === session.groupId && blob.size) {
        void uploadFiles([new File([blob], `voice-${new Date().toISOString().replace(/[:.]/g, '-')}.webm`, { type: 'audio/webm' })])
      }
    }, { once: true })
    recorder.start(); recording.value = true
  } catch {
    stream?.getTracks().forEach((track) => track.stop())
    if (generation === recordingGeneration && !unmounted) {
      recording.value = false
      sendFailure.value = __('Microphone access was not available. You can attach an audio file instead.')
    }
  } finally {
    if (generation === recordingGeneration) voiceStarting = false
  }
}
const stopVoice = () => activeRecording?.recorder.state === 'recording' && activeRecording.recorder.stop()

const loadGroups = async (quiet = false) => {
  if (!quiet) loadingGroups.value = true
  try {
    const value = await json<Group[]>('/api/v1/wasalx/group_workspace/groups')
    const previousGroupId = selectedGroupId.value
    groups.value = value
    failure.value = null
    const requested = typeof route.query.group === 'string' ? route.query.group : null
    const requestedGroup = value.find((group) => group.id === requested)
    if (!selectedGroupId.value || !value.some((group) => group.id === selectedGroupId.value)) {
      if (requestedGroup) filter.value = requestedGroup.access_scope
      const nextGroupId = requestedGroup?.id
        ?? value.find((group) => filter.value === 'ALL' || group.access_scope === filter.value)?.id
        ?? null
      if (previousGroupId && previousGroupId !== nextGroupId) clearConversationState()
      selectedGroupId.value = nextGroupId
    }
  } catch (error) {
    if (deniedStatus(error)) {
      groups.value = []
      clearConversationState()
      selectedGroupId.value = null
    }
    if (!quiet) failure.value = error instanceof Error ? error.message : __('WhatsApp groups could not be loaded.')
  } finally {
    loadingGroups.value = false
  }
}

const loadConversation = async (groupId: string, quiet = false, refreshTickets = true) => {
  if (quiet && request && requestGroupId === groupId) return
  request?.abort()
  request = new AbortController()
  requestGroupId = groupId
  const activeRequest = request
  if (!quiet) loadingConversation.value = true
  failure.value = null
  try {
    const [nextMessages, nextTicketPage] = await Promise.all([
      json<Message[]>(`/api/v1/wasalx/group_workspace/groups/${groupId}/messages?limit=50`, { signal: activeRequest.signal }),
      refreshTickets
        ? json<TicketPage>(`/api/v1/wasalx/group_workspace/groups/${groupId}/tickets?limit=100`, { signal: activeRequest.signal })
        : Promise.resolve({ items: [], next_cursor: ticketCursor.value }),
    ])
    if (activeRequest.signal.aborted || selectedGroupId.value !== groupId) return
    const currentIds = new Set(messages.value.map((message) => message.id))
    const currentExternalIds = new Set(messages.value.map((message) => message.external_message_id).filter(Boolean))
    const nearLatest = isNearLatest()
    const echoed = new Set(nextMessages.filter((message) => message.source_kind !== 'DELIVERY' && message.external_message_id)
      .map((message) => message.external_message_id))
    const echoedDeliveries = new Set(nextMessages.filter((message) => message.source_kind !== 'DELIVERY' && message.delivery_id)
      .map((message) => message.delivery_id))
    const retained = messages.value.filter((message) => !(message.source_kind === 'DELIVERY'
      && (echoedDeliveries.has(message.id) || (message.external_message_id && echoed.has(message.external_message_id)))))
    const inContext = quiet && highlightedMessageId.value !== null
    messages.value = inContext ? messages.value : quiet
      ? [...new Map([...retained, ...nextMessages].map((message) => [message.id, message])).values()]
        .sort((left, right) => right.provider_timestamp.localeCompare(left.provider_timestamp) || right.id.localeCompare(left.id))
      : nextMessages
    if (!quiet) hasOlder.value = nextMessages.length >= 50
    if (refreshTickets) {
      tickets.value = nextTicketPage.items
      ticketCursor.value = nextTicketPage.next_cursor
      ticketLimit.value = 25
    }
    const added = quiet ? nextMessages.filter((message) => !currentIds.has(message.id)
      && (!message.external_message_id || !currentExternalIds.has(message.external_message_id))
      && (!message.delivery_id || !currentIds.has(message.delivery_id))).length : 0
    if (added) {
      if (nearLatest) await scrollToLatest()
      else newMessageCount.value += added
    }
    const latest = nextMessages.find((message) => message.source_kind !== 'DELIVERY')
    if (latest && !inContext) void json(`/api/v1/wasalx/group_workspace/groups/${groupId}/read`, {
      method: 'POST', body: JSON.stringify({ message_id: latest.id }), signal: activeRequest.signal,
    }).then(() => { const group = groups.value.find((item) => item.id === groupId); if (group) group.unread_count = 0 }).catch(() => undefined)
    const requestedMessage = typeof route.query.message === 'string' ? route.query.message : null
    if (requestedMessage && highlightedMessageId.value !== requestedMessage) await showContext(requestedMessage)
  } catch (error) {
    if (!(error instanceof DOMException && error.name === 'AbortError')) {
      if (deniedStatus(error) && selectedGroupId.value === groupId) {
        groups.value = groups.value.filter((group) => group.id !== groupId)
        clearConversationState()
        const next = groups.value.find((group) => filter.value === 'ALL' || group.access_scope === filter.value)
        selectedGroupId.value = next?.id ?? null
        void router.replace({ query: { ...route.query, group: next?.id, message: undefined } })
      } else failure.value = error instanceof Error ? error.message : __('WhatsApp group could not be loaded.')
    }
  } finally {
    if (request === activeRequest) { request = undefined; requestGroupId = undefined }
    if (!quiet) loadingConversation.value = false
  }
}

const selectGroup = (group: Group) => {
  if (group.id === selectedGroupId.value) return
  selectedGroupId.value = group.id
  void router.replace({ query: { ...route.query, group: group.id, message: undefined } })
}

const loadOlder = async () => {
  const groupId = selectedGroupId.value
  const oldest = messages.value.at(-1)
  if (!groupId || !oldest || loadingOlder.value) return
  loadingOlder.value = true
  olderFailure.value = null
  try {
    const beforeHeight = timeline.value?.scrollHeight ?? 0
    const older = await json<Message[]>(`/api/v1/wasalx/group_workspace/groups/${groupId}/messages?limit=50&before=${oldest.id}`)
    const known = new Set(messages.value.map((message) => message.id))
    messages.value.push(...older.filter((message) => !known.has(message.id)))
    if (older.length < 50) hasOlder.value = false
    await nextTick()
    if (timeline.value) timeline.value.scrollTop += timeline.value.scrollHeight - beforeHeight
  } catch {
    olderFailure.value = __('Earlier messages could not be loaded. Try again.')
  } finally {
    loadingOlder.value = false
  }
}

const showContext = async (messageId: string) => {
  if (!selectedGroupId.value) return
  try {
    const context = await json<Message[]>(`/api/v1/wasalx/group_workspace/groups/${selectedGroupId.value}/messages/${messageId}/context`)
    messages.value = [...context].reverse()
    hasOlder.value = true
    olderFailure.value = null
    highlightedMessageId.value = messageId
    await router.replace({ query: { ...route.query, group: selectedGroupId.value, message: messageId } })
    await nextTick()
    document.querySelector<HTMLElement>(`[data-message-id="${messageId}"]`)?.focus()
  } catch {
    olderFailure.value = __('Linked message context could not be loaded. Try again.')
  }
}

const returnToLatest = async () => {
  const groupId = selectedGroupId.value
  if (!groupId) return
  highlightedMessageId.value = null
  newMessageCount.value = 0
  await router.replace({ query: { ...route.query, group: groupId, message: undefined } })
  await loadConversation(groupId)
  await scrollToLatest()
}

const loadMoreTickets = async () => {
  const groupId = selectedGroupId.value
  if (visibleTickets.value.length < filteredTicketCount.value) { ticketLimit.value += 25; return }
  if (!groupId || !ticketCursor.value || loadingMoreTickets.value) return
  loadingMoreTickets.value = true
  try {
    const page = await json<TicketPage>(`/api/v1/wasalx/group_workspace/groups/${groupId}/tickets?limit=100&before=${ticketCursor.value}`)
    tickets.value = mergeTickets(tickets.value, page.items)
    ticketCursor.value = page.next_cursor
    ticketLimit.value += 25
  } catch {
    failure.value = __('More tickets could not be loaded. Try again.')
  } finally { loadingMoreTickets.value = false }
}

const send = async () => {
  const groupId = selectedGroupId.value
  const message = draft.value.trim()
  if (!groupId || (!message && !attachments.value.length) || sending.value || uploading.value || recording.value) return
  const mentions = usedMentions(message)
  const stagedAttachments = [...attachments.value]
  const sentUploadCacheId = stagedAttachments.length ? uploadCacheId.value : null
  const signature = sendSignature(groupId, message, mentions, uploadCacheId.value, stagedAttachments)
  if (retryableSend && retryableSend.signature !== signature) clearGroupSendRecovery(recoveryScope, groupId, retryableSend.token)
  const requestToken = retryableSend?.signature === signature ? retryableSend.token : globalThis.crypto.randomUUID()
  retryableSend = { signature, token: requestToken }
  const recovery: GroupSendRecovery = {
    groupId, signature, token: requestToken, message,
    replyToMessage: quotedMessage.value ? { id: quotedMessage.value.id, messageText: quotedMessage.value.message_text } : null,
    mentions, uploadCacheId: uploadCacheId.value, attachments: stagedAttachments,
  }
  writeGroupSendRecovery(recoveryScope, recovery)
  sending.value = true
  sendFailure.value = null
  try {
    const queued = await json<Message>(`/api/v1/wasalx/group_workspace/groups/${groupId}/send`, {
      method: 'POST',
      body: JSON.stringify({
        message,
        reply_to_message_id: recovery.replyToMessage?.id,
        ...(mentions.length ? { mentions } : {}),
        ...(stagedAttachments.length ? { upload_cache_id: recovery.uploadCacheId, upload_store_ids: stagedAttachments.map((item) => item.id) } : {}),
        request_token: requestToken,
      }),
    })
    clearGroupSendRecovery(recoveryScope, groupId, requestToken)
    if (sentUploadCacheId) void destroyUploadCache(sentUploadCacheId).catch(() => undefined)
    if (unmounted || selectedGroupId.value !== groupId || retryableSend?.token !== requestToken) return
    sending.value = false
    retryableSend = undefined
    draft.value = ''
    selectedMentionIds.value = []
    attachments.value = []
    uploadCacheId.value = globalThis.crypto.randomUUID()
    quotedMessage.value = null
    const staged = stagedAttachments[0]
    const optimistic = staged && !queued.message_text && !queued.media_filename
      ? { ...queued, media_filename: staged.filename, media_mime_type: staged.contentType, media_available: false }
      : queued
    messages.value = [optimistic, ...messages.value.filter((message) => message.id !== optimistic.id)]
    await scrollToLatest()
    await loadConversation(groupId, true, false)
  } catch (error) {
    const status = error instanceof Error ? Number((error as Error & { status?: number }).status) : NaN
    const outcomeKnown = Number.isFinite(status) && status < 500
    if (outcomeKnown) clearGroupSendRecovery(recoveryScope, groupId, requestToken)
    if (!unmounted && selectedGroupId.value === groupId && retryableSend?.token === requestToken) {
      sending.value = false
      if (outcomeKnown) retryableSend = undefined
      sendFailure.value = outcomeKnown
        ? __('Message could not be sent. Check it and try again.')
        : __('Delivery could not be confirmed. Retry the unchanged message safely; it will not be sent twice.')
    }
  } finally {
    if (!unmounted && selectedGroupId.value === groupId && retryableSend?.token === requestToken) sending.value = false
  }
}

const openTicketAction = async (message: Message, mode: 'create' | 'link') => {
  ticketActionMessage.value = message
  ticketActionMode.value = mode
  ticketActionFailure.value = null
  ticketResult.value = null
  if (mode === 'create') {
    ticketTitle.value = `${selectedGroup.value?.name || __('WhatsApp group')} — ${__('WhatsApp message')}`
    if (!ticketGroups.value.length) {
      try {
        ticketGroups.value = await json<TicketGroup[]>('/api/v1/wasalx/group_workspace/ticket_groups')
        targetTicketGroupId.value ||= ticketGroups.value[0]?.id ?? ''
      } catch {
        ticketActionFailure.value = __('Ticket groups could not be loaded.')
      }
    }
  }
}

const submitTicketAction = async () => {
  const groupId = selectedGroupId.value
  const message = ticketActionMessage.value
  if (!groupId || !message || ticketActionPending.value) return
  ticketActionPending.value = true
  ticketActionFailure.value = null
  try {
    const creating = ticketActionMode.value === 'create'
    const result = await json<TicketResult>(
      `/api/v1/wasalx/group_workspace/groups/${groupId}/messages/${message.id}/${creating ? 'tickets' : 'ticket_links'}`,
      {
        method: 'POST',
        body: JSON.stringify(creating
          ? { target_group_id: targetTicketGroupId.value, title: ticketTitle.value, request_token: globalThis.crypto.randomUUID() }
          : { ticket_number: ticketNumber.value, request_token: globalThis.crypto.randomUUID() }),
      },
    )
    ticketResult.value = result
    ticketActionMessage.value = null
    ticketNumber.value = ''
    await loadConversation(groupId)
  } catch {
    ticketActionFailure.value = ticketActionMode.value === 'create'
      ? __('Ticket could not be created. Check the details and try again.')
      : __('Message could not be linked. Check the ticket number and try again.')
  } finally {
    ticketActionPending.value = false
  }
}

const formatTime = (value: string) => new Intl.DateTimeFormat(undefined, {
  dateStyle: 'medium', timeStyle: 'short',
}).format(new Date(value))

const deliveryLabel = (state: Message['delivery_state']) => ({
  QUEUED: __('Queued'), CLAIMED: __('Sending…'), SENDING: __('Sending…'), FAILED_RETRYABLE: __('Retrying…'),
  SENT: __('Sent'), DELIVERED: __('Delivered'), READ: __('Read'), FAILED_TERMINAL: __('Not sent'),
  OUTCOME_UNKNOWN: __('Delivery needs review'),
  BLOCKED: __('Waiting for previous message'),
}[state || ''] || '')
const mediaKind = (message: Message) => message.media_kind
  || (message.media_mime_type?.startsWith('image/') ? 'image'
    : message.media_mime_type?.startsWith('video/') ? 'video'
      : message.media_mime_type?.startsWith('audio/') ? 'audio'
        : (message.media_filename || message.media_mime_type) ? 'document' : null)
const mediaTypeLabel = (message: Message) => ({
  image: __('Image'), video: __('Video'), audio: __('Audio'), document: __('Document'),
}[mediaKind(message) || ''] || __('Attachment'))
const mediaDisplayName = (message: Message) => message.media_filename || mediaTypeLabel(message)
const hasMedia = (message: Message) => message.latest_mutation !== 'REVOKED' && mediaKind(message) !== null
const displayMessageText = (message: Message) => message.latest_mutation === 'REVOKED' ? __('Message deleted') : message.message_text
const unavailableMediaLabel = (message: Message) => message.source_kind !== 'DELIVERY'
  ? __('Attachment is unavailable.')
  : ({
  FAILED_RETRYABLE: __('Attachment is waiting to retry.'),
  FAILED_TERMINAL: __('Attachment was not sent.'),
  OUTCOME_UNKNOWN: __('Attachment delivery needs review.'),
  BLOCKED: __('Attachment is waiting for the previous message.'),
  SENT: __('Attachment is no longer available.'),
  DELIVERED: __('Attachment is no longer available.'),
  READ: __('Attachment is no longer available.'),
}[message.delivery_state || ''] || __('Preparing attachment…'))
const mediaUrl = (message: Message) => `/api/v1/wasalx/group_workspace/groups/${selectedGroupId.value}/messages/${message.id}/media`
const quotedPreview = (message: Message) => {
  const quoted = message.quoted_external_message_id ? messagesByExternalId.value.get(message.quoted_external_message_id) : null
  if (!quoted) return __('Quoted message unavailable')
  return displayMessageText(quoted)?.trim() || (hasMedia(quoted) ? mediaDisplayName(quoted) : __('Unsupported message'))
}

const isNearLatest = () => !timeline.value || timeline.value.scrollHeight - timeline.value.scrollTop - timeline.value.clientHeight < 120
const scrollToLatest = async () => {
  await nextTick()
  timeline.value?.scrollTo?.({
    top: timeline.value.scrollHeight,
    behavior: globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth',
  })
  newMessageCount.value = 0
}

watch(selectedGroupId, (groupId, previousGroupId) => {
  abandonComposer(previousGroupId ?? null)
  clearConversationState()
  if (groupId) {
    restoreComposer(groupId)
    void loadConversation(groupId)
  }
})

watch(ticketFilter, () => { ticketLimit.value = 25 })
watch(filter, () => {
  if (visibleGroups.value.some((group) => group.id === selectedGroupId.value)) return
  const next = visibleGroups.value[0]
  selectedGroupId.value = next?.id ?? null
  void router.replace({ query: { ...route.query, group: next?.id, message: undefined } })
})

onMounted(() => {
  void loadGroups()
  refreshTimer = window.setInterval(() => {
    if (document.visibilityState === 'visible') {
      refreshCount += 1
      const refreshSupportingData = refreshCount % 6 === 0
      if (refreshSupportingData) void loadGroups(true)
      if (selectedGroupId.value) void loadConversation(selectedGroupId.value, true, refreshSupportingData)
    }
  }, 5_000)
})
onBeforeUnmount(() => {
  abandonComposer(selectedGroupId.value)
  unmounted = true
  request?.abort()
  cancelVoiceRecording()
  mentionRequest?.abort()
  if (mentionTimer) window.clearTimeout(mentionTimer)
  if (refreshTimer) window.clearInterval(refreshTimer)
})
</script>

<template>
  <LayoutContent name="wasalx-groups" no-padding no-scrollable>
    <div class="flex h-full min-h-0 flex-col bg-neutral-50 dark:bg-gray-500">
      <header class="flex flex-wrap items-center justify-between gap-3 border-b border-neutral-100 px-6 py-5 dark:border-gray-900">
        <div>
          <h1 class="text-xl font-semibold text-black dark:text-white">{{ $t('WhatsApp Groups') }}</h1>
          <p class="mt-1 text-sm text-gray-100 dark:text-neutral-400">{{ $t('Support conversations and related tickets in one place.') }}</p>
        </div>
        <CommonButton v-if="failure" variant="none" size="medium" class="text-blue-900 hover:underline focus-visible:outline-blue-900 dark:text-blue-600 dark:focus-visible:outline-blue-600" @click="loadGroups()">{{ $t('Try again') }}</CommonButton>
      </header>

      <CommonLoader v-if="loadingGroups" class="grow" :loading="true" size="large" />
      <div v-else-if="failure && !groups.length" class="m-auto max-w-md p-8 text-center" role="alert">
        <h2 class="text-lg font-semibold">{{ $t('WhatsApp Groups is unavailable') }}</h2>
        <p class="mt-2 text-sm text-gray-100 dark:text-neutral-400">{{ failure }}</p>
      </div>
      <div v-else class="grid min-h-0 grow grid-cols-[minmax(15rem,20rem)_minmax(0,1fr)_minmax(15rem,20rem)]">
        <aside class="flex min-h-0 flex-col border-e border-neutral-100 dark:border-gray-900" :aria-label="$t('WhatsApp groups')">
          <div class="flex flex-wrap gap-1 border-b border-neutral-100 p-3 dark:border-gray-900" role="group" :aria-label="$t('Group filters')">
            <button v-for="item in filters" :key="item.value" type="button"
              class="rounded-lg px-3 py-2 text-xs font-medium focus-visible:outline-2 focus-visible:outline-blue-900 dark:focus-visible:outline-blue-600"
              :class="filter === item.value ? 'bg-blue-900 text-white dark:bg-blue-600 dark:text-black' : 'text-black hover:bg-neutral-100 dark:text-white dark:hover:bg-gray-600'"
              :aria-pressed="filter === item.value" @click="filter = item.value">
              {{ item.label }}
            </button>
          </div>
          <div class="min-h-0 overflow-y-auto p-2">
            <p v-if="!visibleGroups.length" class="p-5 text-center text-sm text-gray-100 dark:text-neutral-400">{{ $t('No groups in this view.') }}</p>
            <button v-for="group in visibleGroups" :key="group.id" type="button"
              class="mb-1 flex w-full items-center justify-between gap-3 rounded-xl px-3 py-3 text-start focus-visible:outline-2 focus-visible:outline-blue-900 dark:focus-visible:outline-blue-600"
              :class="selectedGroupId === group.id ? 'bg-blue-100 dark:bg-blue-900' : 'hover:bg-neutral-100 dark:hover:bg-gray-600'"
              @click="selectGroup(group)">
              <span class="min-w-0 truncate text-sm font-medium">{{ group.name }}</span>
              <span v-if="group.unread_count" class="min-w-6 rounded-full bg-blue-900 px-2 py-0.5 text-center text-xs text-white dark:bg-blue-600 dark:text-black" :aria-label="`${$t('Unread messages')}: ${group.unread_count}`">{{ group.unread_count }}</span>
            </button>
          </div>
        </aside>

        <section class="flex min-h-0 min-w-0 flex-col" :aria-label="selectedGroup?.name || $t('Group conversation')">
          <div v-if="selectedGroup" class="border-b border-neutral-100 px-5 py-4 dark:border-gray-900">
            <h2 class="truncate text-base font-semibold">{{ selectedGroup.name }}</h2>
            <p v-if="ticketResult" class="mt-2 text-sm text-green-700" role="status">
              {{ $t('Ticket updated.') }}
              <RouterLink class="font-medium text-blue-900 underline dark:text-blue-600" :to="`/tickets/${ticketResult.ticket_id}#article-${ticketResult.article_id}`">
                {{ `${$t('Open ticket')} #${ticketResult.ticket_number}` }}
              </RouterLink>
            </p>
          </div>
          <CommonLoader v-if="loadingConversation" class="grow" :loading="true" size="large" />
          <div v-else-if="!selectedGroup" class="m-auto p-8 text-center text-sm text-gray-100 dark:text-neutral-400">{{ $t('Choose a group to view its conversation.') }}</div>
          <div v-else-if="!messages.length" class="m-auto p-8 text-center">
            <h3 class="font-semibold">{{ $t('No captured messages yet') }}</h3>
            <p class="mt-2 text-sm text-gray-100 dark:text-neutral-400">{{ $t('History starts when capture is enabled for this group.') }}</p>
          </div>
          <div v-else ref="timeline" class="wasalx-timeline min-h-0 grow overflow-y-auto p-5"
            role="log" :aria-label="$t('Group conversation')" aria-live="polite" aria-relevant="additions text" :aria-busy="loadingOlder">
            <div v-if="hasOlder" class="mb-5 flex justify-center">
              <CommonButton variant="none" class="text-blue-900 hover:underline focus-visible:outline-blue-900 dark:text-blue-600 dark:focus-visible:outline-blue-600" :disabled="loadingOlder" @click="loadOlder">{{ loadingOlder ? $t('Loading…') : $t('Load earlier messages') }}</CommonButton>
            </div>
            <p v-if="olderFailure" class="mb-4 text-center text-sm text-red-500" role="alert">{{ olderFailure }}</p>
            <ol class="space-y-3">
              <li v-for="message in chronologicalMessages" :key="message.id" :data-message-id="message.id" tabindex="-1"
                class="wasalx-message max-w-[44rem] rounded-xl border p-4 outline-none focus-visible:ring-2 focus-visible:ring-blue-800"
                :class="[message.from_me ? 'ms-auto border-blue-200 bg-blue-50 dark:border-blue-900 dark:bg-blue-950' : 'border-neutral-100 bg-white dark:border-gray-900 dark:bg-gray-600', highlightedMessageId === message.id ? 'ring-2 ring-yellow-300' : '']">
                <div class="mb-2 flex flex-wrap items-center justify-between gap-2 text-xs text-gray-100 dark:text-neutral-400">
                  <span class="min-w-0">
                    <strong class="block truncate text-black dark:text-white" dir="auto">{{ message.from_me ? (message.participant_name || $t('Sent from WhatsApp')) : (message.participant_name || $t('Participant')) }}</strong>
                    <span v-if="message.sender_phone" class="mt-0.5 block" dir="auto">{{ message.from_me ? $t('Sent through') : $t('WhatsApp contact') }} · <bdi dir="ltr">{{ message.sender_phone }}</bdi></span>
                    <span v-else-if="!message.from_me" class="mt-0.5 block">{{ $t('Mobile unavailable from WhatsApp') }}</span>
                  </span>
                  <time :datetime="message.provider_timestamp">{{ formatTime(message.provider_timestamp) }}</time>
                </div>
                <blockquote v-if="message.quoted_external_message_id" class="mb-3 rounded-lg bg-neutral-100 px-3 py-2 text-xs dark:bg-gray-500" :aria-label="$t('Quoted message')">
                  <span class="block font-medium">{{ $t('Replying to') }}</span>
                  <p class="mt-1 line-clamp-2 text-gray-100 dark:text-neutral-400" dir="auto">{{ quotedPreview(message) }}</p>
                </blockquote>
                <p v-if="displayMessageText(message)" class="whitespace-pre-wrap text-sm leading-6" dir="auto">{{ displayMessageText(message) }}</p>
                <p v-else-if="!hasMedia(message) && message.source_kind !== 'DELIVERY'" class="text-sm leading-6">{{ $t('Unsupported message') }}</p>
                <div v-if="hasMedia(message)" class="mt-3 overflow-hidden rounded-lg border border-neutral-100 bg-neutral-50 p-3 text-sm dark:border-gray-900 dark:bg-gray-500">
                  <img v-if="message.media_available && message.media_mime_type?.startsWith('image/')" :src="mediaUrl(message)" :alt="mediaDisplayName(message)" loading="lazy" class="mb-2 max-h-80 max-w-full rounded-lg object-contain" />
                  <video v-else-if="message.media_available && message.media_mime_type?.startsWith('video/')" :src="mediaUrl(message)" :aria-label="mediaDisplayName(message)" controls preload="metadata" class="mb-2 max-h-80 max-w-full rounded-lg" />
                  <audio v-else-if="message.media_available && message.media_mime_type?.startsWith('audio/')" :src="mediaUrl(message)" :aria-label="mediaDisplayName(message)" controls preload="none" class="mb-2 max-w-full" />
                  <strong class="block truncate" dir="auto">{{ mediaDisplayName(message) }}</strong>
                  <span v-if="message.media_filename" class="mt-1 block text-xs text-gray-100 dark:text-neutral-400">{{ mediaTypeLabel(message) }}</span>
                  <a v-if="message.media_available && !message.media_mime_type?.match(/^(image|audio|video)\//)" :href="mediaUrl(message)" class="mt-2 inline-block text-blue-900 hover:underline focus-visible:outline-2 focus-visible:outline-blue-900 dark:text-blue-600">{{ $t('Download file') }}</a>
                  <span v-else-if="!message.media_available" class="mt-2 block text-xs text-gray-100 dark:text-neutral-400">{{ unavailableMediaLabel(message) }}</span>
                </div>
                <span v-if="message.latest_mutation === 'EDITED'" class="mt-2 block text-xs text-gray-100 dark:text-neutral-400">{{ $t('Edited') }}</span>
                <span v-if="message.delivery_state" class="mt-2 block text-xs text-gray-100 dark:text-neutral-400" role="status">{{ deliveryLabel(message.delivery_state) }}</span>
                <div class="mt-2 flex flex-wrap gap-3">
                  <button v-if="message.quote_allowed && message.latest_mutation !== 'REVOKED'" type="button" class="text-xs text-blue-900 hover:underline focus-visible:outline-2 focus-visible:outline-blue-900 dark:text-blue-600 dark:focus-visible:outline-blue-600" @click="quotedMessage = message">{{ $t('Quote') }}</button>
                  <button v-if="message.ticket_creatable && !message.linked_to_ticket" type="button" class="text-xs text-blue-900 hover:underline focus-visible:outline-2 focus-visible:outline-blue-900 dark:text-blue-600 dark:focus-visible:outline-blue-600" @click="openTicketAction(message, 'create')">{{ $t('Create ticket') }}</button>
                  <button v-if="!message.from_me" type="button" class="text-xs text-blue-900 hover:underline focus-visible:outline-2 focus-visible:outline-blue-900 dark:text-blue-600 dark:focus-visible:outline-blue-600" @click="openTicketAction(message, 'link')">{{ $t('Link to ticket') }}</button>
                </div>
                <form v-if="ticketActionMessage?.id === message.id" class="mt-3 rounded-lg border border-neutral-100 bg-neutral-50 p-3 dark:border-gray-900 dark:bg-gray-500" :aria-busy="ticketActionPending" @submit.prevent="submitTicketAction">
                  <div class="flex items-center justify-between gap-3">
                    <strong class="text-sm">{{ ticketActionMode === 'create' ? $t('Create a ticket from this message') : $t('Link this message to a ticket') }}</strong>
                    <button type="button" class="text-xs text-blue-900 hover:underline focus-visible:outline-2 focus-visible:outline-blue-900 dark:text-blue-600 dark:focus-visible:outline-blue-600" @click="ticketActionMessage = null">{{ $t('Cancel') }}</button>
                  </div>
                  <template v-if="ticketActionMode === 'create'">
                    <label class="mt-3 block text-xs font-medium" :for="`wasalx-ticket-title-${message.id}`">{{ $t('Ticket title') }}</label>
                    <input :id="`wasalx-ticket-title-${message.id}`" v-model="ticketTitle" required maxlength="200"
                      class="mt-1 w-full rounded-lg border border-neutral-100 bg-white px-3 py-2 text-sm dark:border-gray-900 dark:bg-gray-600" />
                    <label class="mt-3 block text-xs font-medium" :for="`wasalx-ticket-group-${message.id}`">{{ $t('Support team') }}</label>
                    <select :id="`wasalx-ticket-group-${message.id}`" v-model="targetTicketGroupId" required
                      class="mt-1 w-full rounded-lg border border-neutral-100 bg-white px-3 py-2 text-sm dark:border-gray-900 dark:bg-gray-600">
                      <option v-for="group in ticketGroups" :key="group.id" :value="group.id">{{ group.name }}</option>
                    </select>
                  </template>
                  <template v-else>
                    <label class="mt-3 block text-xs font-medium" :for="`wasalx-ticket-number-${message.id}`">{{ $t('Ticket number') }}</label>
                    <input :id="`wasalx-ticket-number-${message.id}`" v-model="ticketNumber" required inputmode="numeric" pattern="[1-9][0-9]{0,15}"
                      class="mt-1 w-full rounded-lg border border-neutral-100 bg-white px-3 py-2 text-sm dark:border-gray-900 dark:bg-gray-600" />
                  </template>
                  <p v-if="ticketActionFailure" class="mt-2 text-sm text-red-500" role="alert">{{ ticketActionFailure }}</p>
                  <CommonButton class="mt-3" type="submit" variant="submit" size="medium" :disabled="ticketActionPending || (ticketActionMode === 'create' && !ticketGroups.length)">
                    {{ ticketActionPending ? $t('Saving…') : (ticketActionMode === 'create' ? $t('Create ticket') : $t('Link message')) }}
                  </CommonButton>
                </form>
              </li>
            </ol>
          </div>
          <button v-if="newMessageCount || highlightedMessageId" type="button"
            class="mx-auto mb-2 rounded-full bg-blue-900 px-4 py-2 text-xs font-medium text-white shadow-sm focus-visible:outline-2 focus-visible:outline-blue-900 dark:bg-blue-600 dark:text-black"
            @click="highlightedMessageId ? returnToLatest() : scrollToLatest()">
            {{ highlightedMessageId ? $t('Return to latest') : (newMessageCount === 1 ? $t('1 new message') : `${newMessageCount} ${$t('new messages')}`) }}
          </button>
          <form v-if="selectedGroup?.send_available" class="border-t border-neutral-100 p-4 dark:border-gray-900" :aria-busy="sending" @submit.prevent="send">
            <div v-if="quotedMessage" class="mb-2 flex items-center justify-between gap-3 rounded-lg bg-neutral-100 px-3 py-2 text-xs dark:bg-gray-600">
              <span class="truncate" dir="auto">{{ `${$t('Replying to')}: ${quotedMessage.message_text || $t('message')}` }}</span>
              <button type="button" class="text-blue-900 hover:underline focus-visible:outline-2 focus-visible:outline-blue-900 dark:text-blue-600 dark:focus-visible:outline-blue-600" @click="quotedMessage = null">{{ $t('Cancel') }}</button>
            </div>
            <ul v-if="attachments.length" class="mb-2 flex flex-wrap gap-2" :aria-label="$t('Attachments')">
              <li v-for="attachment in attachments" :key="attachment.id" class="flex max-w-full items-center gap-2 rounded-lg bg-neutral-100 px-3 py-2 text-xs dark:bg-gray-600">
                <span class="max-w-56 truncate" dir="auto">{{ attachment.filename }}</span>
                <button type="button" class="text-blue-900 hover:underline focus-visible:outline-2 focus-visible:outline-blue-900 disabled:opacity-60 dark:text-blue-600"
                  :disabled="removingAttachmentIds.has(attachment.id)" :aria-label="`${$t('Remove')} ${attachment.filename}`" @click="removeAttachment(attachment)">
                  {{ removingAttachmentIds.has(attachment.id) ? $t('Removing…') : $t('Remove') }}
                </button>
              </li>
            </ul>
            <label class="sr-only" for="wasalx-group-message">{{ $t('Message') }}</label>
            <div class="flex items-end gap-2">
              <div class="relative grow">
                <textarea id="wasalx-group-message" ref="composer" v-model="draft" rows="2" maxlength="4096"
                  class="min-h-12 w-full resize-y rounded-xl border border-neutral-100 bg-white px-3 py-2 text-sm focus:border-blue-800 focus:outline-none dark:border-gray-900 dark:bg-gray-600"
                  :aria-describedby="sendFailure ? 'wasalx-group-message-error' : undefined"
                  :aria-invalid="sendFailure ? 'true' : undefined" :placeholder="$t('Write a group message')"
                  role="combobox" aria-autocomplete="list" :aria-expanded="mentionOpen" aria-controls="wasalx-mention-options"
                  :aria-activedescendant="mentionOpen && mentionOptions.length ? `wasalx-mention-${mentionActiveIndex}` : undefined"
                  @input="updateMentionMenu" @click="updateMentionMenu" @keydown="composerKeydown" />
                <div v-if="mentionOpen" id="wasalx-mention-options" role="listbox" :aria-label="$t('Mention a participant')"
                  class="absolute inset-x-0 bottom-full z-10 mb-2 max-h-56 overflow-y-auto rounded-xl border border-neutral-100 bg-white p-1 shadow-lg dark:border-gray-900 dark:bg-gray-600">
                  <p v-if="mentionLoading" class="px-3 py-2 text-xs text-gray-100 dark:text-neutral-400" role="status">{{ $t('Finding participants…') }}</p>
                  <p v-else-if="!mentionOptions.length" class="px-3 py-2 text-xs text-gray-100 dark:text-neutral-400">{{ $t('No matching participants.') }}</p>
                  <button v-for="(participant, index) in mentionOptions" :id="`wasalx-mention-${index}`" :key="participant.id"
                    type="button" role="option" :aria-selected="mentionActiveIndex === index"
                    class="flex w-full items-center justify-between gap-3 rounded-lg px-3 py-2 text-start text-sm focus-visible:outline-2 focus-visible:outline-blue-900 dark:focus-visible:outline-blue-600"
                    :class="mentionActiveIndex === index ? 'bg-blue-100 dark:bg-blue-900' : 'hover:bg-neutral-100 dark:hover:bg-gray-500'"
                    @mouseenter="mentionActiveIndex = index" @mousedown.prevent @click="selectMention(participant)">
                    <span class="truncate" dir="auto">{{ participant.name }}</span>
                    <span class="shrink-0 text-xs text-gray-100 dark:text-neutral-400" dir="ltr">{{ mentionIdentity(participant.id) }}</span>
                  </button>
                </div>
              </div>
              <CommonButton type="submit" variant="submit" size="medium" :disabled="sending || uploading || recording || (!draft.trim() && !attachments.length)">{{ sending ? $t('Sending…') : $t('Send') }}</CommonButton>
            </div>
            <div class="mt-2 flex flex-wrap items-center gap-2">
              <template v-if="selectedMediaCapabilities.length">
                <input ref="attachmentInput" class="sr-only" type="file" multiple :aria-label="$t('Attach files')"
                  :accept="acceptedMediaTypes" @change="chooseFiles" />
                <CommonButton type="button" variant="none" size="small" :disabled="uploading || recording || attachments.length >= maximumAttachmentFiles" @click="attachmentInput?.click()">
                  {{ uploading ? $t('Uploading…') : $t('Attach files') }}
                </CommonButton>
              </template>
              <CommonButton v-if="voiceRecordingAvailable && !recording" type="button" variant="none" size="small" :disabled="uploading" @click="startVoice">{{ $t('Record voice') }}</CommonButton>
              <CommonButton v-else-if="recording" type="button" variant="submit" size="small" @click="stopVoice">{{ $t('Stop recording') }}</CommonButton>
              <span v-if="recording" class="text-xs text-red-500" role="status">{{ $t('Recording…') }}</span>
              <span v-else-if="attachments.length" class="text-xs text-gray-100 dark:text-neutral-400" role="status">
                {{ `${formatBytes(attachmentBytes)} / ${formatBytes(maximumAttachmentBytes)}` }}
              </span>
            </div>
            <p v-if="sendFailure" id="wasalx-group-message-error" class="mt-2 text-sm text-red-500" role="alert">{{ sendFailure }}</p>
          </form>
          <p v-else-if="selectedGroup" class="border-t border-neutral-100 p-4 text-sm text-gray-100 dark:border-gray-900 dark:text-neutral-400">
            {{ $t('Messaging is unavailable until the WhatsApp connection recovers.') }}
          </p>
        </section>

        <aside class="min-h-0 overflow-y-auto border-s border-neutral-100 p-4 dark:border-gray-900" :aria-label="$t('Related tickets')">
          <h2 class="text-sm font-semibold">{{ $t('Related tickets') }}</h2>
          <div class="mt-3 flex gap-1" role="group" :aria-label="$t('Ticket status')">
            <button v-for="item in ticketFilters" :key="item.value" type="button"
              class="rounded-lg px-2.5 py-2 text-xs font-medium focus-visible:outline-2 focus-visible:outline-blue-900 dark:focus-visible:outline-blue-600"
              :class="ticketFilter === item.value ? 'bg-blue-900 text-white dark:bg-blue-600 dark:text-black' : 'hover:bg-neutral-100 dark:hover:bg-gray-600'"
              :aria-pressed="ticketFilter === item.value" @click="ticketFilter = item.value">
              {{ item.label }}
            </button>
          </div>
          <p v-if="!visibleTickets.length" class="mt-4 text-sm text-gray-100 dark:text-neutral-400">{{ $t('No tickets in this view.') }}</p>
          <article v-for="ticket in visibleTickets" :key="ticket.ticket_id" class="mt-3 rounded-xl border border-neutral-100 p-4 dark:border-gray-900">
            <RouterLink class="font-medium text-blue-900 hover:underline dark:text-blue-600" :to="`/tickets/${ticket.ticket_id}${ticket.links[0]?.article_id ? `#article-${ticket.links[0].article_id}` : ''}`">
              {{ `${$t('Ticket')} #${ticket.ticket_number}` }}
            </RouterLink>
            <p class="mt-1 truncate text-sm" dir="auto">{{ ticket.reference }}</p>
            <div v-if="ticket.links.length" class="mt-3 space-y-2">
              <button v-for="(link, index) in ticket.links" :key="link.message_id" type="button" class="block text-xs text-blue-900 hover:underline focus-visible:outline-2 focus-visible:outline-blue-900 dark:text-blue-600 dark:focus-visible:outline-blue-600" @click="showContext(link.message_id)">
                {{ ticket.links.length === 1 ? $t('Show linked message') : `${$t('Show linked message')} ${index + 1}` }}
              </button>
            </div>
          </article>
          <CommonButton v-if="visibleTickets.length < filteredTicketCount || ticketCursor" class="mt-4 w-full" variant="none" size="medium" :disabled="loadingMoreTickets" @click="loadMoreTickets">
            {{ loadingMoreTickets ? $t('Loading…') : $t('Load more tickets') }}
          </CommonButton>
        </aside>
      </div>
    </div>
  </LayoutContent>
</template>

<style scoped>
.wasalx-message { animation: wasalx-message-in 160ms ease-out; }
.wasalx-message:nth-child(n + 21) {
  content-visibility: auto;
  contain-intrinsic-block-size: auto 8rem;
}
@keyframes wasalx-message-in { from { transform: translateY(0.25rem); } }
@media (prefers-reduced-motion: reduce) {
  .wasalx-message { animation: none; }
  .wasalx-timeline { scroll-behavior: auto; }
}
</style>
