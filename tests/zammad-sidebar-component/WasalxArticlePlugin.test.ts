// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX
import { createNode, type FormKitNode } from '@formkit/core'
import * as defaultRules from '@formkit/rules'
import { createValidationPlugin } from '@formkit/validation'
import { describe, expect, test, vi } from 'vitest'

import { i18n } from './stubs/i18n.ts'

const pluginModule = `${process.cwd()}/../../zammad-package/app/frontend/shared/entities/ticket-article/action/plugins/wasalx.ts`
const { default: plugin } = await import(pluginModule)

const ticket = (attributes: Record<string, unknown>) =>
  ({
    objectAttributeValues: Object.entries(attributes).map(([name, value]) => ({
      attribute: { name },
      value,
    })),
  }) as never

const base = { wasalx_connection_id: 'connection-1', wasalx_group_id: 'chat-1' }

describe('WasalX ticket composer ownership', () => {
  test('keeps the group composer unchanged', () => {
    expect(plugin.addTypes?.(ticket(base))).toHaveLength(1)
  })

  test('fails closed for direct conversations until human handoff is projected', () => {
    expect(
      plugin.addTypes?.(ticket({ ...base, wasalx_bot_conversation: 'true' })),
    ).toEqual([])
    expect(
      plugin.addTypes?.(
        ticket({
          ...base,
          wasalx_bot_conversation: 'true',
          wasalx_bot_state: 'BOT',
        }),
      ),
    ).toEqual([])
    expect(
      plugin.addTypes?.(
        ticket({ ...base, wasalx_bot_state: 'HANDOFF_PENDING' }),
      ),
    ).toEqual([])
    expect(
      plugin.addTypes?.(ticket({ ...base, wasalx_bot_state: 'HUMAN' })),
    ).toHaveLength(1)
  })

  test('only offers a direct reply action while a person owns the conversation', () => {
    const article = {
      type: { name: 'wasalx group message' },
      sender: { name: 'Customer' },
      internal: false,
      internalId: 8,
      messageId: 'message-1',
    } as never
    expect(
      plugin.addActions?.(
        ticket({ ...base, wasalx_bot_state: 'BOT' }),
        article,
      ),
    ).toEqual([])
    const actions =
      plugin.addActions?.(
        ticket({ ...base, wasalx_bot_state: 'HUMAN' }),
        article,
      ) || []
    const openReplyForm = vi.fn()
    actions[0]?.perform?.(ticket(base), article, { openReplyForm } as never)
    expect(openReplyForm).toHaveBeenCalledWith(
      expect.objectContaining({ inReplyTo: 'message-1' }),
    )
  })
  test.each(['Customer', 'Agent'])(
    'quotes the exact public %s article in desktop and mobile',
    (sender) => {
      const article = {
        type: { name: 'wasalx group message' },
        sender: { name: sender },
        internal: false,
        internalId: 8,
        messageId: 'selected-native-id',
        preferences: {},
      } as never
      const action = plugin.addActions?.(ticket(base), article)?.[0]
      expect(action?.apps).toEqual(['mobile', 'desktop'])
      const openReplyForm = vi.fn()
      action?.perform?.(ticket(base), article, { openReplyForm } as never)
      expect(openReplyForm).toHaveBeenCalledExactlyOnceWith({
        articleType: 'wasalx group message',
        inReplyTo: 'selected-native-id',
        internal: false,
      })
    },
  )

  test.each([null, undefined, ''])(
    'uses the stable native article ID when messageId is %s',
    (messageId) => {
      const article = {
        type: { name: 'wasalx group message' },
        sender: { name: 'Agent' },
        internal: false,
        internalId: 812,
        messageId,
        preferences: {},
      } as never
      const action = plugin.addActions?.(ticket(base), article)?.[0]
      const openReplyForm = vi.fn()
      action?.perform?.(ticket(base), article, { openReplyForm } as never)
      expect(openReplyForm).toHaveBeenCalledExactlyOnceWith({
        articleType: 'wasalx group message',
        inReplyTo: 'wasalx-article:812',
        internal: false,
      })
    },
  )

  test.each([
    { internal: true },
    { internal: undefined },
    { sender: { name: 'System' } },
    { type: { name: 'note' } },
    { messageId: null, internalId: undefined },
    { messageId: '', internalId: 0 },
    { messageId: null, internalId: '12x' },
    { messageId: null, internalId: '12345678901234567' },
  ])('does not offer unsafe native reply identity %#', (override) => {
    const article = {
      type: { name: 'wasalx group message' },
      sender: { name: 'Customer' },
      internal: false,
      internalId: 8,
      messageId: 'message-1',
      ...override,
    } as never
    expect(plugin.addActions?.(ticket(base), article)).toEqual([])
  })

  test.each(['BOT', 'HANDOFF_PENDING', 'RESOLVED'])(
    'keeps direct %s replies unavailable for agents too',
    (state) => {
      const article = {
        type: { name: 'wasalx group message' },
        sender: { name: 'Agent' },
        internal: false,
        internalId: 8,
        messageId: null,
      } as never
      expect(
        plugin.addActions?.(
          ticket({ ...base, wasalx_bot_state: state }),
          article,
        ),
      ).toEqual([])
    },
  )
})

const ruleModule = `${process.cwd()}/../../zammad-package/app/frontend/shared/form/validation/rules/wasalx-require-one.ts`
const { default: replyRule } = await import(ruleModule)

describe('WasalX retained reply validation lifecycle', () => {
  const fixture = (
    withArticleType = true,
    hook: 'onOpened' | 'onSelected' = 'onOpened',
  ) => {
    const article = createNode({ name: 'article', type: 'group' })
    const articleType = withArticleType
      ? createNode({
          name: 'articleType',
          value: 'wasalx group message',
          parent: article,
        })
      : undefined
    const fields = plugin.addTypes?.(ticket(base))?.[0]?.fields
    const validation = createValidationPlugin({
      ...defaultRules,
      [replyRule.ruleType]: replyRule.rule,
    })
    const body = createNode({
      name: 'body',
      value: '',
      parent: article,
      props: { validation: fields?.body?.validation },
      plugins: [validation],
    })
    const attachments = createNode({
      name: 'attachments',
      value: [],
      parent: article,
      props: { validation: fields?.attachments?.validation },
      plugins: [validation],
    })
    plugin
      .addTypes?.(ticket(base))?.[0]
      ?.[hook]?.(
        ticket(base),
        { body: {} } as never,
        { getNodeByName: (name: string) => article.at(name) } as never,
      )
    // Same blocking counter used by the native FormKit Vue binding; a core
    // node without this counter would report zero even with failed validation.
    void body.ledger.count('blocking', (message) => message.blocking)
    void attachments.ledger.count('blocking', (message) => message.blocking)
    expect(
      body.props.parsedRules.map((rule: { name: string }) => rule.name),
    ).toEqual(['wasalx_require_one', 'length'])
    expect(
      attachments.props.parsedRules.map((rule: { name: string }) => rule.name),
    ).toEqual(['wasalx_require_one'])
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
      await attachments.input([
        new File(['owned test'], 'إيصال.pdf', { type: 'application/pdf' }),
      ])
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

  test.each(['onOpened', 'onSelected'] as const)(
    'keeps Note saves ready after WhatsApp via %s',
    async (hook) => {
      const { article, articleType, body, attachments } = fixture(true, hook)
      const internal = createNode({
        name: 'internal',
        value: false,
        parent: article,
      })
      void article.ledger.count('blocking', (message) => message.blocking)
      try {
        await body.input('Public reply: مرحبًا')
        await expectValid(body, true)
        await expectValid(attachments, true)
        // Successful native save resets retained values before the next draft.
        await article.input({
          articleType: undefined,
          internal: undefined,
          body: '',
          attachments: [],
        })
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
        expect(article.value).toMatchObject({
          articleType: 'note',
          internal: true,
          body: '<p>ملاحظة داخلية محفوظة</p>',
        })
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
    },
  )

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
    expect(type?.fields?.body?.validation).toBe(
      'wasalx_require_one:attachments|length:1,4096',
    )
    expect(type?.editorMeta?.footer).toMatchObject({
      maxlength: 4096,
      allowExceedMaxLength: false,
    })
    expect(type?.fields?.attachments?.allowedFiles).toContainEqual({
      label: 'Document file',
      types: [
        'application/pdf',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      ],
      size: 25 * 1024 * 1024,
    })
  })
})

describe('WasalX template dialog', () => {
  test('recovers without retaining inputs and starts a new request only on explicit action', async () => {
    const modulePath = `${process.cwd()}/../../zammad-package/app/frontend/shared/entities/ticket-article/action/wasalxTemplateDialog.ts`
    const { openWasalxTemplateDialog } = await import(modulePath)
    const originalLang = document.documentElement.lang
    const originalDir = document.documentElement.dir
    document.documentElement.lang = 'ar'
    document.documentElement.dir = 'rtl'
    const prototype = HTMLDialogElement.prototype
    const showModal = Object.getOwnPropertyDescriptor(prototype, 'showModal')
    Object.defineProperty(prototype, 'showModal', {
      configurable: true,
      value(this: HTMLDialogElement) {
        this.open = true
      },
    })
    const scope = 'b'.repeat(64)
    vi.mocked(globalThis.crypto.randomUUID)
      .mockReturnValueOnce('00000000-0000-4000-8000-000000000042')
      .mockReturnValueOnce('00000000-0000-4000-8000-000000000043')
    const storageKey = `wasalx:ticket-template:${scope}`
    const deliveryId = '45000000-0000-4000-8000-000000000005'
    const submissions: string[] = []
    let statusLookups = 0
    const fetchTemplate = vi.fn(async (url: string, init: RequestInit) => {
      const query = new URL(url, 'https://example.test').searchParams
      if (query.has('recovery')) return Response.json({ scope })
      if (query.has('request_token')) {
        statusLookups += 1
        expect(query.get('request_token')).toBe(
          JSON.parse(submissions[0]!).input.request_token,
        )
        if (query.has('delivery_id'))
          expect(query.get('delivery_id')).toBe(deliveryId)
        return Response.json({
          delivery:
            submissions.length >= 2
              ? { id: deliveryId, state: 'DELIVERED' }
              : null,
        })
      }
      if (init.method === 'POST') {
        submissions.push(String(init.body))
        if (submissions.length === 3) return new Response(null, { status: 409 })
        throw new TypeError('simulated lost response')
      }
      return Response.json({
        window: 'CLOSED',
        templates: [
          {
            id: '44',
            name: 'order_update',
            language: 'ar',
            text: 'Order {{1}}',
            parameterCount: 1,
            semanticSha256: 'a'.repeat(64),
          },
        ],
      })
    })
    vi.stubGlobal('fetch', fetchTemplate)
    const translations: Record<string, string> = {
      'Send WhatsApp template': 'إرسال قالب واتساب',
      'An earlier send was already queued. Your changes were not sent.':
        'أُدرج إرسال سابق في قائمة الانتظار. لم تُرسل تغييراتك.',
      Delivered: 'تم التسليم',
    }
    const translate = vi
      .spyOn(i18n, 't')
      .mockImplementation((message) => translations[message] ?? message)
    const open = async () => {
      await openWasalxTemplateDialog('42', (state: string) =>
        state === 'DELIVERED' ? 'Delivered' : state,
      )
      return document.querySelector('dialog')!
    }
    const submit = (dialog: HTMLDialogElement, value: string) => {
      const select = dialog.querySelector('select')!
      expect(select.disabled).toBe(false)
      if (!select.value) {
        select.value = '44'
        select.dispatchEvent(new Event('change'))
        expect(dialog.querySelector('input')?.value).toBe('')
      }
      const input = dialog.querySelector('input')!
      expect(input.dir).toBe('auto')
      expect(input.readOnly).toBe(false)
      input.value = value
      dialog
        .querySelector('form')!
        .dispatchEvent(new Event('submit', { cancelable: true }))
    }
    const expectRetry = (dialog: HTMLDialogElement) =>
      vi.waitFor(() =>
        expect(dialog.textContent).toContain('You can change the template'),
      )
    const tokenAt = (index: number) =>
      JSON.parse(submissions[index]!).input.request_token
    try {
      let dialog = await open()
      expect(dialog.dir).toBe('rtl')
      expect(dialog.querySelector('h2')?.textContent).toBe('إرسال قالب واتساب')
      submit(dialog, 'synthetic order')
      await expectRetry(dialog)
      expect(JSON.parse(sessionStorage.getItem(storageKey)!)).toEqual({
        token: JSON.parse(submissions[0]!).input.request_token,
      })
      dialog.remove()
      dialog = await open()
      await expectRetry(dialog)
      submit(dialog, 'corrected order')
      await expectRetry(dialog)
      expect(JSON.parse(submissions[1]!).input.parameters).toEqual([
        'corrected order',
      ])
      expect(tokenAt(1)).toBe(tokenAt(0))
      submit(dialog, 'another correction')
      await vi.waitFor(() => expect(dialog.querySelector('form')).toBeNull())
      const receiptStatus = dialog.querySelector('[role="status"]')
      expect(receiptStatus?.textContent).toContain('تم التسليم')
      expect(receiptStatus?.textContent).toContain(
        'أُدرج إرسال سابق في قائمة الانتظار. لم تُرسل تغييراتك.',
      )
      expect(statusLookups).toBe(2)
      expect(tokenAt(2)).toBe(tokenAt(0))
      dialog.remove()
      dialog = await open()
      expect(dialog.querySelector('[role="status"]')?.textContent).toBe(
        'تم التسليم',
      )
      expect(dialog.querySelector('form')).toBeNull()
      expect(JSON.parse(sessionStorage.getItem(storageKey)!)).toEqual({
        token: JSON.parse(submissions[0]!).input.request_token,
        id: deliveryId,
      })
      const button = (label: string) =>
        Array.from(dialog.querySelectorAll('button')).find(
          (item) => item.textContent === label,
        )!
      button('Check template delivery status').click()
      await vi.waitFor(() =>
        expect(button('Check template delivery status').disabled).toBe(false),
      )
      button('Send another template').click()
      await vi.waitFor(() =>
        expect(dialog.querySelector('form')).not.toBeNull(),
      )
      submit(dialog, 'new order')
      await expectRetry(dialog)
      expect(tokenAt(3)).not.toBe(tokenAt(0))
    } finally {
      translate.mockRestore()
      sessionStorage.removeItem(storageKey)
      document.querySelector('dialog')?.remove()
      document.documentElement.lang = originalLang
      document.documentElement.dir = originalDir
      if (showModal) Object.defineProperty(prototype, 'showModal', showModal)
      else Reflect.deleteProperty(prototype, 'showModal')
      vi.unstubAllGlobals()
    }
  })
})
