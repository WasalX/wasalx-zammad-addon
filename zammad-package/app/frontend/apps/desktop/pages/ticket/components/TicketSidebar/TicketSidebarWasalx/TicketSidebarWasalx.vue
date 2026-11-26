<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (c) 2026 WasalX -->
<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { createMessage } from '@formkit/core'
import type { FieldEditorContext } from '#shared/components/Form/fields/FieldEditor/types.ts'
import { attachWasalxReplyPreview } from '#shared/entities/ticket-article/action/wasalxReplyPreview.ts'
import { useWasalxTicketOperations } from '#shared/components/WasalxTicketOperations/useWasalxTicketOperations.ts'
import WasalxTicketOperations from '#shared/components/WasalxTicketOperations/WasalxTicketOperations.vue'
import TicketSidebarContent from '#desktop/pages/ticket/components/TicketSidebar/TicketSidebarContent.vue'
import TicketSidebarWrapper from '#desktop/pages/ticket/components/TicketSidebar/TicketSidebarWrapper.vue'
import type {
  TicketSidebarEmits,
  TicketSidebarProps,
} from '#desktop/pages/ticket/types/sidebar.ts'
const props = defineProps<TicketSidebarProps>()
const emit = defineEmits<TicketSidebarEmits & { click: [sidebar: string] }>()
const scrollPosition = ref(0)
const ticketId = computed(() => props.context.ticket?.value?.internalId)
const operations = useWasalxTicketOperations(ticketId, {
  show: () => emit('show'),
  hide: () => emit('hide'),
})

// Native restored drafts do not run the explicit opened/selected article hooks.
// This sidebar setup is mounted even while its teleported content is hidden.
const form = computed(() => props.context.form)
const initiallySettled = computed(() => form.value?.formInitialSettled)
const previewContext = computed(() => {
  const article = form.value?.values.article as
    { articleType?: string; internal?: boolean } | undefined
  if (
    !initiallySettled.value ||
    article?.articleType !== 'wasalx group message' ||
    article.internal !== false
  )
    return
  const context = form.value?.getNodeByName('body')?.context as
    FieldEditorContext | undefined
  return typeof context?.getEditorValue === 'function' ? context : undefined
})
const seenForms = new WeakSet<object>()
watch(
  [form, initiallySettled, previewContext, ticketId],
  ([currentForm, settled, context], _previous, onCleanup) => {
    let restoredDraft = false
    if (currentForm && settled && !seenForms.has(currentForm)) {
      seenForms.add(currentForm)
      // Only already-nonempty, first-settled drafts are possible restore matches.
      // Late editor readiness or subsequent typing must not invent a restore.
      restoredDraft =
        !!context &&
        !!String(currentForm.getNodeByName('body')?.value ?? '').trim()
    }
    const ticket = props.context.ticket?.value
    if (!currentForm || !context || !ticket) return
    const dispose = attachWasalxReplyPreview(ticket, context, currentForm, {
      restoredDraft,
    })
    if (dispose) onCleanup(dispose)
  },
  { immediate: true, flush: 'post' },
)

// Free-text WhatsApp replies cannot be delivered once the customer-service
// window has closed. Only a known closed window blocks; unknown never does.
const publicWhatsAppReply = computed(() => {
  const article = form.value?.values.article as
    { articleType?: string; internal?: boolean } | undefined
  return (
    article?.articleType === 'wasalx group message' &&
    article.internal === false
  )
})
const templateTarget = ref<HTMLElement | null>(null)
const windowMessageKey = 'wasalxServiceWindowClosed'
watch(
  [
    form,
    operations.serviceWindow.state,
    publicWhatsAppReply,
    operations.canSendTemplate,
  ],
  async (
    [currentForm, state, publicReply, canSendTemplate],
    _previous,
    onCleanup,
  ) => {
    const body = currentForm?.getNodeByName('body')
    if (!body || state !== 'closed' || !publicReply) return
    body.store.set(
      createMessage({
        key: windowMessageKey,
        type: 'error',
        blocking: true,
        visible: true,
        value: operations.serviceWindow.text.value,
      }),
    )
    let disposed = false
    onCleanup(() => {
      disposed = true
      templateTarget.value = null
      body.store.remove(windowMessageKey)
    })
    if (!canSendTemplate) return
    await nextTick()
    if (disposed) return
    // The native FormKit message id is the field id followed by the message key.
    const message = document.getElementById(
      body.props.id + '-' + windowMessageKey,
    )
    templateTarget.value = message?.parentElement ?? null
  },
  { immediate: true },
)
</script>
<template>
  <Teleport v-if="templateTarget" :to="templateTarget">
    <li>
      <button
        type="button"
        class="my-1 min-h-9 rounded-md border border-current px-3 py-1 text-sm font-medium focus-visible:outline-2 focus-visible:outline-offset-2"
        data-test-id="wasalx-send-template"
        @click="operations.openTemplatePicker"
      >
        {{ $t('Send WhatsApp template') }}
      </button>
    </li>
  </Teleport>
  <TicketSidebarWrapper
    :key="sidebar"
    :sidebar="sidebar"
    :sidebar-plugin="sidebarPlugin"
    :selected="selected"
    @click="emit('click', $event)"
  >
    <TicketSidebarContent
      v-model="scrollPosition"
      :title="sidebarPlugin.title"
      :icon="sidebarPlugin.icon"
      icon-class="text-green-500 dark:text-green-400"
    >
      <WasalxTicketOperations :operations="operations" />
    </TicketSidebarContent>
  </TicketSidebarWrapper>
</template>
