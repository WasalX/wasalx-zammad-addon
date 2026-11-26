// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX
import { useForceDesktop } from '#shared/composables/useForceDesktop.ts'
import type { AvatarMenuPlugin } from './index.ts'
export default <AvatarMenuPlugin>{
  key: 'wasalx-mobile',
  label: __('Continue to mobile'),
  icon: 'phone',
  order: 450,
  permission: 'ticket.agent',
  onClick: () => {
    const { forceDesktopLocalStorage } = useForceDesktop()
    forceDesktopLocalStorage.value = false
    window.location.assign('/mobile/')
  },
}
