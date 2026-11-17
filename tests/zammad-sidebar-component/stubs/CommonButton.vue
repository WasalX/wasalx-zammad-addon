<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com> -->
<script setup lang="ts">defineProps<{ disabled?: boolean; type?: 'button' | 'submit' }>()</script>
<template><button :type="type ?? 'button'" :disabled="disabled"><slot /></button></template>
