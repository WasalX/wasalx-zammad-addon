// SPDX-License-Identifier: AGPL-3.0-only
import { computed, onBeforeUnmount, ref } from 'vue'
import { i18n } from '#shared/i18n/index.ts'

export type WasalxServiceWindowState = 'unknown' | 'open' | 'closing' | 'closed'

const CLOSING_MS = 60 * 60 * 1000
const HOUR_MS = 60 * 60 * 1000
const MINUTE_MS = 60 * 1000

// The one place that turns the platform's UTC expiry into the agent-facing
// window state. A missing or unreadable expiry is unknown and never blocks.
export function useWasalxServiceWindow(expiresAt: () => string | null | undefined) {
  const now = ref(Date.now())
  const timer = window.setInterval(() => { now.value = Date.now() }, 30_000)
  onBeforeUnmount(() => window.clearInterval(timer))

  const expiry = computed(() => {
    const value = expiresAt()
    const time = value ? Date.parse(value) : Number.NaN
    return Number.isNaN(time) ? null : time
  })
  const state = computed<WasalxServiceWindowState>(() => {
    if (expiry.value === null) return 'unknown'
    const left = expiry.value - now.value
    if (left <= 0) return 'closed'
    return left <= CLOSING_MS ? 'closing' : 'open'
  })
  const text = computed(() => {
    if (expiry.value === null) return ''
    if (state.value === 'closed') return i18n.t('Window closed: send an approved template')
    const locale = document.documentElement.lang || undefined
    const left = expiry.value - now.value
    const relative = new Intl.RelativeTimeFormat(locale, { numeric: 'always' })
    const remaining = left >= HOUR_MS
      ? relative.format(Math.floor(left / HOUR_MS), 'hour')
      : relative.format(Math.max(1, Math.ceil(left / MINUTE_MS)), 'minute')
    // Same wording as the Groups view; the browser time zone is the agent's.
    const time = new Intl.DateTimeFormat(locale, { timeStyle: 'short' }).format(expiry.value)
    return `${i18n.t('Send window expires')} ${time} (${remaining})`
  })

  return { state, text }
}

export type WasalxServiceWindow = ReturnType<typeof useWasalxServiceWindow>
