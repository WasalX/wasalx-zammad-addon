// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
import { createNode, type FormKitNode } from '@formkit/core'
import * as defaultRules from '@formkit/rules'
import { createValidationPlugin } from '@formkit/validation'
import { describe, expect, test, vi } from 'vitest'

const pluginModule = `${process.cwd()}/../../zammad-package/app/frontend/shared/entities/ticket-article/action/plugins/wasalx.ts`
const { default: plugin } = await import(pluginModule)

const ticket = (attributes: Record<string, unknown>) => ({
  objectAttributeValues: Object.entries(attributes).map(([name, value]) => ({ attribute: { name }, value })),
}) as never

const base = { wasalx_connection_id: 'connection-1', wasalx_group_id: 'chat-1' }

describe('WasalX ticket composer ownership', () => {
  test('keeps the group composer unchanged', () => {
    expect(plugin.addTypes?.(ticket(base))).toHaveLength(1)
  })

  test('fails closed for direct conversations until human handoff is projected', () => {
    expect(plugin.addTypes?.(ticket({ ...base, wasalx_bot_conversation: 'true' }))).toEqual([])
    expect(plugin.addTypes?.(ticket({ ...base, wasalx_bot_conversation: 'true', wasalx_bot_state: 'BOT' }))).toEqual([])
    expect(plugin.addTypes?.(ticket({ ...base, wasalx_bot_state: 'HANDOFF_PENDING' }))).toEqual([])
    expect(plugin.addTypes?.(ticket({ ...base, wasalx_bot_state: 'HUMAN' }))).toHaveLength(1)
  })

  test('only offers a direct reply action while a person owns the conversation', () => {
    const article = { type: { name: 'wasalx group message' }, sender: { name: 'Customer' }, internal: false, internalId: 8, messageId: 'message-1' } as never
    expect(plugin.addActions?.(ticket({ ...base, wasalx_bot_state: 'BOT' }), article)).toEqual([])
    const actions = plugin.addActions?.(ticket({ ...base, wasalx_bot_state: 'HUMAN' }), article) || []
    const openReplyForm = vi.fn()
    actions[0]?.perform?.(ticket(base), article, { openReplyForm } as never)
    expect(openReplyForm).toHaveBeenCalledWith(expect.objectContaining({ inReplyTo: 'message-1' }))
  })
  test.each(['Customer', 'Agent'])('quotes the exact public %s article in desktop and mobile', (sender) => {
    const article = { type: { name: 'wasalx group message' }, sender: { name: sender },
      internal: false, internalId: 8, messageId: 'selected-native-id', preferences: {} } as never
    const action = plugin.addActions?.(ticket(base), article)?.[0]
    expect(action?.apps).toEqual(['mobile', 'desktop'])
    const openReplyForm = vi.fn()
    action?.perform?.(ticket(base), article, { openReplyForm } as never)
    expect(openReplyForm).toHaveBeenCalledExactlyOnceWith({
      articleType: 'wasalx group message', inReplyTo: 'selected-native-id', internal: false,
    })
  })

  test.each([null, undefined, ''])('uses the stable native article ID when messageId is %s', (messageId) => {
    const article = { type: { name: 'wasalx group message' }, sender: { name: 'Agent' },
      internal: false, internalId: 812, messageId, preferences: {} } as never
    const action = plugin.addActions?.(ticket(base), article)?.[0]
    const openReplyForm = vi.fn()
    action?.perform?.(ticket(base), article, { openReplyForm } as never)
    expect(openReplyForm).toHaveBeenCalledExactlyOnceWith({
      articleType: 'wasalx group message', inReplyTo: 'wasalx-article:812', internal: false,
    })
  })

  test.each([
    { internal: true }, { internal: undefined }, { sender: { name: 'System' } },
    { type: { name: 'note' } }, { messageId: null, internalId: undefined },
    { messageId: '', internalId: 0 }, { messageId: null, internalId: '12x' },
    { messageId: null, internalId: '12345678901234567' },
  ])('does not offer unsafe native reply identity %#', (override) => {
    const article = { type: { name: 'wasalx group message' }, sender: { name: 'Customer' },
      internal: false, internalId: 8, messageId: 'message-1', ...override } as never
    expect(plugin.addActions?.(ticket(base), article)).toEqual([])
  })

  test.each(['BOT', 'HANDOFF_PENDING', 'RESOLVED'])('keeps direct %s replies unavailable for agents too', (state) => {
    const article = { type: { name: 'wasalx group message' }, sender: { name: 'Agent' },
      internal: false, internalId: 8, messageId: null } as never
    expect(plugin.addActions?.(ticket({ ...base, wasalx_bot_state: state }), article)).toEqual([])
  })

})

const ruleModule = `${process.cwd()}/../../zammad-package/app/frontend/shared/form/validation/rules/wasalx-require-one.ts`
const { default: replyRule } = await import(ruleModule)

describe('WasalX retained reply validation lifecycle', () => {
  const fixture = (withArticleType = true, hook: 'onOpened' | 'onSelected' = 'onOpened') => {
    const article = createNode({ name: 'article', type: 'group' })
    const articleType = withArticleType
      ? createNode({ name: 'articleType', value: 'wasalx group message', parent: article })
      : undefined
    const fields = plugin.addTypes?.(ticket(base))?.[0]?.fields
    const validation = createValidationPlugin({ ...defaultRules, [replyRule.ruleType]: replyRule.rule })
    const body = createNode({ name: 'body', value: '', parent: article,
      props: { validation: fields?.body?.validation }, plugins: [validation] })
    const attachments = createNode({ name: 'attachments', value: [], parent: article,
      props: { validation: fields?.attachments?.validation }, plugins: [validation] })
    plugin.addTypes?.(ticket(base))?.[0]?.[hook]?.(ticket(base), { body: {} } as never,
      { getNodeByName: (name: string) => article.at(name) } as never)
    // Same blocking counter used by the native FormKit Vue binding; a core
    // node without this counter would report zero even with failed validation.
    void body.ledger.count('blocking', (message) => message.blocking)
    void attachments.ledger.count('blocking', (message) => message.blocking)
    expect(body.props.parsedRules.map((rule: { name: string }) => rule.name))
      .toEqual(['wasalx_require_one', 'length'])
    expect(attachments.props.parsedRules.map((rule: { name: string }) => rule.name))
      .toEqual(['wasalx_require_one'])
    return { article, articleType, body, attachments }
  }
  const expectValid = async (node: FormKitNode, valid: boolean) => {
    await vi.waitFor(() => {
      expect(node.store.validating).toBeUndefined()
      expect(node.ledger.value('blocking') === 0).toBe(valid)
    })
  }

  test('revalidates the same retained nodes across reply, attachment, and state-only edits', async () => {
    const { article, articleType, body, attachments } = fixture()
    try {
      await expectValid(body, false)
      await expectValid(attachments, false)
      await body.input('Arabic reply: مرحبًا')
      await expectValid(body, true)
      await expectValid(attachments, true)
      await body.input('x'.repeat(4097))
      await expectValid(body, false)
      await body.input('')
      await expectValid(body, false)
      await expectValid(attachments, false)
      await attachments.input([new File(['owned test'], 'إيصال.pdf', { type: 'application/pdf' })])
      await expectValid(body, true)
      await expectValid(attachments, true)
      await attachments.input([])
      await expectValid(body, false)
      await expectValid(attachments, false)
      await articleType!.input(undefined)
      await expectValid(body, true)
      await expectValid(attachments, true)
      await articleType!.input('wasalx group message')
      await expectValid(body, false)
      await expectValid(attachments, false)
    } finally {
      article.destroy()
    }
  })

  test.each(['onOpened', 'onSelected'] as const)('keeps Note saves ready after WhatsApp via %s', async (hook) => {
    const { article, articleType, body, attachments } = fixture(true, hook)
    const internal = createNode({ name: 'internal', value: false, parent: article })
    void article.ledger.count('blocking', (message) => message.blocking)
    try {
      await body.input('Public reply: مرحبًا')
      await expectValid(body, true)
      await expectValid(attachments, true)
      // Successful native save resets retained values before the next draft.
      await article.input({ articleType: undefined, internal: undefined, body: '', attachments: [] })
      await expectValid(body, true)
      await expectValid(attachments, true)
      // Channel selection queues dependency validation while reactive field props
      // replace WhatsApp rules with Note's required body and optional attachment.
      await articleType!.input('note', false)
      body.props.validation = 'required'
      attachments.props.validation = null
      await internal.input(true, false)
      await body.input('<p>ملاحظة داخلية محفوظة</p>')
      await expectValid(body, true)
      await expectValid(attachments, true)
      expect(article.ledger.value('blocking')).toBe(0)
      expect(article.value).toMatchObject({ articleType: 'note', internal: true, body: '<p>ملاحظة داخلية محفوظة</p>' })
      // Removed-rule cleanup must not bypass Note's remaining required rule.
      await body.input('')
      await expectValid(body, false)
      expect(article.ledger.value('blocking')).toBeGreaterThan(0)
      const fields = plugin.addTypes?.(ticket(base))?.[0]?.fields
      await articleType!.input('wasalx group message', false)
      body.props.validation = fields?.body?.validation
      attachments.props.validation = fields?.attachments?.validation
      await internal.input(false, false)
      await expectValid(body, false)
      await expectValid(attachments, false)
      await body.input('A new public reply')
      await expectValid(body, true)
      await expectValid(attachments, true)
      expect(article.ledger.value('blocking')).toBe(0)
    } finally {
      article.destroy()
    }
  })

  test('fails closed when the native channel sibling is absent, even with reply content', async () => {
    const { article, body, attachments } = fixture(false)
    try {
      await body.input('A reply must have a native channel node')
      await expectValid(body, false)
      await expectValid(attachments, false)
    } finally {
      article.destroy()
    }
  })

  test('preserves native length, editor, and media constraints', () => {
    const type = plugin.addTypes?.(ticket(base))?.[0]
    expect(type?.fields?.body?.validation).toBe('wasalx_require_one:attachments|length:1,4096')
    expect(type?.editorMeta?.footer).toMatchObject({ maxlength: 4096, allowExceedMaxLength: false })
    expect(type?.fields?.attachments?.allowedFiles).toContainEqual({
      label: 'Document file',
      types: ['application/pdf', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation'],
      size: 25 * 1024 * 1024,
    })
  })
})
