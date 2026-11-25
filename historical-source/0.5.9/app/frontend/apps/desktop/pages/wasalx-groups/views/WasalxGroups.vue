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
  participant_name: string | null
  message_text: string | null
  from_me: boolean
  provider_timestamp: string
  latest_mutation: 'EDITED' | 'REVOKED' | null
  quote_allowed: boolean
}
type Ticket = {
  ticket_id: string
  ticket_number: string
  reference: string
  article_id: string | null
  message_id: string | null
}

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
const quotedMessage = ref<Message | null>(null)
const sending = ref(false)
const sendFailure = ref<string | null>(null)
let refreshTimer: number | undefined
let request: AbortController | undefined

const selectedGroup = computed(() => groups.value.find((group) => group.id === selectedGroupId.value) ?? null)
const visibleGroups = computed(() => filter.value === 'ALL'
  ? groups.value
  : groups.value.filter((group) => group.access_scope === filter.value))
const chronologicalMessages = computed(() => [...messages.value].reverse())

const filters = [
  { value: 'MY' as const, label: __('My Groups') },
  { value: 'TEAM' as const, label: __('My Team') },
  { value: 'UNASSIGNED' as const, label: __('Unassigned') },
  { value: 'ALL' as const, label: __('All Accessible') },
]

const json = async <T,>(path: string, init?: RequestInit): Promise<T> => {
  const response = await fetch(path, {
    credentials: 'same-origin',
    headers: { Accept: 'application/json', ...(init?.body ? { 'Content-Type': 'application/json' } : {}) },
    ...init,
  })
  if (!response.ok) throw new Error(__('WhatsApp groups could not be loaded.'))
  return response.json() as Promise<T>
}

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

const loadConversation = async (groupId: string, quiet = false) => {
  request?.abort()
  request = new AbortController()
  if (!quiet) loadingConversation.value = true
  failure.value = null
  try {
    const [nextMessages, nextTickets] = await Promise.all([
      json<Message[]>(`/api/v1/wasalx/group_workspace/groups/${groupId}/messages?limit=50`, { signal: request.signal }),
      json<Ticket[]>(`/api/v1/wasalx/group_workspace/groups/${groupId}/tickets`, { signal: request.signal }),
    ])
    messages.value = nextMessages
    tickets.value = nextTickets
    const latest = nextMessages[0]
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
    const older = await json<Message[]>(`/api/v1/wasalx/group_workspace/groups/${groupId}/messages?limit=50&before=${oldest.id}`)
    messages.value.push(...older)
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
  if (!groupId || !message || sending.value) return
  sending.value = true
  sendFailure.value = null
  try {
    const csrfToken = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content
    await json(`/api/v1/wasalx/group_workspace/groups/${groupId}/send`, {
      method: 'POST',
      headers: csrfToken ? { 'X-CSRF-Token': csrfToken } : undefined,
      body: JSON.stringify({
        message,
        reply_to_message_id: quotedMessage.value?.id,
        request_token: globalThis.crypto.randomUUID(),
      }),
    })
    draft.value = ''
    quotedMessage.value = null
    await loadConversation(groupId)
  } catch {
    sendFailure.value = __('Message could not be sent. Try again.')
  } finally {
    sending.value = false
  }
}

const formatTime = (value: string) => new Intl.DateTimeFormat(undefined, {
  dateStyle: 'medium', timeStyle: 'short',
}).format(new Date(value))

watch(selectedGroupId, (groupId) => {
  messages.value = []
  tickets.value = []
  if (groupId) void loadConversation(groupId)
})

onMounted(() => {
  void loadGroups()
  refreshTimer = window.setInterval(() => {
    if (document.visibilityState === 'visible') {
      void loadGroups(true)
      if (selectedGroupId.value) void loadConversation(selectedGroupId.value, true)
    }
  }, 30_000)
})
onBeforeUnmount(() => {
  request?.abort()
  if (refreshTimer) window.clearInterval(refreshTimer)
})
</script>

<template>
  <LayoutContent name="wasalx-groups" no-padding no-scrollable>
    <div class="flex h-full min-h-0 flex-col bg-neutral-50 dark:bg-gray-500">
      <header class="flex flex-wrap items-center justify-between gap-3 border-b border-neutral-100 px-6 py-5 dark:border-gray-900">
        <div>
          <h1 class="text-xl font-semibold text-black dark:text-white">{{ $t('WhatsApp Groups') }}</h1>
          <p class="mt-1 text-sm text-stone-200 dark:text-neutral-500">{{ $t('Support conversations and related tickets in one place.') }}</p>
        </div>
        <CommonButton v-if="failure" size="medium" @click="loadGroups()">{{ $t('Try again') }}</CommonButton>
      </header>

      <CommonLoader v-if="loadingGroups" class="grow" :loading="true" size="large" />
      <div v-else-if="failure && !groups.length" class="m-auto max-w-md p-8 text-center" role="alert">
        <h2 class="text-lg font-semibold">{{ $t('WhatsApp Groups is unavailable') }}</h2>
        <p class="mt-2 text-sm text-stone-200 dark:text-neutral-500">{{ failure }}</p>
      </div>
      <div v-else class="grid min-h-0 grow grid-cols-[minmax(15rem,20rem)_minmax(0,1fr)_minmax(15rem,20rem)]">
        <aside class="flex min-h-0 flex-col border-e border-neutral-100 dark:border-gray-900" :aria-label="$t('WhatsApp groups')">
          <div class="flex flex-wrap gap-1 border-b border-neutral-100 p-3 dark:border-gray-900" role="group" :aria-label="$t('Group filters')">
            <button v-for="item in filters" :key="item.value" type="button"
              class="rounded-lg px-3 py-2 text-xs font-medium focus-visible:outline-2 focus-visible:outline-blue-800"
              :class="filter === item.value ? 'bg-blue-800 text-white' : 'text-black hover:bg-neutral-100 dark:text-white dark:hover:bg-gray-600'"
              :aria-pressed="filter === item.value" @click="filter = item.value">
              {{ item.label }}
            </button>
          </div>
          <div class="min-h-0 overflow-y-auto p-2">
            <p v-if="!visibleGroups.length" class="p-5 text-center text-sm text-stone-200 dark:text-neutral-500">{{ $t('No groups in this view.') }}</p>
            <button v-for="group in visibleGroups" :key="group.id" type="button"
              class="mb-1 flex w-full items-center justify-between gap-3 rounded-xl px-3 py-3 text-start focus-visible:outline-2 focus-visible:outline-blue-800"
              :class="selectedGroupId === group.id ? 'bg-blue-100 dark:bg-blue-900' : 'hover:bg-neutral-100 dark:hover:bg-gray-600'"
              @click="selectGroup(group)">
              <span class="min-w-0 truncate text-sm font-medium">{{ group.name }}</span>
              <span v-if="group.unread_count" class="min-w-6 rounded-full bg-blue-800 px-2 py-0.5 text-center text-xs text-white" :aria-label="`${$t('Unread messages')}: ${group.unread_count}`">{{ group.unread_count }}</span>
            </button>
          </div>
        </aside>

        <section class="flex min-h-0 min-w-0 flex-col" :aria-label="selectedGroup?.name || $t('Group conversation')">
          <div v-if="selectedGroup" class="border-b border-neutral-100 px-5 py-4 dark:border-gray-900">
            <h2 class="truncate text-base font-semibold">{{ selectedGroup.name }}</h2>
          </div>
          <CommonLoader v-if="loadingConversation" class="grow" :loading="true" size="large" />
          <div v-else-if="!selectedGroup" class="m-auto p-8 text-center text-sm text-stone-200 dark:text-neutral-500">{{ $t('Choose a group to view its conversation.') }}</div>
          <div v-else-if="!messages.length" class="m-auto p-8 text-center">
            <h3 class="font-semibold">{{ $t('No captured messages yet') }}</h3>
            <p class="mt-2 text-sm text-stone-200 dark:text-neutral-500">{{ $t('History starts when capture is enabled for this group.') }}</p>
          </div>
          <div v-else class="min-h-0 grow overflow-y-auto p-5" aria-live="polite">
            <div class="mb-5 flex justify-center">
              <CommonButton :disabled="loadingOlder" @click="loadOlder">{{ loadingOlder ? $t('Loading…') : $t('Load earlier messages') }}</CommonButton>
            </div>
            <ol class="space-y-3">
              <li v-for="message in chronologicalMessages" :key="message.id" :data-message-id="message.id" tabindex="-1"
                class="max-w-[44rem] rounded-xl border p-4 outline-none focus-visible:ring-2 focus-visible:ring-blue-800"
                :class="[message.from_me ? 'ms-auto border-blue-200 bg-blue-50 dark:border-blue-900 dark:bg-blue-950' : 'border-neutral-100 bg-white dark:border-gray-900 dark:bg-gray-600', highlightedMessageId === message.id ? 'ring-2 ring-yellow-300' : '']">
                <div class="mb-2 flex flex-wrap items-center justify-between gap-2 text-xs text-stone-200 dark:text-neutral-500">
                  <strong class="text-black dark:text-white" dir="auto">{{ message.from_me ? $t('Agent') : (message.participant_name || $t('Participant')) }}</strong>
                  <time :datetime="message.provider_timestamp">{{ formatTime(message.provider_timestamp) }}</time>
                </div>
                <p class="whitespace-pre-wrap text-sm leading-6" dir="auto">{{ message.message_text || $t('Unsupported message') }}</p>
                <span v-if="message.latest_mutation === 'EDITED'" class="mt-2 block text-xs text-stone-200 dark:text-neutral-500">{{ $t('Edited') }}</span>
                <button v-if="message.quote_allowed" type="button" class="mt-2 text-xs text-blue-800 hover:underline focus-visible:outline-2 focus-visible:outline-blue-800" @click="quotedMessage = message">{{ $t('Quote') }}</button>
              </li>
            </ol>
          </div>
          <form v-if="selectedGroup?.send_available" class="border-t border-neutral-100 p-4 dark:border-gray-900" :aria-busy="sending" @submit.prevent="send">
            <div v-if="quotedMessage" class="mb-2 flex items-center justify-between gap-3 rounded-lg bg-neutral-100 px-3 py-2 text-xs dark:bg-gray-600">
              <span class="truncate" dir="auto">{{ `${$t('Replying to')}: ${quotedMessage.message_text || $t('message')}` }}</span>
              <button type="button" class="text-blue-800 hover:underline" @click="quotedMessage = null">{{ $t('Cancel') }}</button>
            </div>
            <label class="sr-only" for="wasalx-group-message">{{ $t('Message') }}</label>
            <div class="flex items-end gap-2">
              <textarea id="wasalx-group-message" v-model="draft" rows="2" maxlength="4096" required
                class="min-h-12 grow resize-y rounded-xl border border-neutral-100 bg-white px-3 py-2 text-sm focus:border-blue-800 focus:outline-none dark:border-gray-900 dark:bg-gray-600"
                :aria-describedby="sendFailure ? 'wasalx-group-message-error' : undefined"
                :aria-invalid="sendFailure ? 'true' : undefined" :placeholder="$t('Write a group message')" />
              <CommonButton type="submit" variant="primary" size="medium" :disabled="sending">{{ sending ? $t('Sending…') : $t('Send') }}</CommonButton>
            </div>
            <p v-if="sendFailure" id="wasalx-group-message-error" class="mt-2 text-sm text-red-500" role="alert">{{ sendFailure }}</p>
          </form>
          <p v-else-if="selectedGroup" class="border-t border-neutral-100 p-4 text-sm text-stone-200 dark:border-gray-900 dark:text-neutral-500">
            {{ $t('Messaging is unavailable until the WhatsApp connection recovers.') }}
          </p>
        </section>

        <aside class="min-h-0 overflow-y-auto border-s border-neutral-100 p-4 dark:border-gray-900" :aria-label="$t('Related tickets')">
          <h2 class="text-sm font-semibold">{{ $t('Open tickets') }}</h2>
          <p v-if="!tickets.length" class="mt-4 text-sm text-stone-200 dark:text-neutral-500">{{ $t('No open tickets for this group.') }}</p>
          <article v-for="ticket in tickets" :key="ticket.ticket_id" class="mt-3 rounded-xl border border-neutral-100 p-4 dark:border-gray-900">
            <RouterLink class="font-medium text-blue-800 hover:underline" :to="`/tickets/${ticket.ticket_id}${ticket.article_id ? `#article-${ticket.article_id}` : ''}`">
              {{ `${$t('Ticket')} #${ticket.ticket_number}` }}
            </RouterLink>
            <p class="mt-1 truncate text-sm" dir="auto">{{ ticket.reference }}</p>
            <button v-if="ticket.message_id" type="button" class="mt-3 text-xs text-blue-800 hover:underline focus-visible:outline-2 focus-visible:outline-blue-800" @click="showContext(ticket.message_id)">
              {{ $t('Show triggering message') }}
            </button>
          </article>
        </aside>
      </div>
    </div>
  </LayoutContent>
</template>
