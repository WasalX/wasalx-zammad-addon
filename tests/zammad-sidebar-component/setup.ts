// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
import { vi } from 'vitest'

Object.defineProperty(globalThis, '__', {
  configurable: true,
  value: (message: string) => message,
})

Object.defineProperty(globalThis.crypto, 'randomUUID', {
  configurable: true,
  value: vi.fn(() => '00000000-0000-4000-8000-000000000042'),
})
