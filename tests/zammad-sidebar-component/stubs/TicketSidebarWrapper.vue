<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (c) 2026 WasalX -->
<script setup lang="ts">
defineProps<{
  sidebar: string
  sidebarPlugin: { title: string; icon: string }
  selected: boolean
}>()
</script>

<template>
  <aside aria-label="Ticket sidebar" data-test-host="sidebar-wrapper">
    <!-- Zammad 7.1.3 mounts its teleported content only after selection. -->
    <slot v-if="selected" />
  </aside>
</template>
