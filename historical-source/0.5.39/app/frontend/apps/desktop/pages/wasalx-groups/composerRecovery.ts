// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>

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

// The session ledger survives a hard reload while remaining isolated to this
// browser tab. The CSRF-derived scope prevents a later login in the same tab
// from inheriting another agent's unfinished message. The in-memory copy is a
// fallback for browsers that deny session storage.
const recoveries = new Map<string, GroupSendRecovery>()
const STORAGE_PREFIX = 'wasalx:group-send-recovery:'

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
const storageKey = (scope: string, groupId: string) => `${STORAGE_PREFIX}${key(scope, groupId)}`
const copy = (value: GroupSendRecovery): GroupSendRecovery => ({
  ...value,
  replyToMessage: value.replyToMessage ? { ...value.replyToMessage } : null,
  mentions: [...value.mentions],
  attachments: value.attachments.map((item) => ({ ...item })),
})

const validRecovery = (value: unknown, groupId: string): value is GroupSendRecovery => {
  if (!value || typeof value !== 'object') return false
  const candidate = value as Partial<GroupSendRecovery>
  return candidate.groupId === groupId
    && typeof candidate.signature === 'string' && candidate.signature.length <= 4_096
    && typeof candidate.token === 'string' && candidate.token.length <= 100
    && typeof candidate.message === 'string' && candidate.message.length <= 65_536
    && typeof candidate.uploadCacheId === 'string' && candidate.uploadCacheId.length <= 100
    && Array.isArray(candidate.mentions) && candidate.mentions.length <= 20
    && candidate.mentions.every((item) => typeof item === 'string' && item.length <= 512)
    && (candidate.replyToMessage === null || Boolean(candidate.replyToMessage
      && typeof candidate.replyToMessage.id === 'string' && candidate.replyToMessage.id.length <= 100
      && (candidate.replyToMessage.messageText === null || typeof candidate.replyToMessage.messageText === 'string')))
    && Array.isArray(candidate.attachments) && candidate.attachments.length <= 10
    && candidate.attachments.every((item) => Boolean(item && Number.isSafeInteger(item.id) && item.id > 0
      && typeof item.filename === 'string' && item.filename.length <= 512
      && Number.isSafeInteger(item.size) && item.size >= 0
      && typeof item.contentType === 'string' && item.contentType.length <= 255))
}

const storedRecovery = (scope: string, groupId: string) => {
  try {
    const serialized = globalThis.sessionStorage?.getItem(storageKey(scope, groupId))
    if (!serialized) return undefined
    const value: unknown = JSON.parse(serialized)
    if (validRecovery(value, groupId)) return copy(value)
    globalThis.sessionStorage.removeItem(storageKey(scope, groupId))
  } catch {
    // Session storage can be unavailable under restrictive browser policies.
  }
  return undefined
}

export const readGroupSendRecovery = (scope: string, groupId: string) => {
  const value = storedRecovery(scope, groupId) ?? recoveries.get(key(scope, groupId))
  if (value) recoveries.set(key(scope, groupId), copy(value))
  return value ? copy(value) : undefined
}

export const writeGroupSendRecovery = (scope: string, value: GroupSendRecovery) => {
  recoveries.set(key(scope, value.groupId), copy(value))
  try {
    globalThis.sessionStorage?.setItem(storageKey(scope, value.groupId), JSON.stringify(value))
  } catch {
    // Keep the in-memory recovery when browser storage is unavailable or full.
  }
}

export const clearGroupSendRecovery = (scope: string, groupId: string, token?: string) => {
  const recoveryKey = key(scope, groupId)
  const value = storedRecovery(scope, groupId) ?? recoveries.get(recoveryKey)
  if (!value || (token && value.token !== token)) return
  recoveries.delete(recoveryKey)
  try {
    globalThis.sessionStorage?.removeItem(storageKey(scope, groupId))
  } catch {
    // The in-memory recovery was still cleared.
  }
}
