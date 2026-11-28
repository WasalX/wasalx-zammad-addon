// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX
import { computed, onBeforeUnmount, ref, watch, type Ref } from 'vue'
import { i18n } from '#shared/i18n/index.ts'
import { useWasalxServiceWindow } from './useWasalxServiceWindow.ts'
import { openWasalxTemplateDialog } from '../../entities/ticket-article/action/wasalxTemplateDialog.ts'

type WasalxPanel = {
  ticket: {
    id: number
    number: string
    reference: string | null
    correlation_status: string | null
    rule_version: string | null
    bot_state: string | null
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
  trigger_sender?: {
    sender_name: string | null
    sender_phone: string | null
    from_me: boolean
  } | null
  email_routing: {
    article_id: string
    routing_state: string
    acknowledgement_state: string | null
    retry_allowed: boolean
    updated_at: string
  } | null
  service_window_expires_at?: string | null
  can_retry: boolean
}

// Own loading in the adapter setup: desktop content mounts only after selection.
export function useWasalxTicketOperations(
  ticketId: Readonly<Ref<number | undefined>>,
  visibility: { show: () => void; hide: () => void },
) {
  const panel = ref<WasalxPanel | null>(null)
  const loading = ref(false)
  const failure = ref<string | null>(null)
  const retryPhase = ref<'idle' | 'pending' | 'success' | 'failed'>('idle')
  const retryFailure = ref<string | null>(null)
  const retryConfirmation = ref('')
  const retryToken = ref<string | null>(null)
  let request: AbortController | undefined
  let retryGeneration = 0
  const countFormatter = new Intl.NumberFormat(
    document.documentElement.lang || undefined,
  )

  const load = async (background = false) => {
    request?.abort()
    request = undefined
    if (!background) panel.value = null
    failure.value = null
    if (!ticketId.value) {
      panel.value = null
      loading.value = false
      visibility.hide()
      return
    }

    if (!background) loading.value = true
    const currentRequest = new AbortController()
    request = currentRequest
    try {
      const response = await fetch(
        `/api/v1/wasalx/tickets/${ticketId.value}/panel`,
        {
          credentials: 'same-origin',
          headers: { Accept: 'application/json' },
          signal: currentRequest.signal,
        },
      )
      if (request !== currentRequest) return
      if (response.status === 404) {
        panel.value = null
        visibility.hide()
        return
      }
      if (!response.ok)
        throw new Error(__('WasalX status could not be loaded.'))
      const value = (await response.json()) as WasalxPanel
      if (request !== currentRequest) return
      if (!validPanel(value, ticketId.value))
        throw new Error(__('WasalX returned an invalid status.'))

      panel.value = value
      visibility.show()
    } catch (error) {
      if (
        request !== currentRequest ||
        (error instanceof DOMException && error.name === 'AbortError')
      )
        return
      failure.value = __('WasalX status could not be loaded.')
      // A non-404 response means this is a WasalX ticket. Keep its recovery
      // surface visible rather than turning a dependency outage into a dead end.
      visibility.show()
    } finally {
      if (request === currentRequest) {
        request = undefined
        if (!background) loading.value = false
      }
    }
  }

  watch(
    ticketId,
    () => {
      retryGeneration += 1
      retryPhase.value = 'idle'
      retryFailure.value = null
      retryConfirmation.value = ''
      retryToken.value = null
      void load()
    },
    { immediate: true },
  )
  const refreshWhenVisible = () => {
    if (document.visibilityState === 'visible' && !request) void load(true)
  }
  const refreshTimer = window.setInterval(refreshWhenVisible, 15_000)
  document.addEventListener('visibilitychange', refreshWhenVisible)
  onBeforeUnmount(() => {
    retryGeneration += 1
    request?.abort()
    request = undefined
    if (refreshTimer) window.clearInterval(refreshTimer)
    document.removeEventListener('visibilitychange', refreshWhenVisible)
  })

  const serviceWindow = useWasalxServiceWindow(
    () => panel.value?.service_window_expires_at,
  )
  const canTrackTemplate = computed(
    () =>
      panel.value?.connection.provider === 'META' &&
      Boolean(panel.value?.ticket.bot_state),
  )
  const canSendTemplate = computed(
    () =>
      serviceWindow.state.value === 'closed' &&
      panel.value?.ticket.bot_state === 'HUMAN' &&
      panel.value?.connection.provider === 'META',
  )
  const openTemplatePicker = () => {
    if (canTrackTemplate.value && ticketId.value)
      void openWasalxTemplateDialog(String(ticketId.value), label)
  }
  const connectionTone = computed(() => tone(panel.value?.connection.state))
  const deliveryTone = computed(() => tone(panel.value?.delivery.state))
  const retryEligible = computed(() =>
    Boolean(
      panel.value?.can_retry &&
      panel.value.delivery.retry_allowed &&
      panel.value.delivery.id &&
      panel.value.delivery.article_id,
    ),
  )
  const emailRetryEligible = computed(() =>
    Boolean(panel.value?.can_retry && panel.value.email_routing?.retry_allowed),
  )
  const retryConfirmationValid = computed(
    () =>
      !panel.value?.delivery.retry_requires_confirmation ||
      retryConfirmation.value === 'RETRY',
  )
  const caseHeadingId = computed(
    () => `wasalx-case-heading-${panel.value?.ticket.id || 'loading'}`,
  )
  const formatCount = (value: number) => countFormatter.format(value)

  const tone = (state?: string) => {
    if (
      state === 'WORKING' ||
      state === 'SENT' ||
      state === 'DELIVERED' ||
      state === 'READ' ||
      state === 'APPLIED' ||
      state === 'SUCCEEDED'
    )
      return 'text-green-700 dark:text-green-400'
    if (
      state === 'FAILED' ||
      state === 'FAILED_TERMINAL' ||
      state === 'REVOKED' ||
      state === 'OUTCOME_UNKNOWN' ||
      state === 'BLOCKED'
    )
      return 'text-red-600 dark:text-red-400'
    if (
      state === 'DEGRADED' ||
      state === 'ACTION_REQUIRED' ||
      state === 'FAILED_RETRYABLE'
    )
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
      OUTCOME_UNKNOWN: __('Delivery outcome unconfirmed'),
      BLOCKED: __('Blocked'),
      NOT_SENT: __('Not sent'),
      PENDING: __('Pending'),
      APPLIED: __('Applied'),
      SUCCEEDED: __('Applied'),
      BOT: __('Bot active'),
      ACTION_PENDING: __('Automation needs review'),
      HANDOFF_PENDING: __('Assigning to a person'),
      HUMAN: __('Human support'),
      RESOLVED: __('Conversation resolved'),
    }

    // __() only marks the source for extraction; translate at render time.
    return i18n.t(value ? labels[value] || __('Unknown') : __('Unknown'))
  }

  const timestamp = (value?: string | null) => {
    if (!value) return i18n.t('Not observed')
    const date = new Date(value)
    return Number.isNaN(date.getTime())
      ? i18n.t('Not observed')
      : new Intl.DateTimeFormat(document.documentElement.lang || undefined, {
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
      (value.message_context === null ||
        (uuid(value.message_context.group_id) &&
          uuid(value.message_context.message_id))) &&
      Array.isArray(value.message_contexts) &&
      value.message_contexts.length <= 100 &&
      value.message_contexts.every(
        (context) => uuid(context?.group_id) && uuid(context?.message_id),
      ) &&
      typeof value.message_contexts_truncated === 'boolean' &&
      (value.email_routing === null ||
        (/^[1-9][0-9]{0,15}$/u.test(value.email_routing?.article_id || '') &&
          ['PENDING', 'APPLIED', 'FAILED_TERMINAL'].includes(
            value.email_routing.routing_state,
          ) &&
          (value.email_routing.acknowledgement_state === null ||
            ['PENDING', 'SUCCEEDED', 'FAILED_TERMINAL'].includes(
              value.email_routing.acknowledgement_state,
            )) &&
          typeof value.email_routing.retry_allowed === 'boolean')) &&
      (value.trigger_sender === null ||
        value.trigger_sender === undefined ||
        (typeof value.trigger_sender?.from_me === 'boolean' &&
          (value.trigger_sender.sender_name === null ||
            typeof value.trigger_sender.sender_name === 'string') &&
          (value.trigger_sender.sender_phone === null ||
            /^\+[1-9][0-9]{5,14}$/u.test(value.trigger_sender.sender_phone)))),
    )

  const uuid = (value?: string) =>
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(
      value || '',
    )

  const retryDelivery = async () => {
    const value = panel.value
    if (
      !value ||
      !retryEligible.value ||
      !retryConfirmationValid.value ||
      !value.delivery.id ||
      !value.delivery.article_id
    )
      return

    const generation = ++retryGeneration
    const currentTicketId = value.ticket.id
    const currentDeliveryId = value.delivery.id
    const isCurrentRetry = () =>
      generation === retryGeneration &&
      ticketId.value === currentTicketId &&
      panel.value?.delivery.id === currentDeliveryId
    retryPhase.value = 'pending'
    retryFailure.value = null
    retryToken.value ||= globalThis.crypto.randomUUID()
    try {
      const csrfToken = document.querySelector<HTMLMetaElement>(
        'meta[name="csrf-token"]',
      )?.content
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
      if (!response.ok)
        throw new Error(__('The delivery could not be queued for retry.'))

      if (!isCurrentRetry()) return
      retryPhase.value = 'success'
      retryToken.value = null
      retryConfirmation.value = ''
      await load()
    } catch {
      if (!isCurrentRetry()) return
      retryPhase.value = 'failed'
      retryFailure.value = __('The delivery could not be queued for retry.')
    }
  }

  const retryEmailRouting = async () => {
    const value = panel.value
    if (!value?.email_routing || !emailRetryEligible.value) return
    const generation = ++retryGeneration
    const currentTicketId = value.ticket.id
    retryPhase.value = 'pending'
    retryFailure.value = null
    try {
      const csrfToken = document.querySelector<HTMLMetaElement>(
        'meta[name="csrf-token"]',
      )?.content
      const response = await fetch(
        `/api/v1/wasalx/tickets/${value.ticket.id}/articles/${value.email_routing.article_id}/routing/retry`,
        {
          method: 'POST',
          credentials: 'same-origin',
          headers: {
            Accept: 'application/json',
            ...(csrfToken ? { 'X-CSRF-Token': csrfToken } : {}),
          },
        },
      )
      if (!response.ok)
        throw new Error(__('Email routing could not be queued for retry.'))
      if (generation !== retryGeneration || ticketId.value !== currentTicketId)
        return
      retryPhase.value = 'success'
      await load()
    } catch {
      if (generation !== retryGeneration || ticketId.value !== currentTicketId)
        return
      retryPhase.value = 'failed'
      retryFailure.value = __('Email routing could not be queued for retry.')
    }
  }

  return {
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
    serviceWindow,
    canSendTemplate,
    canTrackTemplate,
    openTemplatePicker,
    caseHeadingId,
    formatCount,
    label,
    timestamp,
    load,
    retryDelivery,
    retryEmailRouting,
  }
}

export type WasalxTicketOperationsState = ReturnType<
  typeof useWasalxTicketOperations
>
