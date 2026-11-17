// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>

import type { RouteRecordRaw } from 'vue-router'
import { installNativeAccessibility } from '#shared/wasalx/accessibility.ts'

installNativeAccessibility()

const routes: RouteRecordRaw[] = [
  {
    path: '/wasalx/groups',
    name: 'WasalxGroups',
    component: () => import('./views/WasalxGroups.vue'),
    meta: {
      title: __('WhatsApp Groups'),
      icon: 'whatsapp',
      requiresAuth: true,
      requiredPermission: ['ticket.agent'],
      level: 1,
      order: 70,
      pageKey: 'wasalx-groups',
      permanentItem: true,
    },
  },
]

export default routes
