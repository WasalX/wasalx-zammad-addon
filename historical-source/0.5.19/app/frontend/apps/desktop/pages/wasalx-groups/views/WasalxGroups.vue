<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (c) 2026 WasalX -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'

import CommonButton from '#desktop/components/CommonButton/CommonButton.vue'
import CommonLoader from '#desktop/components/CommonLoader/CommonLoader.vue'
import LayoutContent from '#desktop/components/layout/LayoutContent.vue'

type Group = {
  id: string
  name: string
  access_scope: 'MY' | 'TEAM' | 'UNASSIGNED' | 'ALL'
  unread_count: number
  send_available: boolean
}
type Message = {
  id: string
  external_message_id?: string | null
  participant_name: string | null
  message_text: string | null
  from_me: boolean
  provider_timestamp: string
  latest_mutation: 'EDITED' | 'REVOKED' | null
  quote_allowed: boolean
  ticket_creatable: boolean
  linked_to_ticket: boolean
  source_kind?: 'MESSAGE' | 'DELIVERY'
  delivery_state?: 'QUEUED' | 'CLAIMED' | 'SENDING' | 'SENT' | 'DELIVERED' | 'READ' | 'FAILED_RETRYABLE' | 'FAILED_TERMINAL' | 'OUTCOME_UNKNOWN' | null
  media_filename?: string | null
  media_mime_type?: string | null
  media_available?: boolean
}
type ComposerAttachment = { id: number, filename: string, size: number, contentType: string }
type Participant = { id: string, name: string }
type Ticket = {
  ticket_id: string
  ticket_number: string
  reference: string
  state_category: 'OPEN' | 'CLOSED'
  links: Array<{ article_id: string | null, message_id: string }>
}
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
const quotedMessage = ref<Message | null>(null)
const sending = ref(false)
const sendFailure = ref<string | null>(null)
const attachments = ref<ComposerAttachment[]>([])
const attachmentInput = ref<HTMLInputElement | null>(null)
const uploadCacheId = ref(globalThis.crypto.randomUUID())
const uploading = ref(false)
const recording = ref(false)
let recorder: MediaRecorder | undefined
let recordingStream: MediaStream | undefined
const ticketFilter = ref<'OPEN' | 'CLOSED' | 'ALL'>('OPEN')
const ticketLimit = ref(25)
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
let refreshCount = 0

const selectedGroup = computed(() => groups.value.find((group) => group.id === selectedGroupId.value) ?? null)
const visibleGroups = computed(() => filter.value === 'ALL'
  ? groups.value
  : groups.value.filter((group) => group.access_scope === filter.value))
const chronologicalMessages = computed(() => [...messages.value].reverse())
const visibleTickets = computed(() => tickets.value
  .filter((ticket) => ticketFilter.value === 'ALL' || ticket.state_category === ticketFilter.value)
  .slice(0, ticketLimit.value))
const filteredTicketCount = computed(() => tickets.value.filter((ticket) => ticketFilter.value === 'ALL' || ticket.state_category === ticketFilter.value).length)

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
  if (!response.ok) throw new Error(__('WhatsApp groups could not be loaded.'))
  return response.json() as Promise<T>
}

const uploadFiles = async (files: File[]) => {
  if (!files.length || uploading.value) return
  if (attachments.value.length + files.length > 10) { sendFailure.value = __('You can attach up to 10 files.'); return }
  uploading.value = true
  sendFailure.value = null
  try {
    for (const file of files) {
      if (!acceptedMediaType(file.type) || file.size < 1 || file.size > mediaLimit(file.type)) throw new Error(__('This file type or size is not supported.'))
      const body = new FormData(); body.append('File', file, file.name)
      const headers = new Headers({ Accept: 'application/json' })
      const token = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content
      if (token) headers.set('X-CSRF-Token', token)
      const response = await fetch(`/api/v1/upload_caches/${uploadCacheId.value}`, { method: 'POST', body, headers, credentials: 'same-origin' })
      if (!response.ok) throw new Error(__('Attachment could not be uploaded.'))
      const value = await response.json() as { data?: { id?: number, filename?: string, size?: number, contentType?: string } }
      const item = value.data
      if (!item || !Number.isSafeInteger(item.id) || !item.filename || !Number.isSafeInteger(item.size) || !item.contentType) throw new Error(__('Attachment could not be uploaded.'))
      attachments.value.push({ id: item.id!, filename: item.filename, size: item.size!, contentType: item.contentType })
    }
  } catch (error) {
    sendFailure.value = error instanceof Error ? error.message : __('Attachment could not be uploaded.')
  } finally {
    uploading.value = false
    if (attachmentInput.value) attachmentInput.value.value = ''
  }
}

const chooseFiles = (event: Event) => void uploadFiles([...((event.target as HTMLInputElement).files ?? [])])
const mentionNumber = (id: string) => id.slice(0, id.indexOf('@'))
const closeMentions = () => {
  mentionOpen.value = false
  mentionOptions.value = []
  mentionActiveIndex.value = 0
  mentionRequest?.abort()
  if (mentionTimer) window.clearTimeout(mentionTimer)
}
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
const startVoice = async () => {
  if (recording.value || uploading.value) return
  try {
    recordingStream = await navigator.mediaDevices.getUserMedia({ audio: true })
    const mimeType = ['audio/webm;codecs=opus', 'audio/webm'].find((type) => MediaRecorder.isTypeSupported(type))
    if (!mimeType) throw new Error(__('Voice recording is not supported in this browser.'))
    const chunks: Blob[] = []
    recorder = new MediaRecorder(recordingStream, { mimeType })
    recorder.addEventListener('dataavailable', (event) => { if (event.data.size) chunks.push(event.data) })
    recorder.addEventListener('stop', () => {
      recordingStream?.getTracks().forEach((track) => track.stop()); recordingStream = undefined; recording.value = false
      const blob = new Blob(chunks, { type: 'audio/webm' })
      if (blob.size) void uploadFiles([new File([blob], `voice-${new Date().toISOString().replace(/[:.]/g, '-')}.webm`, { type: 'audio/webm' })])
    }, { once: true })
    recorder.start(); recording.value = true
  } catch (error) {
    recordingStream?.getTracks().forEach((track) => track.stop()); recordingStream = undefined; recording.value = false
    sendFailure.value = error instanceof Error ? error.message : __('Microphone access was not available. You can attach an audio file instead.')
  }
}
const stopVoice = () => recorder?.state === 'recording' && recorder.stop()

const loadGroups = async (quiet = false) => {
  if (!quiet) loadingGroups.value = true
  try {
    const value = await json<Group[]>('/api/v1/wasalx/group_workspace/groups')
    groups.value = value
    failure.value = null
    const requested = typeof route.query.group === 'string' ? route.query.group : null
    if (!selectedGroupId.value || !value.some((group) => group.id === selectedGroupId.value)) {
      selectedGroupId.value = value.find((group) => group.id === requested)?.id ?? value[0]?.id ?? null
    }
  } catch (error) {
    if (!quiet) failure.value = error instanceof Error ? error.message : __('WhatsApp groups could not be loaded.')
  } finally {
    loadingGroups.value = false
  }
}

const loadConversation = async (groupId: string, quiet = false, refreshTickets = true) => {
  request?.abort()
  request = new AbortController()
  if (!quiet) loadingConversation.value = true
  failure.value = null
  try {
    const [nextMessages, nextTickets] = await Promise.all([
      json<Message[]>(`/api/v1/wasalx/group_workspace/groups/${groupId}/messages?limit=50`, { signal: request.signal }),
      refreshTickets
        ? json<Ticket[]>(`/api/v1/wasalx/group_workspace/groups/${groupId}/tickets`, { signal: request.signal })
        : Promise.resolve(tickets.value),
    ])
    const currentIds = new Set(messages.value.map((message) => message.id))
    const currentExternalIds = new Set(messages.value.map((message) => message.external_message_id).filter(Boolean))
    const nearLatest = isNearLatest()
    const echoed = new Set(nextMessages.filter((message) => message.source_kind !== 'DELIVERY' && message.external_message_id)
      .map((message) => message.external_message_id))
    const retained = messages.value.filter((message) => !(message.source_kind === 'DELIVERY'
      && message.external_message_id && echoed.has(message.external_message_id)))
    messages.value = quiet
      ? [...new Map([...retained, ...nextMessages].map((message) => [message.id, message])).values()]
        .sort((left, right) => right.provider_timestamp.localeCompare(left.provider_timestamp) || right.id.localeCompare(left.id))
      : nextMessages
    tickets.value = nextTickets
    if (!quiet) ticketLimit.value = 25
    const added = quiet ? nextMessages.filter((message) => !currentIds.has(message.id)
      && (!message.external_message_id || !currentExternalIds.has(message.external_message_id))).length : 0
    if (added) {
      if (nearLatest) await scrollToLatest()
      else newMessageCount.value += added
    }
    const latest = nextMessages.find((message) => message.source_kind !== 'DELIVERY')
    if (latest) void json(`/api/v1/wasalx/group_workspace/groups/${groupId}/read`, {
      method: 'POST', body: JSON.stringify({ message_id: latest.id }), signal: request.signal,
    }).then(() => { const group = groups.value.find((item) => item.id === groupId); if (group) group.unread_count = 0 }).catch(() => undefined)
    const requestedMessage = typeof route.query.message === 'string' ? route.query.message : null
    if (requestedMessage) await showContext(requestedMessage)
  } catch (error) {
    if (!(error instanceof DOMException && error.name === 'AbortError'))
      failure.value = error instanceof Error ? error.message : __('WhatsApp group could not be loaded.')
  } finally {
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
  try {
    const beforeHeight = timeline.value?.scrollHeight ?? 0
    const older = await json<Message[]>(`/api/v1/wasalx/group_workspace/groups/${groupId}/messages?limit=50&before=${oldest.id}`)
    const known = new Set(messages.value.map((message) => message.id))
    messages.value.push(...older.filter((message) => !known.has(message.id)))
    await nextTick()
    if (timeline.value) timeline.value.scrollTop += timeline.value.scrollHeight - beforeHeight
  } finally {
    loadingOlder.value = false
  }
}

const showContext = async (messageId: string) => {
  if (!selectedGroupId.value) return
  const context = await json<Message[]>(`/api/v1/wasalx/group_workspace/groups/${selectedGroupId.value}/messages/${messageId}/context`)
  messages.value = [...context].reverse()
  highlightedMessageId.value = messageId
  await router.replace({ query: { ...route.query, group: selectedGroupId.value, message: messageId } })
  await nextTick()
  document.querySelector<HTMLElement>(`[data-message-id="${messageId}"]`)?.focus()
}

const send = async () => {
  const groupId = selectedGroupId.value
  const message = draft.value.trim()
  if (!groupId || (!message && !attachments.value.length) || sending.value || uploading.value || recording.value) return
  sending.value = true
  sendFailure.value = null
  try {
    const mentions = selectedMentionIds.value.filter((id) => new RegExp(`(^|[^0-9])@${mentionNumber(id)}(?![0-9])`, 'u').test(message))
    const queued = await json<Message>(`/api/v1/wasalx/group_workspace/groups/${groupId}/send`, {
      method: 'POST',
      body: JSON.stringify({
        message,
        reply_to_message_id: quotedMessage.value?.id,
        ...(mentions.length ? { mentions } : {}),
        ...(attachments.value.length ? { upload_cache_id: uploadCacheId.value, upload_store_ids: attachments.value.map((item) => item.id) } : {}),
        request_token: globalThis.crypto.randomUUID(),
      }),
    })
    draft.value = ''
    selectedMentionIds.value = []
    attachments.value = []
    uploadCacheId.value = globalThis.crypto.randomUUID()
    quotedMessage.value = null
    messages.value = [queued, ...messages.value.filter((message) => message.id !== queued.id)]
    await scrollToLatest()
    await loadConversation(groupId, true, false)
  } catch {
    sendFailure.value = __('Message could not be sent. Try again.')
  } finally {
    sending.value = false
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
  QUEUED: __('Sending…'), CLAIMED: __('Sending…'), SENDING: __('Sending…'), FAILED_RETRYABLE: __('Retrying…'),
  SENT: __('Sent'), DELIVERED: __('Delivered'), READ: __('Read'), FAILED_TERMINAL: __('Not sent'),
  OUTCOME_UNKNOWN: __('Delivery needs review'),
}[state || ''] || '')
const mediaUrl = (message: Message) => `/api/v1/wasalx/group_workspace/groups/${selectedGroupId.value}/messages/${message.id}/media`
const ACCEPTED_MEDIA = new Set(['image/png','image/jpeg','image/gif','image/webp','application/pdf','application/zip','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','application/vnd.openxmlformats-officedocument.presentationml.presentation','audio/ogg','audio/mpeg','audio/mp4','audio/webm','video/mp4'])
const acceptedMediaType = (value: string) => ACCEPTED_MEDIA.has(value.split(';', 1)[0]?.toLowerCase() || '')
const mediaLimit = (value: string) => value.startsWith('video/') ? 50_000_000 : value.startsWith('image/') ? 15_000_000 : 25_000_000

const isNearLatest = () => !timeline.value || timeline.value.scrollHeight - timeline.value.scrollTop - timeline.value.clientHeight < 120
const scrollToLatest = async () => {
  await nextTick()
  timeline.value?.scrollTo?.({
    top: timeline.value.scrollHeight,
    behavior: globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth',
  })
  newMessageCount.value = 0
}

watch(selectedGroupId, (groupId) => {
  messages.value = []
  tickets.value = []
  newMessageCount.value = 0
  selectedMentionIds.value = []
  closeMentions()
  if (groupId) void loadConversation(groupId)
})

watch(ticketFilter, () => { ticketLimit.value = 25 })

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
  request?.abort()
  if (recorder?.state === 'recording') recorder.stop()
  recordingStream?.getTracks().forEach((track) => track.stop())
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
            <div class="mb-5 flex justify-center">
              <CommonButton variant="none" class="text-blue-900 hover:underline focus-visible:outline-blue-900 dark:text-blue-600 dark:focus-visible:outline-blue-600" :disabled="loadingOlder" @click="loadOlder">{{ loadingOlder ? $t('Loading…') : $t('Load earlier messages') }}</CommonButton>
            </div>
            <ol class="space-y-3">
              <li v-for="message in chronologicalMessages" :key="message.id" :data-message-id="message.id" tabindex="-1"
                class="wasalx-message max-w-[44rem] rounded-xl border p-4 outline-none focus-visible:ring-2 focus-visible:ring-blue-800"
                :class="[message.from_me ? 'ms-auto border-blue-200 bg-blue-50 dark:border-blue-900 dark:bg-blue-950' : 'border-neutral-100 bg-white dark:border-gray-900 dark:bg-gray-600', highlightedMessageId === message.id ? 'ring-2 ring-yellow-300' : '']">
                <div class="mb-2 flex flex-wrap items-center justify-between gap-2 text-xs text-gray-100 dark:text-neutral-400">
                  <strong class="text-black dark:text-white" dir="auto">{{ message.from_me ? $t('Agent') : (message.participant_name || $t('Participant')) }}</strong>
                  <time :datetime="message.provider_timestamp">{{ formatTime(message.provider_timestamp) }}</time>
                </div>
                <p v-if="message.message_text" class="whitespace-pre-wrap text-sm leading-6" dir="auto">{{ message.message_text }}</p>
                <p v-else-if="!message.media_filename" class="text-sm leading-6">{{ $t('Unsupported message') }}</p>
                <div v-if="message.media_filename" class="mt-3 overflow-hidden rounded-lg border border-neutral-100 bg-neutral-50 p-3 text-sm dark:border-gray-900 dark:bg-gray-500">
                  <img v-if="message.media_available && message.media_mime_type?.startsWith('image/')" :src="mediaUrl(message)" :alt="message.media_filename" loading="lazy" class="mb-2 max-h-80 max-w-full rounded-lg object-contain" />
                  <video v-else-if="message.media_available && message.media_mime_type?.startsWith('video/')" :src="mediaUrl(message)" controls preload="metadata" class="mb-2 max-h-80 max-w-full rounded-lg" />
                  <audio v-else-if="message.media_available && message.media_mime_type?.startsWith('audio/')" :src="mediaUrl(message)" controls preload="none" class="mb-2 max-w-full" />
                  <strong class="block truncate" dir="auto">{{ message.media_filename }}</strong>
                  <span class="mt-1 block text-xs text-gray-100 dark:text-neutral-400">{{ message.media_mime_type }}</span>
                  <a v-if="message.media_available && !message.media_mime_type?.match(/^(image|audio|video)\//)" :href="mediaUrl(message)" class="mt-2 inline-block text-blue-900 hover:underline focus-visible:outline-2 focus-visible:outline-blue-900 dark:text-blue-600">{{ $t('Download file') }}</a>
                  <span v-else-if="!message.media_available" class="mt-2 block text-xs text-gray-100 dark:text-neutral-400">{{ $t('Preparing attachment…') }}</span>
                </div>
                <span v-if="message.latest_mutation === 'EDITED'" class="mt-2 block text-xs text-gray-100 dark:text-neutral-400">{{ $t('Edited') }}</span>
                <span v-if="message.delivery_state" class="mt-2 block text-xs text-gray-100 dark:text-neutral-400" role="status">{{ deliveryLabel(message.delivery_state) }}</span>
                <div class="mt-2 flex flex-wrap gap-3">
                  <button v-if="message.quote_allowed" type="button" class="text-xs text-blue-900 hover:underline focus-visible:outline-2 focus-visible:outline-blue-900 dark:text-blue-600 dark:focus-visible:outline-blue-600" @click="quotedMessage = message">{{ $t('Quote') }}</button>
                  <button v-if="message.ticket_creatable && !message.linked_to_ticket" type="button" class="text-xs text-blue-900 hover:underline focus-visible:outline-2 focus-visible:outline-blue-900 dark:text-blue-600 dark:focus-visible:outline-blue-600" @click="openTicketAction(message, 'create')">{{ $t('Create ticket') }}</button>
                  <button type="button" class="text-xs text-blue-900 hover:underline focus-visible:outline-2 focus-visible:outline-blue-900 dark:text-blue-600 dark:focus-visible:outline-blue-600" @click="openTicketAction(message, 'link')">{{ $t('Link to ticket') }}</button>
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
          <button v-if="newMessageCount" type="button"
            class="mx-auto mb-2 rounded-full bg-blue-900 px-4 py-2 text-xs font-medium text-white shadow-sm focus-visible:outline-2 focus-visible:outline-blue-900 dark:bg-blue-600 dark:text-black"
            @click="scrollToLatest">
            {{ newMessageCount === 1 ? $t('1 new message') : `${newMessageCount} ${$t('new messages')}` }}
          </button>
          <form v-if="selectedGroup?.send_available" class="border-t border-neutral-100 p-4 dark:border-gray-900" :aria-busy="sending" @submit.prevent="send">
            <div v-if="quotedMessage" class="mb-2 flex items-center justify-between gap-3 rounded-lg bg-neutral-100 px-3 py-2 text-xs dark:bg-gray-600">
              <span class="truncate" dir="auto">{{ `${$t('Replying to')}: ${quotedMessage.message_text || $t('message')}` }}</span>
              <button type="button" class="text-blue-900 hover:underline focus-visible:outline-2 focus-visible:outline-blue-900 dark:text-blue-600 dark:focus-visible:outline-blue-600" @click="quotedMessage = null">{{ $t('Cancel') }}</button>
            </div>
            <ul v-if="attachments.length" class="mb-2 flex flex-wrap gap-2" :aria-label="$t('Attachments')">
              <li v-for="attachment in attachments" :key="attachment.id" class="flex max-w-full items-center gap-2 rounded-lg bg-neutral-100 px-3 py-2 text-xs dark:bg-gray-600">
                <span class="max-w-56 truncate" dir="auto">{{ attachment.filename }}</span>
                <button type="button" class="text-blue-900 hover:underline focus-visible:outline-2 focus-visible:outline-blue-900 dark:text-blue-600" :aria-label="`${$t('Remove')} ${attachment.filename}`" @click="attachments = attachments.filter((item) => item.id !== attachment.id)">{{ $t('Remove') }}</button>
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
                    <span class="shrink-0 text-xs text-gray-100 dark:text-neutral-400" dir="ltr">{{ `+${mentionNumber(participant.id)}` }}</span>
                  </button>
                </div>
              </div>
              <CommonButton type="submit" variant="submit" size="medium" :disabled="sending || uploading || recording || (!draft.trim() && !attachments.length)">{{ sending ? $t('Sending…') : $t('Send') }}</CommonButton>
            </div>
            <div class="mt-2 flex flex-wrap items-center gap-2">
              <input ref="attachmentInput" class="sr-only" type="file" multiple :aria-label="$t('Attach files')"
                accept="image/png,image/jpeg,image/gif,image/webp,application/pdf,application/zip,application/vnd.openxmlformats-officedocument.wordprocessingml.document,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,application/vnd.openxmlformats-officedocument.presentationml.presentation,audio/ogg,audio/mpeg,audio/mp4,audio/webm,video/mp4"
                @change="chooseFiles" />
              <CommonButton type="button" variant="none" size="small" :disabled="uploading || recording || attachments.length >= 10" @click="attachmentInput?.click()">
                {{ uploading ? $t('Uploading…') : $t('Attach files') }}
              </CommonButton>
              <CommonButton v-if="!recording" type="button" variant="none" size="small" :disabled="uploading" @click="startVoice">{{ $t('Record voice') }}</CommonButton>
              <CommonButton v-else type="button" variant="submit" size="small" @click="stopVoice">{{ $t('Stop recording') }}</CommonButton>
              <span v-if="recording" class="text-xs text-red-500" role="status">{{ $t('Recording…') }}</span>
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
          <CommonButton v-if="visibleTickets.length < filteredTicketCount" class="mt-4 w-full" variant="none" size="medium" @click="ticketLimit += 25">
            {{ $t('Load more tickets') }}
          </CommonButton>
        </aside>
      </div>
    </div>
  </LayoutContent>
</template>

<style scoped>
.wasalx-message { animation: wasalx-message-in 160ms ease-out; }
@keyframes wasalx-message-in { from { transform: translateY(0.25rem); } }
@media (prefers-reduced-motion: reduce) {
  .wasalx-message { animation: none; }
  .wasalx-timeline { scroll-behavior: auto; }
}
</style>
