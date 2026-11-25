<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (c) 2026 WasalX -->
<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'

import TicketSidebarContent from '#desktop/pages/ticket/components/TicketSidebar/TicketSidebarContent.vue'
import TicketSidebarWrapper from '#desktop/pages/ticket/components/TicketSidebar/TicketSidebarWrapper.vue'
import type {
  TicketSidebarEmits,
  TicketSidebarProps,
} from '#desktop/pages/ticket/types/sidebar.ts'

type WasalxPanel = {
  ticket: {
    id: number
    number: string
    reference: string | null
    correlation_status: string | null
    rule_version: string | null
  }
  group: { id: string; name: string }
  connection: {
    id: string
    provider: string | null
    state: string
    binding_state: string
    available: boolean
    last_heartbeat_at: string | null
    last_provider_event_at: string | null
  }
  delivery: {
    id: string | null
    article_id: string | null
    state: string
    updated_at: string | null
    retry_allowed: boolean
    retry_requires_confirmation: boolean
  }
  portal_url: string | null
  message_context: { group_id: string; message_id: string } | null
  message_contexts: Array<{ group_id: string; message_id: string }>
  message_contexts_truncated: boolean
  can_retry: boolean
}

const props = defineProps<TicketSidebarProps>()
const emit = defineEmits<TicketSidebarEmits>()
const scrollPosition = ref(0)
const panel = ref<WasalxPanel | null>(null)
const loading = ref(false)
const failure = ref<string | null>(null)
const retryPhase = ref<'idle' | 'pending' | 'success' | 'failed'>('idle')
const retryFailure = ref<string | null>(null)
const retryConfirmation = ref('')
const retryToken = ref<string | null>(null)
let request: AbortController | undefined
let retryGeneration = 0
const countFormatter = new Intl.NumberFormat(document.documentElement.lang || undefined)

const ticketId = computed(() => props.context.ticket?.value?.internalId)

const load = async () => {
  request?.abort()
  panel.value = null
  failure.value = null
  if (!ticketId.value) {
    emit('hide')
    return
  }

  loading.value = true
  const currentRequest = new AbortController()
  request = currentRequest
  try {
    const response = await fetch(`/api/v1/wasalx/tickets/${ticketId.value}/panel`, {
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
      signal: currentRequest.signal,
    })
    if (request !== currentRequest) return
    if (response.status === 404) {
      emit('hide')
      return
    }
    if (!response.ok) throw new Error(__('WasalX status could not be loaded.'))
    const value = (await response.json()) as WasalxPanel
    if (!validPanel(value, ticketId.value)) throw new Error(__('WasalX returned an invalid status.'))

    panel.value = value
    emit('show')
  } catch (error) {
    if (
      request !== currentRequest ||
      (error instanceof DOMException && error.name === 'AbortError')
    )
      return
    failure.value = error instanceof Error ? error.message : __('WasalX status could not be loaded.')
    // A non-404 response means this is a WasalX ticket. Keep its recovery
    // surface visible rather than turning a dependency outage into a dead end.
    emit('show')
  } finally {
    if (request === currentRequest) {
      request = undefined
      loading.value = false
    }
  }
}

watch(ticketId, () => {
  retryGeneration += 1
  retryPhase.value = 'idle'
  retryFailure.value = null
  retryConfirmation.value = ''
  retryToken.value = null
  void load()
}, { immediate: true })
onBeforeUnmount(() => {
  retryGeneration += 1
  request?.abort()
})

const connectionTone = computed(() => tone(panel.value?.connection.state))
const deliveryTone = computed(() => tone(panel.value?.delivery.state))
const retryEligible = computed(() => Boolean(
  panel.value?.can_retry &&
  panel.value.delivery.retry_allowed &&
  panel.value.delivery.id &&
  panel.value.delivery.article_id,
))
const retryConfirmationValid = computed(() =>
  !panel.value?.delivery.retry_requires_confirmation || retryConfirmation.value === 'RETRY',
)
const caseHeadingId = computed(() => `wasalx-case-heading-${panel.value?.ticket.id || 'loading'}`)
const formatCount = (value: number) => countFormatter.format(value)

const tone = (state?: string) => {
  if (state === 'WORKING' || state === 'SENT' || state === 'DELIVERED' || state === 'READ')
    return 'text-green-600 dark:text-green-400'
  if (
    state === 'FAILED' ||
    state === 'FAILED_TERMINAL' ||
    state === 'REVOKED' ||
    state === 'OUTCOME_UNKNOWN' ||
    state === 'BLOCKED'
  )
    return 'text-red-600 dark:text-red-400'
  if (state === 'DEGRADED' || state === 'ACTION_REQUIRED' || state === 'FAILED_RETRYABLE')
    return 'text-amber-700 dark:text-amber-400'
  return 'text-neutral-600 dark:text-neutral-400'
}

const label = (value?: string | null) => {
  const labels: Record<string, string> = {
    PROVISIONING: __('Provisioning'),
    AWAITING_AUTH: __('Waiting for authentication'),
    CONNECTING: __('Connecting'),
    WORKING: __('Connected'),
    DEGRADED: __('Needs attention'),
    ACTION_REQUIRED: __('Action required'),
    FAILED: __('Failed'),
    PAUSED: __('Paused'),
    REVOKED: __('Revoked'),
    UNAVAILABLE: __('Unavailable'),
    QUEUED: __('Queued'),
    CLAIMED: __('Preparing'),
    SENDING: __('Sending…'),
    SENT: __('Sent'),
    DELIVERED: __('Delivered'),
    READ: __('Read'),
    FAILED_RETRYABLE: __('Ready to retry'),
    FAILED_TERMINAL: __('Failed'),
    OUTCOME_UNKNOWN: __('Delivery needs review'),
    BLOCKED: __('Blocked'),
    NOT_SENT: __('Not sent'),
  }

  return value ? labels[value] || __('Unknown') : __('Unknown')
}

const timestamp = (value?: string | null) => {
  if (!value) return __('Not observed')
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? __('Not observed') : new Intl.DateTimeFormat(document.documentElement.lang || undefined, {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date)
}

const validPanel = (value: WasalxPanel, expectedTicketId: number) =>
  Boolean(
    value &&
      value.ticket?.id === expectedTicketId &&
      value.group?.name &&
      value.connection?.id &&
      value.connection.state &&
      value.delivery?.state &&
      (value.message_context === null || (
        uuid(value.message_context.group_id) && uuid(value.message_context.message_id)
      )) && Array.isArray(value.message_contexts) && value.message_contexts.length <= 100
      && value.message_contexts.every((context) => uuid(context?.group_id) && uuid(context?.message_id))
      && typeof value.message_contexts_truncated === 'boolean',
  )

const uuid = (value?: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value || '')

const retryDelivery = async () => {
  const value = panel.value
  if (
    !value ||
    !retryEligible.value ||
    !retryConfirmationValid.value ||
    !value.delivery.id ||
    !value.delivery.article_id
  ) return

  const generation = ++retryGeneration
  const currentTicketId = value.ticket.id
  const currentDeliveryId = value.delivery.id
  const isCurrentRetry = () => generation === retryGeneration && ticketId.value === currentTicketId
    && panel.value?.delivery.id === currentDeliveryId
  retryPhase.value = 'pending'
  retryFailure.value = null
  retryToken.value ||= globalThis.crypto.randomUUID()
  try {
    const csrfToken = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content
    const response = await fetch(
      `/api/v1/wasalx/tickets/${value.ticket.id}/articles/${value.delivery.article_id}/retry`,
      {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          Accept: 'application/json',
          'Content-Type': 'application/json',
          ...(csrfToken ? { 'X-CSRF-Token': csrfToken } : {}),
        },
        body: JSON.stringify({
          delivery_id: value.delivery.id,
          request_token: retryToken.value,
          confirm_outcome_unknown: value.delivery.retry_requires_confirmation,
        }),
      },
    )
    if (!response.ok) throw new Error(__('The delivery could not be queued for retry.'))

    if (!isCurrentRetry()) return
    retryPhase.value = 'success'
    retryToken.value = null
    retryConfirmation.value = ''
    await load()
  } catch (error) {
    if (!isCurrentRetry()) return
    retryPhase.value = 'failed'
    retryFailure.value = error instanceof Error
      ? error.message
      : __('The delivery could not be queued for retry.')
  }
}
</script>

<template>
  <TicketSidebarWrapper
    :key="sidebar"
    :sidebar="sidebar"
    :sidebar-plugin="sidebarPlugin"
    :selected="selected"
  >
    <TicketSidebarContent
      v-model="scrollPosition"
      :title="sidebarPlugin.title"
      :icon="sidebarPlugin.icon"
      icon-class="text-green-500 dark:text-green-400"
    >
      <div
        v-if="loading"
        class="flex flex-col gap-3"
        aria-busy="true"
        :aria-label="$t('Loading WasalX operations')"
      >
        <div class="h-24 animate-pulse rounded-lg bg-neutral-100 dark:bg-gray-900" />
        <div class="h-36 animate-pulse rounded-lg bg-neutral-100 dark:bg-gray-900" />
      </div>

      <div
        v-else-if="failure"
        class="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-900 dark:border-red-900 dark:bg-red-950 dark:text-red-100"
        role="alert"
      >
        <strong class="block">{{ $t('WasalX status is unavailable') }}</strong>
        <p class="my-2 text-xs opacity-80">{{ $t(failure) }}</p>
        <button
          type="button"
          class="rounded-md border border-current px-3 py-1.5 text-xs font-medium"
          @click="load"
        >
          {{ $t('Retry status check') }}
        </button>
      </div>

      <template v-else-if="panel">
        <section
          class="overflow-hidden rounded-lg border border-neutral-200 bg-white shadow-sm dark:border-gray-800 dark:bg-gray-950"
          :aria-labelledby="caseHeadingId"
          data-test-id="wasalx-ticket-panel"
          data-wasalx-ticket-sidebar
        >
          <div class="flex items-center gap-3 border-b border-neutral-200 p-3 dark:border-gray-800">
            <span
              class="grid size-9 place-items-center rounded-lg bg-violet-100 font-mono text-xs font-bold text-violet-800 dark:bg-violet-950 dark:text-violet-200"
              aria-hidden="true"
            >WX</span>
            <div class="min-w-0 grow">
              <h3 :id="caseHeadingId" class="truncate text-sm font-semibold">
                {{ panel.group.name }}
              </h3>
              <p class="truncate font-mono text-xs text-neutral-500 dark:text-neutral-400">
                <template v-if="panel.ticket.reference">{{ panel.ticket.reference }} · </template>#{{ panel.ticket.number }}
              </p>
            </div>
          </div>

          <dl class="grid grid-cols-2">
            <div class="border-e border-neutral-200 p-3 dark:border-gray-800">
              <dt class="text-xs text-neutral-500 dark:text-neutral-400">{{ $t('Connection') }}</dt>
              <dd class="mt-1">
                <span class="wasalx-state" :class="connectionTone">
                  <span aria-hidden="true" />{{ label(panel.connection.state) }}
                </span>
              </dd>
            </div>
            <div class="p-3">
              <dt class="text-xs text-neutral-500 dark:text-neutral-400">{{ $t('Delivery') }}</dt>
              <dd class="mt-1">
                <span class="wasalx-state" :class="deliveryTone">
                  <span aria-hidden="true" />{{ label(panel.delivery.state) }}
                </span>
              </dd>
            </div>
          </dl>
        </section>

        <section
          class="rounded-lg border border-neutral-200 p-3 dark:border-gray-800"
          :aria-label="$t('WasalX activity')"
        >
          <dl class="flex flex-col gap-3 text-xs">
            <div>
              <dt class="text-neutral-500 dark:text-neutral-400">{{ $t('Last activity') }}</dt>
              <dd class="mt-1 font-mono tabular-nums">{{ timestamp(panel.connection.last_provider_event_at) }}</dd>
            </div>
          </dl>
        </section>

        <nav v-if="panel.message_contexts.length" class="space-y-2" :aria-label="$t('Linked WhatsApp messages')">
          <RouterLink
            :to="{ path: '/wasalx/groups', query: { group: panel.message_contexts[0].group_id, message: panel.message_contexts[0].message_id } }"
            class="flex min-h-10 items-center justify-center rounded-md border border-neutral-300 px-3 text-sm font-medium text-neutral-950 no-underline hover:bg-neutral-100 focus-visible:outline-2 focus-visible:outline-offset-2 dark:border-gray-700 dark:text-white dark:hover:bg-gray-900"
          >
            {{ $t('Show triggering message') }}
          </RouterLink>
          <details v-if="panel.message_contexts.length > 1 || panel.message_contexts_truncated" class="group text-sm">
            <summary class="min-h-9 cursor-pointer rounded-md px-2 py-2 font-medium text-neutral-700 hover:bg-neutral-100 focus-visible:outline-2 focus-visible:outline-offset-2 dark:text-neutral-300 dark:hover:bg-gray-900">
              <span>{{ $t('Additional linked messages') }}</span>
              <span class="ms-2 tabular-nums text-xs text-neutral-500 dark:text-neutral-400">{{ formatCount(panel.message_contexts.length - 1) }}</span>
            </summary>
            <div class="mt-1 max-h-64 overflow-y-auto ps-2">
              <ul class="space-y-1">
                <li v-for="(context, index) in panel.message_contexts.slice(1)" :key="`${context.group_id}:${context.message_id}`">
                  <RouterLink
                    :to="{ path: '/wasalx/groups', query: { group: context.group_id, message: context.message_id } }"
                    class="flex min-h-9 items-center rounded-md px-2 text-sm text-blue-900 no-underline hover:bg-neutral-100 hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-900 dark:text-blue-600 dark:hover:bg-gray-900 dark:focus-visible:outline-blue-600"
                  >
                    {{ `${$t('Show linked message')} ${index + 2}` }}
                  </RouterLink>
                </li>
              </ul>
              <p v-if="panel.message_contexts_truncated" class="px-2 py-2 text-xs text-neutral-600 dark:text-neutral-400">
                {{ $t('More linked messages are available in the group conversation.') }}
              </p>
            </div>
          </details>
        </nav>

        <div
          v-if="!panel.connection.available"
          class="rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-900 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-100"
          role="status"
        >
          {{ $t('We could not verify this WhatsApp connection. Delivery updates may be delayed.') }}
        </div>

        <section
          v-if="retryEligible"
          class="rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-950 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-100"
          :aria-busy="retryPhase === 'pending'"
          data-test-id="wasalx-delivery-retry"
        >
          <strong class="block">{{ $t('Delivery needs attention') }}</strong>
          <p id="wasalx-retry-warning" class="my-2">
            {{ panel.delivery.retry_requires_confirmation
              ? $t('Delivery could not be confirmed. Check the WhatsApp group before retrying to avoid a duplicate message.')
              : $t('This delivery can be safely queued for another attempt.') }}
          </p>
          <label
            v-if="panel.delivery.retry_requires_confirmation"
            class="mb-2 block"
          >
            <span class="mb-1 block font-medium">{{ $t('Type RETRY to confirm') }}</span>
            <input
              v-model="retryConfirmation"
              type="text"
              autocomplete="off"
              class="min-h-10 w-full rounded-md border border-amber-400 bg-white px-3 font-mono text-neutral-950 focus-visible:outline-2 focus-visible:outline-offset-2 dark:border-amber-700 dark:bg-gray-950 dark:text-white"
              :disabled="retryPhase === 'pending'"
              aria-describedby="wasalx-retry-warning"
            >
          </label>
          <p
            v-if="retryFailure"
            id="wasalx-retry-error"
            class="my-2 text-red-700 dark:text-red-300"
            role="alert"
          >
            {{ $t(retryFailure) }}
          </p>
          <button
            type="button"
            class="min-h-10 rounded-md bg-amber-950 px-3 font-medium text-white disabled:cursor-not-allowed disabled:opacity-50 dark:bg-amber-100 dark:text-amber-950"
            :disabled="retryPhase === 'pending' || !retryConfirmationValid"
            @click="retryDelivery"
          >
            {{ retryPhase === 'pending' ? $t('Queueing retry…') : $t('Retry delivery') }}
          </button>
        </section>

        <p
          v-if="retryPhase === 'success'"
          class="m-0 rounded-lg border border-green-200 bg-green-50 p-3 text-xs text-green-900 dark:border-green-900 dark:bg-green-950 dark:text-green-100"
          role="status"
        >
          {{ $t('Delivery was queued for retry.') }}
        </p>

        <a
          v-if="panel.portal_url"
          :href="panel.portal_url"
          target="_blank"
          rel="noopener noreferrer"
          class="flex min-h-10 items-center justify-center rounded-md bg-neutral-950 px-3 text-sm font-medium text-white no-underline hover:bg-neutral-800 focus-visible:outline-2 focus-visible:outline-offset-2 dark:bg-white dark:text-neutral-950 dark:hover:bg-neutral-200"
        >
          {{ $t('Open in WasalX') }}
          <span class="ms-2" aria-hidden="true">↗</span>
        </a>
      </template>
    </TicketSidebarContent>
  </TicketSidebarWrapper>
</template>

<style scoped>
.wasalx-state {
  display: inline-flex;
  align-items: center;
  gap: 0.375rem;
  border: 1px solid currentColor;
  border-radius: 9999px;
  padding: 0.125rem 0.5rem;
  font-size: 0.75rem;
  font-weight: 600;
}

.wasalx-state > span {
  width: 0.375rem;
  height: 0.375rem;
  border-radius: 9999px;
  background: currentColor;
}

@media (max-width: 64rem) {
  :global(.grid:has(> #content-sidebar [data-wasalx-ticket-sidebar])) {
    grid-template-columns: minmax(0, 1fr) !important;
  }

  :global(#content-sidebar:has([data-wasalx-ticket-sidebar])) {
    position: fixed;
    inset-block: 3.5rem 0;
    inset-inline-end: 0;
    width: min(22.5rem, calc(100vw - 3.5rem));
    z-index: 30;
    background: var(--color-white);
    box-shadow: 0 1rem 3rem rgb(0 0 0 / 18%);
  }
}

</style>
