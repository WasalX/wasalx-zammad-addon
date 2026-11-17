// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
import type { RouteRecordRaw } from 'vue-router'
import { installNativeAccessibility } from '#shared/wasalx/accessibility.ts'

installNativeAccessibility()

const routes: RouteRecordRaw[] = [{
  path: '/wasalx/groups',
  name: 'WasalxGroups',
  component: () => import('#desktop/pages/wasalx-groups/views/WasalxGroups.vue'),
  props: { mobile: true },
  meta: {
    title: __('WhatsApp Groups'),
    requiresAuth: true,
    requiredPermission: ['ticket.agent'],
    hasHeader: false,
    hasBottomNavigation: true,
    level: 1,
  },
}]

export default routes
