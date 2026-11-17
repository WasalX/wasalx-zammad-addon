<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com> -->
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
    reference: string
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
  delivery: { state: string; updated_at: string | null }
  portal_url: string | null
  can_retry: boolean
}

const props = defineProps<TicketSidebarProps>()
const emit = defineEmits<TicketSidebarEmits>()
const scrollPosition = ref(0)
const panel = ref<WasalxPanel | null>(null)
const loading = ref(false)
const failure = ref<string | null>(null)
let request: AbortController | undefined

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

watch(ticketId, load, { immediate: true })
onBeforeUnmount(() => request?.abort())

const connectionTone = computed(() => tone(panel.value?.connection.state))
const deliveryTone = computed(() => tone(panel.value?.delivery.state))
const caseHeadingId = computed(() => `wasalx-case-heading-${panel.value?.ticket.id || 'loading'}`)

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

const label = (value?: string | null) =>
  value ? value.toLowerCase().replaceAll('_', ' ').replace(/^./, (letter) => letter.toUpperCase()) : __('Unknown')

const timestamp = (value?: string | null) => {
  if (!value) return __('Not observed')
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? __('Not observed') : new Intl.DateTimeFormat(undefined, {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date)
}

const validPanel = (value: WasalxPanel, expectedTicketId: number) =>
  Boolean(
    value &&
      value.ticket?.id === expectedTicketId &&
      value.ticket.reference &&
      value.group?.name &&
      value.connection?.id &&
      value.connection.state &&
      value.delivery?.state,
  )
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
                {{ panel.ticket.reference }} · #{{ panel.ticket.number }}
              </p>
            </div>
          </div>

          <dl class="grid grid-cols-2">
            <div class="border-b border-e border-neutral-200 p-3 dark:border-gray-800">
              <dt class="text-xs text-neutral-500 dark:text-neutral-400">{{ $t('Connection') }}</dt>
              <dd class="mt-1">
                <span class="wasalx-state" :class="connectionTone">
                  <span aria-hidden="true" />{{ label(panel.connection.state) }}
                </span>
              </dd>
            </div>
            <div class="border-b border-neutral-200 p-3 dark:border-gray-800">
              <dt class="text-xs text-neutral-500 dark:text-neutral-400">{{ $t('Delivery') }}</dt>
              <dd class="mt-1">
                <span class="wasalx-state" :class="deliveryTone">
                  <span aria-hidden="true" />{{ label(panel.delivery.state) }}
                </span>
              </dd>
            </div>
            <div class="border-e border-neutral-200 p-3 dark:border-gray-800">
              <dt class="text-xs text-neutral-500 dark:text-neutral-400">{{ $t('Provider') }}</dt>
              <dd class="mt-1 font-mono text-xs font-medium">{{ panel.connection.provider || $t('Unavailable') }}</dd>
            </div>
            <div class="p-3">
              <dt class="text-xs text-neutral-500 dark:text-neutral-400">{{ $t('Binding') }}</dt>
              <dd class="mt-1 text-xs font-medium">{{ label(panel.connection.binding_state) }}</dd>
            </div>
          </dl>
        </section>

        <section
          class="rounded-lg border border-neutral-200 p-3 dark:border-gray-800"
          :aria-label="$t('WasalX activity')"
        >
          <dl class="flex flex-col gap-3 text-xs">
            <div>
              <dt class="text-neutral-500 dark:text-neutral-400">{{ $t('Last provider event') }}</dt>
              <dd class="mt-1 font-mono tabular-nums">{{ timestamp(panel.connection.last_provider_event_at) }}</dd>
            </div>
            <div>
              <dt class="text-neutral-500 dark:text-neutral-400">{{ $t('Last heartbeat') }}</dt>
              <dd class="mt-1 font-mono tabular-nums">{{ timestamp(panel.connection.last_heartbeat_at) }}</dd>
            </div>
            <div>
              <dt class="text-neutral-500 dark:text-neutral-400">{{ $t('Rule version') }}</dt>
              <dd class="mt-1 font-mono">{{ panel.ticket.rule_version || $t('Not recorded') }}</dd>
            </div>
          </dl>
        </section>

        <div
          v-if="!panel.connection.available"
          class="rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-900 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-100"
          role="status"
        >
          {{ $t('The control plane could not verify this connection. Delivery state may be delayed.') }}
        </div>

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
        <p v-else class="m-0 text-xs text-neutral-500 dark:text-neutral-400">
          {{ $t('Administrative access is available to authorized supervisors.') }}
        </p>
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

</style>
