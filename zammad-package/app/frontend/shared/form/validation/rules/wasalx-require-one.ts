// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX

import { require_one } from '@formkit/rules'
import type { FormKitNode } from '@formkit/core'
import type { FormKitValidationRule } from '@formkit/validation'

const observedFields = new WeakSet<FormKitNode>()

export const observeWasalxValidationRemoval = (node: FormKitNode | undefined) => {
  if (!node || observedFields.has(node)) return
  observedFields.add(node)
  // FormKit 2 can retain its invisible validating blocker when a channel removes
  // the last rule while dependency revalidation is queued. No rules means there
  // is no validation left to finish; preserve every nonempty native rule set.
  node.on('prop:validation', () => {
    if (Array.isArray(node.props.parsedRules) && node.props.parsedRules.length === 0) {
      node.store.remove('validating')
    }
  })
}

const wasalxRequireOne: FormKitValidationRule = (node, ...inputNames: string[]) => {
  // Observe the channel even when content already satisfies require_one. The
  // retained reply fields must revalidate when native state-only editing clears it.
  const articleType = node.at('articleType')
  if (!articleType) return false
  if (articleType.value === undefined) return true
  return require_one(node, ...inputNames)
}

wasalxRequireOne.skipEmpty = false

export default {
  ruleType: 'wasalx_require_one',
  rule: wasalxRequireOne,
  localeMessage: () => __('Enter a message or attach a file.'),
}
