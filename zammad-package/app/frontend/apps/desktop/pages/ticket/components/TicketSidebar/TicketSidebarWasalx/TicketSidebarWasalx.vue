<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (c) 2026 WasalX -->
<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { createMessage } from '@formkit/core'
import { i18n } from '#shared/i18n/index.ts'
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
// This package-owned item, with its button built directly in the DOM, is moved
// into FormKit's current message list, which a native re-render may replace.
// A Vue Teleport into the item rendered nothing in the native desktop build.
const templateSlot = document.createElement('li')
const templateButton = document.createElement('button')
templateButton.type = 'button'
templateButton.className =
  'my-1 min-h-9 rounded-md border border-current px-3 py-1 text-sm font-medium focus-visible:outline-2 focus-visible:outline-offset-2'
templateButton.dataset.testId = 'wasalx-send-template'
templateButton.addEventListener('click', () => operations.openTemplatePicker())
templateSlot.append(templateButton)
const windowMessageKey = 'wasalxServiceWindowClosed'
watch(
  [
    form,
    operations.serviceWindow.state,
    publicWhatsAppReply,
    operations.canSendTemplate,
  ],
  (
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
    let targetObserver: MutationObserver | undefined
    onCleanup(() => {
      targetObserver?.disconnect()
      templateSlot.remove()
      body.store.remove(windowMessageKey)
    })
    if (!canSendTemplate) return

    templateButton.textContent = i18n.t('Send WhatsApp template')
    const messageId = body.props.id + '-' + windowMessageKey
    const placeSlot = () => {
      const list = document.getElementById(messageId)?.parentElement
      if (list && templateSlot.parentElement !== list) list.append(templateSlot)
    }
    placeSlot()
    // FormKit may render the message late or re-render its list; follow it.
    targetObserver = new MutationObserver(placeSlot)
    targetObserver.observe(document.body, { childList: true, subtree: true })
  },
  { immediate: true },
)
</script>
<template>
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
