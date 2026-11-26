// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX
import { inject, type Ref } from 'vue'
export const useTicketInformation = () => inject<{ ticket: Ref<{ internalId: number } | undefined> }>('wasalx-mobile-ticket-information')!
