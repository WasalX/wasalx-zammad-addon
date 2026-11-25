// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX

export type RecoveredAttachment = {
  id: number
  filename: string
  size: number
  contentType: string
}

export type GroupSendRecovery = {
  groupId: string
  signature: string
  token: string
  message: string
  replyToMessage: { id: string, messageText: string | null } | null
  mentions: string[]
  uploadCacheId: string
  attachments: RecoveredAttachment[]
}

// This module-level ledger survives a route remount in the current authenticated
// browser session. The CSRF-derived scope prevents a later login in the same tab
// from inheriting another agent's unfinished message.
const recoveries = new Map<string, GroupSendRecovery>()

export const composerRecoveryScope = (csrfToken: string | undefined) => {
  if (!csrfToken) return `ephemeral:${globalThis.crypto.randomUUID()}`
  let hash = 2166136261
  for (const value of csrfToken) {
    hash ^= value.codePointAt(0) ?? 0
    hash = Math.imul(hash, 16777619)
  }
  return `session:${(hash >>> 0).toString(36)}:${csrfToken.length}`
}

const key = (scope: string, groupId: string) => `${scope}:${groupId}`
const copy = (value: GroupSendRecovery): GroupSendRecovery => ({
  ...value,
  replyToMessage: value.replyToMessage ? { ...value.replyToMessage } : null,
  mentions: [...value.mentions],
  attachments: value.attachments.map((item) => ({ ...item })),
})

export const readGroupSendRecovery = (scope: string, groupId: string) => {
  const value = recoveries.get(key(scope, groupId))
  return value ? copy(value) : undefined
}

export const writeGroupSendRecovery = (scope: string, value: GroupSendRecovery) => {
  recoveries.set(key(scope, value.groupId), copy(value))
}

export const clearGroupSendRecovery = (scope: string, groupId: string, token?: string) => {
  const recoveryKey = key(scope, groupId)
  const value = recoveries.get(recoveryKey)
  if (!value || (token && value.token !== token)) return
  recoveries.delete(recoveryKey)
}
