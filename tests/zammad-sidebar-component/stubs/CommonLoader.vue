<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (c) 2026 WasalX -->
<script setup lang="ts">defineProps<{ loading?: boolean }>()</script>
<template><div v-if="loading" role="status">Loading…</div><slot v-else /></template>
