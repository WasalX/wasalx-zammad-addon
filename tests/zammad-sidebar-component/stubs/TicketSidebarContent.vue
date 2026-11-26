<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (c) 2026 WasalX -->
<script setup lang="ts">
defineProps<{
  modelValue: number
  title: string
  icon: string
  iconClass?: string
}>()

defineEmits<{ 'update:modelValue': [value: number] }>()
</script>

<template>
  <div data-test-host="sidebar-content">
    <slot />
  </div>
</template>
