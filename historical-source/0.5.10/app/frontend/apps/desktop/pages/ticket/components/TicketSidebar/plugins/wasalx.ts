// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX

import { TicketSidebarScreenType } from '#desktop/pages/ticket/types/sidebar.ts'

import TicketSidebarWasalx from '../TicketSidebarWasalx/TicketSidebarWasalx.vue'

import type { TicketSidebarPlugin } from './types.ts'

// Zammad's package precompile includes this file in the sidebar plugin glob.
// The component hides itself after a 404 so ordinary tickets never gain a
// WasalX control, while transient control-plane failures remain visible on a
// known WasalX ticket.
export default <TicketSidebarPlugin>{
  title: __('WasalX operations'),
  component: TicketSidebarWasalx,
  permissions: ['ticket.agent'],
  screens: [TicketSidebarScreenType.TicketDetailView],
  views: ['agent'],
  icon: 'whatsapp',
  order: 3500,
}
