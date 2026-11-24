<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com> -->
<script setup lang="ts">
import { computed, ref } from 'vue'
import { useWasalxTicketOperations } from '#shared/components/WasalxTicketOperations/useWasalxTicketOperations.ts'
import WasalxTicketOperations from '#shared/components/WasalxTicketOperations/WasalxTicketOperations.vue'
import { useTicketInformation } from '#mobile/pages/ticket/composable/useTicketInformation.ts'
const { ticket } = useTicketInformation()
const ticketId = computed(() => ticket.value?.internalId)
const unavailable = ref(false)
const operations = useWasalxTicketOperations(ticketId, {
  show: () => { unavailable.value = false },
  hide: () => { unavailable.value = true },
})
</script>
<template>
  <section class="space-y-3 pb-4" :aria-label="$t('WasalX operations')">
    <WasalxTicketOperations :operations="operations" />
    <button
      v-if="operations.canSendTemplate.value"
      type="button"
      class="min-h-11 rounded-lg border border-current px-3 py-2 font-medium focus-visible:outline-2 focus-visible:outline-offset-2"
      data-test-id="wasalx-send-template"
      @click="operations.openTemplatePicker"
    >{{ $t('Send WhatsApp template') }}</button>
    <p v-if="unavailable" role="status">{{ $t('No WasalX operations are available for this ticket.') }}</p>
    <RouterLink to="/wasalx/groups" class="flex min-h-11 items-center justify-center rounded-lg border border-current px-3 py-2 font-medium focus-visible:outline-2 focus-visible:outline-offset-2">
      {{ $t('WhatsApp Groups') }}
    </RouterLink>
  </section>
</template>
