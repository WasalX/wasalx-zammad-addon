// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX
import { reactive } from 'vue'
import { vi } from 'vitest'

export const route = reactive({ query: {} as Record<string, string | undefined> })
export const replace = vi.fn(async () => undefined)
export const useRoute = () => route
export const useRouter = () => ({ replace })
