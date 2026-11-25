// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX
/// <reference types="vitest/globals" />

declare module '*.vue' {
  import type { DefineComponent } from 'vue'

  const component: DefineComponent
  export default component
}
