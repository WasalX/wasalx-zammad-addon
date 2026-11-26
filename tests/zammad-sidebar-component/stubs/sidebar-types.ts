// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX
import type { FormKitNode } from '@formkit/core'

export type SidebarForm = {
  formInitialSettled: boolean
  values: { article?: { articleType?: string; internal?: boolean } }
  getNodeByName(name: string): FormKitNode | undefined
}

export type TicketSidebarProps = {
  sidebar: string
  sidebarPlugin: { title: string; icon: string }
  selected: boolean
  context: {
    form?: SidebarForm
    ticket?: {
      value?: { internalId?: number }
    }
  }
}

export type TicketSidebarEmits = {
  hide: []
  show: []
}
