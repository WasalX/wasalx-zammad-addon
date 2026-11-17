// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
import type { TicketInformationPlugin } from './index.ts'

export default <TicketInformationPlugin>{
  label: __('WasalX operations'),
  route: {
    path: 'whatsapp-groups',
    name: 'TicketInformationWasalx',
    component: () => import('../TicketInformationWasalx.vue'),
    meta: {
      requiresAuth: true,
      requiredPermission: ['ticket.agent'],
    },
  },
  order: 400,
}
