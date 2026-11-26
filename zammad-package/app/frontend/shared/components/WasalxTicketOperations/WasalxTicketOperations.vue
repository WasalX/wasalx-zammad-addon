<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (c) 2026 WasalX -->
<script setup lang="ts">
import type { WasalxTicketOperationsState } from './useWasalxTicketOperations.ts'

const props = defineProps<{ operations: WasalxTicketOperationsState }>()
const {
  panel,
  loading,
  failure,
  retryPhase,
  retryFailure,
  retryConfirmation,
  connectionTone,
  deliveryTone,
  retryEligible,
  emailRetryEligible,
  retryConfirmationValid,
  caseHeadingId,
  formatCount,
  label,
  timestamp,
  load,
  retryDelivery,
  retryEmailRouting,
} = props.operations
const { state: serviceWindowState, text: serviceWindowText } = props.operations.serviceWindow
</script>

<template>
  <div class="space-y-3 bg-white text-neutral-950 dark:bg-gray-950 dark:text-white">
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
    v-else-if="failure && !panel"
    class="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-900 dark:border-red-900 dark:bg-red-950 dark:text-red-100"
    role="alert"
  >
    <strong class="block">{{ $t('WasalX status is unavailable') }}</strong>
    <p class="my-2 text-xs opacity-80">{{ $t(failure) }}</p>
    <button
      type="button"
      class="rounded-md border border-current px-3 py-1.5 text-xs font-medium"
      @click="load()"
    >
      {{ $t('Retry status check') }}
    </button>
  </div>

  <template v-else-if="panel">
    <div
      v-if="failure"
      class="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-900 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-100"
      role="status"
    >
      <span>{{ $t('WasalX status could not be loaded.') }}</span>
      <button type="button" class="rounded-md border border-current px-3 py-1.5 font-medium" @click="load(true)">
        {{ $t('Retry status check') }}
      </button>
    </div>
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
          <p class="truncate font-mono text-xs text-neutral-600 dark:text-neutral-400">
            <template v-if="panel.ticket.reference">{{ panel.ticket.reference }} · </template>#{{ panel.ticket.number }}
          </p>
        </div>
      </div>

      <dl class="grid grid-cols-2">
        <div class="border-e border-neutral-200 p-3 dark:border-gray-800">
          <dt class="text-xs text-neutral-600 dark:text-neutral-400">{{ panel.email_routing ? $t('Routing') : $t('Connection') }}</dt>
          <dd class="mt-1">
            <span class="wasalx-state" :class="connectionTone">
              <span aria-hidden="true" />{{ label(panel.connection.state) }}
            </span>
          </dd>
        </div>
        <div class="p-3">
          <dt class="text-xs text-neutral-600 dark:text-neutral-400">{{ panel.email_routing ? $t('Confirmation') : $t('Delivery') }}</dt>
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
          <dt class="text-neutral-600 dark:text-neutral-400">{{ $t('Last activity') }}</dt>
          <dd class="mt-1 font-mono tabular-nums">{{ timestamp(panel.connection.last_provider_event_at) }}</dd>
        </div>
        <div v-if="serviceWindowState !== 'unknown'" data-test-id="wasalx-service-window">
          <dt class="text-neutral-600 dark:text-neutral-400">{{ $t('Customer-service window') }}</dt>
          <dd
            class="mt-1"
            :class="{
              'text-amber-700 dark:text-amber-400': serviceWindowState === 'closing',
              'text-red-700 dark:text-red-400': serviceWindowState === 'closed',
            }"
            :data-state="serviceWindowState"
          >{{ serviceWindowText }}</dd>
        </div>
        <div v-if="panel.ticket.bot_state">
          <dt class="text-neutral-600 dark:text-neutral-400">{{ $t('Conversation') }}</dt>
          <dd class="mt-1">{{ label(panel.ticket.bot_state) }}</dd>
        </div>
        <div v-if="panel.trigger_sender">
          <dt class="text-neutral-600 dark:text-neutral-400">{{ $t('Trigger sender') }}</dt>
          <dd class="mt-1">
            <span dir="auto">{{ panel.trigger_sender.sender_name || $t('WhatsApp participant') }}</span>
            <span v-if="panel.trigger_sender.sender_phone" class="ms-1 font-mono" dir="ltr">{{ panel.trigger_sender.sender_phone }}</span>
          </dd>
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
        <summary class="min-h-9 cursor-pointer rounded-md px-2 py-2 font-medium text-neutral-600 hover:bg-neutral-100 focus-visible:outline-2 focus-visible:outline-offset-2 dark:text-neutral-300 dark:hover:bg-gray-900">
          <span>{{ $t('Additional linked messages') }}</span>
          <span class="ms-2 tabular-nums text-xs text-neutral-600 dark:text-neutral-400">{{ formatCount(panel.message_contexts.length - 1) }}</span>
        </summary>
        <div class="mt-1 max-h-64 overflow-y-auto ps-2">
          <ul class="space-y-1">
            <li v-for="(context, index) in panel.message_contexts.slice(1)" :key="`${context.group_id}:${context.message_id}`">
              <RouterLink
                :to="{ path: '/wasalx/groups', query: { group: context.group_id, message: context.message_id } }"
                class="flex min-h-9 items-center rounded-md px-2 text-sm text-blue-900 no-underline hover:bg-neutral-100 hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-900 dark:text-blue-400 dark:hover:bg-gray-900 dark:focus-visible:outline-blue-400"
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
      v-if="!panel.email_routing && !panel.connection.available"
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
        class="my-2 text-red-700 dark:text-red-100"
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

    <section
      v-if="emailRetryEligible"
      class="rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-950 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-100"
      :aria-busy="retryPhase === 'pending'"
      data-test-id="wasalx-email-routing-retry"
    >
      <strong class="block">{{ $t('Email routing needs attention') }}</strong>
      <p class="my-2">{{ $t('Review the routing setup, then queue the stored decision for another attempt.') }}</p>
      <p v-if="retryFailure" class="my-2 text-red-700 dark:text-red-100" role="alert">{{ $t(retryFailure) }}</p>
      <button
        type="button"
        class="min-h-10 rounded-md bg-amber-950 px-3 font-medium text-white disabled:cursor-not-allowed disabled:opacity-50 dark:bg-amber-100 dark:text-amber-950"
        :disabled="retryPhase === 'pending'"
        @click="retryEmailRouting"
      >
        {{ retryPhase === 'pending' ? $t('Queueing retry…') : $t('Retry email routing') }}
      </button>
    </section>

    <p
      v-if="retryPhase === 'success'"
      class="m-0 rounded-lg border border-green-200 bg-green-50 p-3 text-xs text-green-900 dark:border-green-900 dark:bg-green-950 dark:text-green-100"
      role="status"
    >
      {{ panel.email_routing ? $t('Email routing was queued for retry.') : $t('Delivery was queued for retry.') }}
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
  </div>
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

@media (any-pointer: coarse) {
  button,
  a,
  input,
  summary {
    min-block-size: 44px;
  }

  button,
  a {
    min-inline-size: 44px;
  }

  a {
    display: inline-flex;
    align-items: center;
  }

  input {
    font-size: 1rem;
  }
}

</style>
