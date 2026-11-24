// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { createNode, type FormKitNode } from '@formkit/core'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import axe from 'axe-core'
import { markRaw, nextTick, reactive, ref } from 'vue'
import TicketInformationWasalx from '../../zammad-package/app/frontend/apps/mobile/pages/ticket/views/TicketInformation/TicketInformationWasalx.vue'

import TicketSidebarWasalx from '../../zammad-package/app/frontend/apps/desktop/pages/ticket/components/TicketSidebar/TicketSidebarWasalx/TicketSidebarWasalx.vue'
import type { SidebarForm } from './stubs/sidebar-types.ts'

type DeliveryState = 'FAILED_RETRYABLE' | 'OUTCOME_UNKNOWN' | 'QUEUED' | 'SENT'

type Panel = {
  ticket: {
    id: number
    number: string
    reference: string | null
    correlation_status: string
    rule_version: string
    bot_state: string | null
  }
  group: { id: string; name: string }
  connection: {
    id: string
    provider: string | null
    state: string
    binding_state: string
    available: boolean
    last_heartbeat_at: string | null
    last_provider_event_at: string | null
  }
  delivery: {
    id: string | null
    article_id: string | null
    state: string
    updated_at: string | null
    retry_allowed: boolean
    retry_requires_confirmation: boolean
  }
  portal_url: string
  message_context: { group_id: string; message_id: string } | null
  message_contexts: Array<{ group_id: string; message_id: string }>
  message_contexts_truncated: boolean
  trigger_sender: { sender_name: string | null; sender_phone: string | null; from_me: boolean } | null
  can_retry: boolean
  email_routing: {
    article_id: string
    routing_state: 'PENDING' | 'APPLIED' | 'FAILED_TERMINAL'
    acknowledgement_state: 'PENDING' | 'SUCCEEDED' | 'FAILED_TERMINAL' | null
    retry_allowed: boolean
    updated_at: string
  } | null
  service_window_expires_at?: string | null
}

type FetchResult = Pick<Response, 'json' | 'ok' | 'status'>

const fetchMock = vi.fn<typeof fetch>()
const mounted: VueWrapper[] = []

function response(body: unknown, status = 200): FetchResult {
  return {
    json: async () => body,
    ok: status >= 200 && status < 300,
    status,
  }
}

function panel(
  state: DeliveryState = 'FAILED_RETRYABLE',
  retryRequiresConfirmation = false,
): Panel {
  return {
    ticket: {
      id: 42,
      number: '420042',
      reference: 'SHIP-778899',
      correlation_status: 'OPEN',
      rule_version: 'rule-7',
      bot_state: 'HUMAN',
    },
    group: { id: 'group-1', name: 'Riyadh Operations' },
    connection: {
      id: 'connection-1',
      provider: 'WAHA',
      state: 'WORKING',
      binding_state: 'ACTIVE',
      available: true,
      last_heartbeat_at: '2026-08-12T09:00:00.000Z',
      last_provider_event_at: '2026-08-12T09:01:00.000Z',
    },
    delivery: {
      id: 'delivery-1',
      article_id: '99',
      state,
      updated_at: '2026-08-12T09:02:00.000Z',
      retry_allowed: state === 'FAILED_RETRYABLE' || state === 'OUTCOME_UNKNOWN',
      retry_requires_confirmation: retryRequiresConfirmation,
    },
    portal_url: 'https://portal.example.test/cases/SHIP-778899',
    message_context: {
      group_id: '40000000-0000-4000-8000-000000000004',
      message_id: '50000000-0000-4000-8000-000000000005',
    },
    message_contexts: [
      { group_id: '40000000-0000-4000-8000-000000000004', message_id: '50000000-0000-4000-8000-000000000005' },
      { group_id: '40000000-0000-4000-8000-000000000004', message_id: '50000000-0000-4000-8000-000000000006' },
    ],
    message_contexts_truncated: false,
    trigger_sender: { sender_name: 'Customer One', sender_phone: '+12025550184', from_me: false },
    can_retry: true,
    email_routing: null,
  }
}

function panelFor(ticket: number, state: DeliveryState = 'FAILED_RETRYABLE'): Panel {
  const value = panel(state)
  value.ticket.id = ticket
  value.ticket.number = String(420000 + ticket)
  value.group.name = ticket === 42 ? 'Riyadh Operations' : 'Jeddah Operations'
  value.delivery.id = `delivery-${ticket}`
  value.delivery.article_id = String(90 + ticket)
  return value
}

function emailPanel(
  routingState: 'PENDING' | 'APPLIED' | 'FAILED_TERMINAL',
  acknowledgementState: 'PENDING' | 'SUCCEEDED' | 'FAILED_TERMINAL' | null,
): Panel {
  const value = panel('SENT')
  value.group = { id: 'email-routing', name: 'Email routing' }
  value.connection = {
    id: 'email-routing', provider: null, state: routingState, binding_state: 'UNKNOWN', available: true,
    last_heartbeat_at: null, last_provider_event_at: '2026-09-04T10:00:00.000Z',
  }
  value.delivery = {
    id: null, article_id: null, state: acknowledgementState || routingState,
    updated_at: '2026-09-04T10:00:00.000Z', retry_allowed: false, retry_requires_confirmation: false,
  }
  value.message_context = null
  value.message_contexts = []
  value.trigger_sender = null
  value.email_routing = {
    article_id: '19', routing_state: routingState, acknowledgement_state: acknowledgementState,
    retry_allowed: [routingState, acknowledgementState].includes('FAILED_TERMINAL'),
    updated_at: '2026-09-04T10:00:00.000Z',
  }
  return value
}

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (reason?: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

function mountSidebar(selected = true, form?: SidebarForm): VueWrapper {
  const wrapper = mount(TicketSidebarWasalx, {
    attachTo: document.body,
    props: {
      context: { ticket: { value: { internalId: 42 } }, form },
      selected,
      sidebar: 'wasalx',
      sidebarPlugin: { icon: 'whatsapp', title: 'WasalX' },
    },
    global: {
      config: {
        globalProperties: {
          $t: (message: string) => message,
        },
      },
      stubs: {
        RouterLink: { props: ['to'], template: '<a :href="`/wasalx/groups?group=${to.query.group}&message=${to.query.message}`"><slot /></a>' },
      },
    },
  })
  mounted.push(wrapper)
  return wrapper
}

async function settle(): Promise<void> {
  await flushPromises()
  await nextTick()
}

async function expectComponentAccessible(wrapper: VueWrapper): Promise<void> {
  const result = await axe.run(wrapper.element, {
    rules: {
      // Layout and landmarks are owned by the surrounding Zammad ticket page.
      'color-contrast': { enabled: false },
      region: { enabled: false },
    },
  })
  expect(result.violations).toEqual([])
}

function postBodies(): Array<Record<string, unknown>> {
  return fetchMock.mock.calls
    .filter(([, options]) => options?.method === 'POST')
    .map(([, options]) => JSON.parse(String(options?.body)) as Record<string, unknown>)
}

// Real pinned FormKit nodes, with only the native editor's plain-text adapter
// and exposed FormRef subset supplied by the shell fixture.
function composer(initial: Record<string, unknown> = {}, settled = true) {
  const values = { articleType: 'wasalx group message', internal: false,
    inReplyTo: 'wasalx-article:8', body: 'Retained unsent reply', attachments: [], ...initial }
  const root = markRaw(createNode({ name: 'form', type: 'group', value: { article: values } }))
  const article = markRaw(createNode({ name: 'article', type: 'group', parent: root }))
  const nodes = Object.fromEntries(Object.entries(values).map(([name, value]) =>
    [name, markRaw(createNode({ name, value, parent: article }))])) as Record<string, FormKitNode>
  const body = nodes.body
  body.props.help = 'Native help'
  body.context = reactive({ getEditorValue: () => String(body.value ?? '') }) as unknown as typeof body.context
  const current = ref(root.value as SidebarForm['values'])
  root.on('commit', ({ payload }) => { current.value = structuredClone(payload) as SidebarForm['values'] })
  const form = reactive({ formInitialSettled: settled,
    get values() { return current.value }, getNodeByName: (name: string) => nodes[name] })
  return { root, nodes, body, form }
}

describe('restored native composer preview', () => {
  const composers: ReturnType<typeof composer>[] = []
  const open = (initial: Record<string, unknown> = {}, settled = true) => {
    const value = composer(initial, settled)
    composers.push(value)
    return { ...value, wrapper: mountSidebar(false, value.form) }
  }
  const previews = () => fetchMock.mock.calls.filter(([url]) => String(url).endsWith('/reply-preview'))
  const previewBodies = () => previews().map(([, options]) => JSON.parse(String(options?.body)))
  const tick = async (milliseconds = 250) => {
    await vi.advanceTimersByTimeAsync(milliseconds)
    await settle()
  }
  const selectManually = async (value: ReturnType<typeof composer>, ticketId = 42, form = value.form) => {
    const pluginModule = `${process.cwd()}/../../zammad-package/app/frontend/shared/entities/ticket-article/action/plugins/wasalx.ts`
    const { default: plugin } = await import(pluginModule)
    const ticket = { internalId: ticketId, objectAttributeValues: [
      { attribute: { name: 'wasalx_connection_id' }, value: 'connection-1' },
      { attribute: { name: 'wasalx_group_id' }, value: 'chat-1' },
    ] }
    plugin.addTypes(ticket)[0].onSelected(ticket, { body: value.body.context }, form)
  }
  beforeEach(() => {
    vi.useFakeTimers()
    fetchMock.mockReset()
    fetchMock.mockImplementation(async (url) => response(String(url).endsWith('/reply-preview')
      ? { text: 'Prepared retained reply', replyToMessageId: 'source-message', quoteLabel: 'Linked message' }
      : panel('SENT')) as Response)
    vi.stubGlobal('fetch', fetchMock)
  })
  afterEach(() => {
    while (mounted.length) mounted.pop()?.unmount()
    while (composers.length) composers.pop()?.root.destroy()
    vi.useRealTimers()
    document.head.querySelector('meta[name="csrf-token"]')?.remove()
    vi.unstubAllGlobals()
  })

  test('previews an already-restored public draft without manual hooks or selecting the sidebar', async () => {
    const csrf = document.createElement('meta')
    csrf.name = 'csrf-token'; csrf.content = 'synthetic-csrf'
    document.head.append(csrf)
    const { body, nodes, wrapper } = open()
    await tick(249)
    expect(previews()).toHaveLength(0)
    await tick(1)
    expect(previewBodies()).toEqual([{ body: 'Retained unsent reply', in_reply_to: 'wasalx-article:8',
      internal: false, has_attachments: false, restored_draft: true }])
    expect(previews()[0][1]).toMatchObject({ credentials: 'same-origin', headers: { 'X-CSRF-Token': 'synthetic-csrf' } })
    expect(body.props.help).toContain('Outgoing WhatsApp preview\nLinked message\n\nPrepared retained reply')
    expect(body.value).toBe('Retained unsent reply')
    expect(nodes.inReplyTo.value).toBe('wasalx-article:8')
    expect(wrapper.find('[data-test-id="wasalx-ticket-panel"]').exists()).toBe(false)
    await body.input('Edited retained reply', false)
    await tick()
    expect(previewBodies()[1]).toMatchObject({ body: 'Edited retained reply' })
    expect(previewBodies()[1]).not.toHaveProperty('restored_draft')
  })

  test('waits for initial settling and never treats later typing as restoration', async () => {
    const { body, form } = open({ body: '' }, false)
    await tick()
    expect(previews()).toHaveLength(0)
    form.formInitialSettled = true
    await settle()
    await tick()
    expect(previews()).toHaveLength(0)
    await body.input('A fresh reply', false)
    await tick()
    expect(previewBodies()).toEqual([{ body: 'A fresh reply', in_reply_to: 'wasalx-article:8',
      internal: false, has_attachments: false }])
  })

  test.each([{ articleType: 'note' }, { internal: true }])('does not bind a non-public initial composer %j', async (initial) => {
    const { nodes, body, form } = open(initial)
    await tick()
    expect(previews()).toHaveLength(0)
    expect(body.props.help).toBe('Native help')
    await nodes.articleType.input('wasalx group message', false)
    await nodes.internal.input(false, false)
    await settle()
    expect(form.values.article).toMatchObject({ articleType: 'wasalx group message', internal: false })
    await tick()
    expect(previews()).toHaveLength(1)
    expect(previewBodies()[0]).not.toHaveProperty('restored_draft')
  })

  test('suppresses the initial restore signal when an edit changes the pending preview', async () => {
    const { body } = open()
    await settle()
    await body.input('Newly edited before preview', false)
    await tick()
    expect(previewBodies()).toHaveLength(1)
    expect(previewBodies()[0]).not.toHaveProperty('restored_draft')
  })

  test.each([false, true])('shares one binding with existing manual hooks (selected again=%s)', async (selectAgain) => {
    const pluginModule = `${process.cwd()}/../../zammad-package/app/frontend/shared/entities/ticket-article/action/plugins/wasalx.ts`
    const { default: plugin } = await import(pluginModule)
    const value = composer()
    composers.push(value)
    const ticket = { internalId: 42, objectAttributeValues: [
      { attribute: { name: 'wasalx_connection_id' }, value: 'connection-1' },
      { attribute: { name: 'wasalx_group_id' }, value: 'chat-1' },
    ] }
    const type = plugin.addTypes(ticket)[0]
    type.onOpened(ticket, { body: value.body.context }, value.form)
    mountSidebar(false, value.form)
    await settle()
    if (selectAgain) type.onSelected(ticket, { body: value.body.context }, value.form)
    await tick()
    expect(previews()).toHaveLength(1)
    expect(previewBodies()[0]).not.toHaveProperty('restored_draft')
    await value.body.input('One preview per edit', false)
    await tick()
    expect(previews()).toHaveLength(2)
  })

  test('waits for a late editor adapter without inventing a restored-draft event', async () => {
    const value = composer()
    composers.push(value)
    const context = value.body.context!
    const getEditorValue = context.getEditorValue
    delete context.getEditorValue
    mountSidebar(false, value.form)
    await tick()
    expect(previews()).toHaveLength(0)
    context.getEditorValue = getEditorValue
    await settle()
    await tick()
    expect(previews()).toHaveLength(1)
    expect(previewBodies()[0]).not.toHaveProperty('restored_draft')
  })

  test('cancels reset and private-note previews without restoring stale help or changing the draft', async () => {
    const late = deferred<Response>()
    fetchMock.mockImplementation(async (url) => String(url).endsWith('/reply-preview')
      ? late.promise : response(panel('SENT')) as Response)
    const { body, nodes } = open()
    await tick()
    const signal = previews()[0][1]?.signal
    await body.input('', false)
    await settle()
    expect(signal?.aborted).toBe(true)
    expect(body.props.help).toBe('Native help')
    late.resolve(response({ text: 'Obsolete preview' }) as Response)
    await settle()
    expect(body.props.help).toBe('Native help')
    await body.input('Keep this note', false)
    await nodes.articleType.input('note', false)
    await settle()
    await tick()
    expect(previews()).toHaveLength(1)
    expect(body.value).toBe('Keep this note')
    expect(nodes.inReplyTo.value).toBe('wasalx-article:8')
  })

  test('disposes the sidebar-owned binding and aborts its pending request on unmount', async () => {
    const late = deferred<Response>()
    fetchMock.mockImplementation(async (url) => String(url).endsWith('/reply-preview')
      ? late.promise : response(panel('SENT')) as Response)
    const { body, wrapper } = open()
    await tick()
    const signal = previews()[0][1]?.signal
    wrapper.unmount()
    expect(signal?.aborted).toBe(true)
    late.resolve(response({ text: 'After teardown' }) as Response)
    await settle()
    await body.input('Unsent and retained after teardown', false)
    await tick()
    expect(previews()).toHaveLength(1)
    expect(body.props.help).toBe('Native help')
    expect(body.value).toBe('Unsent and retained after teardown')
  })

  test('releases the previous form when the ticket changes and previews only the new ticket', async () => {
    const late = deferred<Response>()
    fetchMock.mockImplementation(async (url) => String(url).endsWith('/42/reply-preview')
      ? late.promise : response(String(url).endsWith('/reply-preview')
        ? { text: 'New ticket preview' } : panel('SENT')) as Response)
    const { body: oldBody, wrapper } = open()
    await tick()
    const oldSignal = previews()[0][1]?.signal
    const next = composer({ body: 'Different unsent draft', inReplyTo: null })
    composers.push(next)
    await wrapper.setProps({ context: { ticket: { value: { internalId: 43 } }, form: next.form } })
    await tick()
    expect(oldSignal?.aborted).toBe(true)
    expect(previews().map(([url]) => url)).toEqual([
      '/api/v1/wasalx/tickets/42/reply-preview', '/api/v1/wasalx/tickets/43/reply-preview',
    ])
    late.resolve(response({ text: 'Old ticket preview' }) as Response)
    await settle()
    await oldBody.input('Still unsent in the old form', false)
    await tick()
    expect(previews()).toHaveLength(2)
    expect(oldBody.props.help).toBe('Native help')
    expect(next.body.props.help).toContain('New ticket preview')
    expect(next.body.value).toBe('Different unsent draft')
  })

  test.each(['unmount', 'replace'])('cleans a later manual binding on sidebar %s while its old nodes survive', async (action) => {
    const late = deferred<Response>()
    fetchMock.mockImplementation(async (url) => String(url).endsWith('/42/reply-preview')
      ? late.promise : response(String(url).endsWith('/reply-preview')
        ? { text: 'Current ticket preview' } : panel('SENT')) as Response)
    const value = open()
    await settle()
    await selectManually(value)
    await tick()
    const signal = previews()[0][1]?.signal
    expect(previews()).toHaveLength(1)
    let next: ReturnType<typeof composer> | undefined
    if (action === 'unmount') value.wrapper.unmount()
    else {
      next = composer({ body: 'Current ticket draft', inReplyTo: null })
      composers.push(next)
      await value.wrapper.setProps({ context: { ticket: { value: { internalId: 43 } }, form: next.form } })
      await tick()
    }
    expect(signal?.aborted).toBe(true)
    late.resolve(response({ text: 'Retired form preview' }) as Response)
    await settle()
    await value.body.input('Retired form remains unsent', false)
    await tick()
    expect(previews().filter(([url]) => String(url).endsWith('/42/reply-preview'))).toHaveLength(1)
    expect(value.body.props.help).toBe('Native help')
    expect(value.body.value).toBe('Retired form remains unsent')
    if (next) {
      expect(next.body.props.help).toContain('Current ticket preview')
      await next.body.input('Still current', false)
      await tick()
      expect(previews().filter(([url]) => String(url).endsWith('/43/reply-preview'))).toHaveLength(2)
    }
  })

  test.each(['ticket', 'form'])('old sidebar cleanup preserves a newer different-%s binding on the same editor context', async (owner) => {
    const late = deferred<Response>()
    fetchMock.mockImplementation(async (url) => String(url).endsWith('/reply-preview')
      ? late.promise : response(panel('SENT')) as Response)
    const value = open()
    await settle()
    const current = owner === 'form' ? composer() : value
    if (current !== value) composers.push(current)
    await selectManually(value, owner === 'ticket' ? 43 : 42, current.form)
    await tick()
    const signal = previews()[0][1]?.signal
    value.wrapper.unmount()
    expect(signal?.aborted).toBe(false)
    late.resolve(response({ text: 'Newer owner preview' }) as Response)
    await settle()
    expect(current.body.props.help).toContain('Newer owner preview')
    await current.body.input('Newer owner still active', false)
    await tick()
    expect(previews()).toHaveLength(2)
    expect(signal?.aborted).toBe(true)
  })
})

describe('TicketSidebarWasalx mounted agent interactions', () => {
  beforeEach(() => {
    fetchMock.mockReset()
    vi.stubGlobal('fetch', fetchMock)
  })

  afterEach(() => {
    vi.useRealTimers()
    while (mounted.length) mounted.pop()?.unmount()
    document.head.querySelector('meta[name="csrf-token"]')?.remove()
    vi.unstubAllGlobals()
  })

  test('discovers an unselected sidebar and retains one loader across selection changes', async () => {
    fetchMock.mockResolvedValue(response(panel('SENT')) as Response)
    const wrapper = mountSidebar(false)
    await settle()
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(wrapper.emitted('show')).toHaveLength(1)
    expect(wrapper.find('[data-test-id="wasalx-ticket-panel"]').exists()).toBe(false)
    await wrapper.setProps({ selected: true })
    expect(wrapper.get('[data-test-id="wasalx-ticket-panel"]').text()).toContain('Riyadh Operations')
    await wrapper.setProps({ selected: false })
    await wrapper.setProps({ selected: true })
    await settle()
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(wrapper.get('[data-test-id="wasalx-ticket-panel"]').text()).toContain('Riyadh Operations')
  })

  test.each([404, 503])('classifies an unselected sidebar response %s before selection', async (status) => {
    fetchMock.mockResolvedValueOnce(response({}, status) as Response)
    const wrapper = mountSidebar(false)
    await settle()
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(wrapper.emitted(status === 404 ? 'hide' : 'show')).toHaveLength(1)
    await wrapper.setProps({ selected: true })
    expect(wrapper.find('[data-test-id="wasalx-ticket-panel"]').exists()).toBe(false)
    expect(wrapper.find('[role="alert"]').exists()).toBe(status === 503)
    if (status === 503) {
      fetchMock.mockResolvedValueOnce(response(panel('SENT')) as Response)
      await wrapper.get('[role="alert"] button').trigger('click')
      await settle()
      expect(wrapper.get('[data-test-id="wasalx-ticket-panel"]').text()).toContain('Riyadh Operations')
    }
  })

  test('does not publish a stale parsed body after an unselected ticket changes', async () => {
    const staleBody = deferred<Panel>()
    const current = panelFor(42, 'SENT')
    current.group.name = 'Current Riyadh Operations'
    fetchMock.mockResolvedValueOnce({ ok: true, status: 200, json: () => staleBody.promise } as Response)
      .mockResolvedValueOnce(response(panelFor(43, 'SENT')) as Response)
      .mockResolvedValueOnce(response(current) as Response)
    const wrapper = mountSidebar(false)
    await settle()
    await wrapper.setProps({ context: { ticket: { value: { internalId: 43 } } } })
    await settle()
    await wrapper.setProps({ context: { ticket: { value: { internalId: 42 } } } })
    await settle()
    staleBody.resolve(panelFor(42, 'QUEUED'))
    await settle()
    await wrapper.setProps({ selected: true })
    expect(fetchMock).toHaveBeenCalledTimes(3)
    expect(wrapper.emitted('show')).toHaveLength(2)
    expect(wrapper.find('[role="alert"]').exists()).toBe(false)
    expect(wrapper.get('[data-test-id="wasalx-ticket-panel"]').text()).toContain('Current Riyadh Operations')
    expect(wrapper.text()).not.toContain('Queued')
  })

  test('ignores an unselected panel body that settles after unmount', async () => {
    const body = deferred<Panel>()
    fetchMock.mockResolvedValueOnce({ ok: true, status: 200, json: () => body.promise } as Response)
    const wrapper = mountSidebar(false)
    await settle()
    const signal = fetchMock.mock.calls[0][1]?.signal
    wrapper.unmount()
    mounted.splice(mounted.indexOf(wrapper), 1)
    expect(signal?.aborted).toBe(true)
    body.resolve(panel('SENT'))
    await settle()
    expect(wrapper.emitted('show')).toBeUndefined()
  })

  test('clears an unselected ticket removed while its response body is pending', async () => {
    const body = deferred<Panel>()
    fetchMock.mockResolvedValueOnce({ ok: true, status: 200, json: () => body.promise } as Response)
    const wrapper = mountSidebar(false)
    await settle()
    const signal = fetchMock.mock.calls[0][1]?.signal
    await wrapper.setProps({ context: { ticket: { value: undefined } } })
    await settle()
    expect(signal?.aborted).toBe(true)
    expect(wrapper.emitted('hide')).toHaveLength(1)
    body.resolve(panel('SENT'))
    await settle()
    await wrapper.setProps({ selected: true })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(wrapper.emitted('show')).toBeUndefined()
    expect(wrapper.find('[data-test-id="wasalx-ticket-panel"]').exists()).toBe(false)
    expect(wrapper.find('[role="alert"]').exists()).toBe(false)
    expect(wrapper.find('[aria-busy="true"]').exists()).toBe(false)
  })

  test('clears an unselected panel on background 404 and stops its controller on unmount', async () => {
    vi.useFakeTimers()
    fetchMock.mockResolvedValueOnce(response(panel('SENT')) as Response)
      .mockResolvedValueOnce(response({}, 404) as Response)
    const wrapper = mountSidebar(false)
    await settle()
    await vi.advanceTimersByTimeAsync(15_000)
    await settle()
    expect(wrapper.emitted('hide')).toHaveLength(1)
    await wrapper.setProps({ selected: true })
    expect(wrapper.find('[data-test-id="wasalx-ticket-panel"]').exists()).toBe(false)
    expect(wrapper.findAll('a')).toHaveLength(0)
    wrapper.unmount()
    mounted.splice(mounted.indexOf(wrapper), 1)
    await vi.advanceTimersByTimeAsync(30_000)
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  test('keeps a failed load visible and lets a keyboard user recover it', async () => {
    fetchMock
      .mockRejectedValueOnce(new Error('Control plane is temporarily unavailable.'))
      .mockResolvedValueOnce(response(panel('SENT')) as Response)

    const wrapper = mountSidebar()
    await settle()

    const alert = wrapper.get('[role="alert"]')
    expect(alert.text()).toContain('WasalX status is unavailable')
    expect(alert.text()).toContain('WasalX status could not be loaded.')
    expect(alert.text()).not.toContain('Control plane is temporarily unavailable.')
    expect(wrapper.emitted('show')).toHaveLength(1)

    const retry = alert.get('button')
    expect(retry.attributes('type')).toBe('button')
    expect(retry.attributes('tabindex')).not.toBe('-1')
    retry.element.focus()
    expect(document.activeElement).toBe(retry.element)
    await expectComponentAccessible(wrapper)

    await retry.trigger('click')
    await settle()

    expect(wrapper.find('[role="alert"]').exists()).toBe(false)
    const ticketPanel = wrapper.get('[data-test-id="wasalx-ticket-panel"]')
    expect(ticketPanel.text()).toContain('Riyadh Operations')
    expect(ticketPanel.text()).not.toMatch(/WAHA|Provider|Binding|Rule version/i)
    expect(wrapper.text()).toContain('Last activity')
    expect(wrapper.text()).toContain('Customer One')
    expect(wrapper.text()).toContain('+12025550184')
    expect(wrapper.text()).not.toContain('Connection checked')
    expect(wrapper.text()).not.toContain('Administrative access')
    expect(wrapper.text()).toContain('Connected')
    expect(wrapper.text()).not.toContain('Working')
    expect(wrapper.text()).toContain('Sent')
    expect(wrapper.get('a[href*="message=50000000-0000-4000-8000-000000000005"]').text()).toBe('Show triggering message')
    expect(wrapper.get('a[href*="message=50000000-0000-4000-8000-000000000006"]').text()).toBe('Show linked message 2')
    expect(wrapper.get('details').attributes('open')).toBeUndefined()
    expect(wrapper.get('details summary').text()).toContain('Additional linked messages')
    expect(wrapper.get('details summary').text()).toContain('1')
    expect(wrapper.emitted('show')).toHaveLength(2)
    await expectComponentAccessible(wrapper)
  })

  test('accepts a group-workspace ticket without an automation reference', async () => {
    const value = panel('SENT')
    value.ticket.reference = null
    fetchMock.mockResolvedValueOnce(response(value) as Response)

    const wrapper = mountSidebar()
    await settle()

    expect(wrapper.find('[role="alert"]').exists()).toBe(false)
    expect(wrapper.get('[data-test-id="wasalx-ticket-panel"]').text()).toContain('#420042')
    expect(wrapper.get('[data-test-id="wasalx-ticket-panel"]').text()).not.toContain('null')
  })

  test('refreshes visible delivery state without replacing the current panel with a skeleton', async () => {
    vi.useFakeTimers()
    const refreshed = deferred<Response>()
    fetchMock
      .mockResolvedValueOnce(response(panel('QUEUED')) as Response)
      .mockImplementationOnce(() => refreshed.promise)

    const wrapper = mountSidebar()
    await settle()
    expect(wrapper.text()).toContain('Queued')

    await vi.advanceTimersByTimeAsync(15_000)
    await nextTick()
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(wrapper.get('[data-test-id="wasalx-ticket-panel"]').text()).toContain('Queued')
    expect(wrapper.find('[aria-label="Loading WasalX operations"]').exists()).toBe(false)

    refreshed.resolve(response(panel('SENT')) as Response)
    await settle()
    expect(wrapper.get('[data-test-id="wasalx-ticket-panel"]').text()).toContain('Sent')
    vi.useRealTimers()
  })

  test('retains the panel through a failed background refresh and its retry', async () => {
    vi.useFakeTimers()
    const recovery = deferred<Response>()
    fetchMock
      .mockResolvedValueOnce(response(panel('QUEUED')) as Response)
      .mockRejectedValueOnce(new Error('Control plane is temporarily unavailable.'))
      .mockImplementationOnce(() => recovery.promise)

    const wrapper = mountSidebar()
    await settle()
    await vi.advanceTimersByTimeAsync(15_000)
    await settle()

    expect(wrapper.get('[data-test-id="wasalx-ticket-panel"]').text()).toContain('Queued')
    expect(wrapper.find('[aria-label="Loading WasalX operations"]').exists()).toBe(false)
    const status = wrapper.get('[role="status"]')
    expect(status.text()).toContain('WasalX status could not be loaded.')
    vi.useRealTimers()
    await expectComponentAccessible(wrapper)

    status.get('button').element.click()
    await nextTick()
    expect(wrapper.get('[data-test-id="wasalx-ticket-panel"]').text()).toContain('Queued')
    expect(wrapper.find('[aria-label="Loading WasalX operations"]').exists()).toBe(false)

    recovery.resolve(response(panel('SENT')) as Response)
    await settle()
    expect(wrapper.get('[data-test-id="wasalx-ticket-panel"]').text()).toContain('Sent')
    expect(wrapper.find('[role="status"]').exists()).toBe(false)
  })

  test('explains an unverified connection without internal system terms', async () => {
    const value = panel('SENT')
    value.connection.available = false
    value.connection.state = 'UNAVAILABLE'
    fetchMock.mockResolvedValueOnce(response(value) as Response)

    const wrapper = mountSidebar()
    await settle()

    expect(wrapper.text()).toContain('We could not verify this WhatsApp connection. Delivery updates may be delayed.')
    expect(wrapper.text()).not.toMatch(/control plane|provider outcome/iu)
  })

  test('renders pending, failed, and successful phases for a retryable delivery', async () => {
    let rejectFirstRetry: ((reason: Error) => void) | undefined
    const firstRetry = new Promise<FetchResult>((_, reject) => {
      rejectFirstRetry = reject
    })
    fetchMock
      .mockResolvedValueOnce(response(panel()) as Response)
      .mockImplementationOnce(() => firstRetry as Promise<Response>)
      .mockResolvedValueOnce(response({ state: 'QUEUED' }) as Response)
      .mockResolvedValueOnce(response(panel('SENT')) as Response)

    const wrapper = mountSidebar()
    await settle()

    const retrySection = wrapper.get('[data-test-id="wasalx-delivery-retry"]')
    expect(wrapper.get('[data-test-id="wasalx-ticket-panel"]').text()).toContain('Ready to retry')
    expect(retrySection.text()).toContain('safely queued')
    const button = retrySection.get('button')
    expect(button.attributes('type')).toBe('button')
    button.element.focus()
    expect(document.activeElement).toBe(button.element)

    await button.trigger('click')
    await nextTick()
    expect(retrySection.attributes('aria-busy')).toBe('true')
    expect(button.attributes()).toHaveProperty('disabled')
    expect(button.text()).toBe('Queueing retry…')

    rejectFirstRetry?.(new Error('socket hang up for internal-control-api.local'))
    await settle()
    const retryAlert = retrySection.get('[role="alert"]')
    expect(retryAlert.text()).toBe('The delivery could not be queued for retry.')
    expect(retryAlert.text()).not.toContain('internal-control-api.local')
    expect(retrySection.attributes('aria-busy')).toBe('false')
    expect(button.attributes()).not.toHaveProperty('disabled')
    await expectComponentAccessible(wrapper)

    await button.trigger('click')
    await settle()
    expect(wrapper.text()).toContain('Delivery was queued for retry.')
    expect(wrapper.text()).toContain('Sent')
    expect(wrapper.find('[data-test-id="wasalx-delivery-retry"]').exists()).toBe(false)
    expect(postBodies()).toEqual([
      {
        confirm_outcome_unknown: false,
        delivery_id: 'delivery-1',
        request_token: '00000000-0000-4000-8000-000000000042',
      },
      {
        confirm_outcome_unknown: false,
        delivery_id: 'delivery-1',
        request_token: '00000000-0000-4000-8000-000000000042',
      },
    ])
    await expectComponentAccessible(wrapper)
  })

  test('requires an exact typed RETRY confirmation for OUTCOME_UNKNOWN', async () => {
    const csrf = document.createElement('meta')
    csrf.name = 'csrf-token'
    csrf.content = 'csrf-test-token'
    document.head.insertAdjacentElement('beforeend', csrf)
    fetchMock
      .mockResolvedValueOnce(response(panel('OUTCOME_UNKNOWN', true)) as Response)
      .mockResolvedValueOnce(response({ state: 'QUEUED' }) as Response)
      .mockResolvedValueOnce(response(panel('QUEUED')) as Response)

    const wrapper = mountSidebar()
    await settle()

    const retrySection = wrapper.get('[data-test-id="wasalx-delivery-retry"]')
    expect(retrySection.text()).toContain('Delivery could not be confirmed')
    const input = retrySection.get('input')
    const button = retrySection.get('button')
    expect(input.attributes('aria-describedby')).toBe('wasalx-retry-warning')
    expect(input.element.closest('label')?.textContent).toContain('Type RETRY to confirm')
    expect(button.attributes()).toHaveProperty('disabled')

    await input.setValue('retry')
    expect(button.attributes()).toHaveProperty('disabled')
    await input.setValue('RETRY')
    expect(button.attributes()).not.toHaveProperty('disabled')
    input.element.focus()
    expect(document.activeElement).toBe(input.element)
    await expectComponentAccessible(wrapper)

    await button.trigger('click')
    await settle()

    expect(postBodies()).toEqual([{
      confirm_outcome_unknown: true,
      delivery_id: 'delivery-1',
      request_token: '00000000-0000-4000-8000-000000000042',
    }])
    const postOptions = fetchMock.mock.calls.find(([, options]) => options?.method === 'POST')?.[1]
    expect(postOptions?.headers).toMatchObject({ 'X-CSRF-Token': 'csrf-test-token' })
    expect(wrapper.text()).toContain('Delivery was queued for retry.')
    expect(wrapper.text()).toContain('Queued')
    await expectComponentAccessible(wrapper)
  })

  test.each([
    ['routing', 'FAILED_TERMINAL', null],
    ['acknowledgement', 'APPLIED', 'FAILED_TERMINAL'],
  ] as const)('recovers an email %s terminal failure through the visible routing action', async (_phase, routingState, acknowledgementState) => {
    const csrf = document.createElement('meta')
    csrf.name = 'csrf-token'
    csrf.content = 'csrf-test-token'
    document.head.insertAdjacentElement('beforeend', csrf)
    fetchMock
      .mockResolvedValueOnce(response(emailPanel(routingState, acknowledgementState)) as Response)
      .mockRejectedValueOnce(new Error('private upstream detail'))
      .mockResolvedValueOnce(response({ state: 'QUEUED' }) as Response)
      .mockResolvedValueOnce(response(emailPanel('APPLIED', 'SUCCEEDED')) as Response)

    const wrapper = mountSidebar()
    await settle()
    const retrySection = wrapper.get('[data-test-id="wasalx-email-routing-retry"]')
    const button = retrySection.get('button')
    await button.trigger('click')
    await settle()
    expect(retrySection.get('[role="alert"]').text()).toBe('Email routing could not be queued for retry.')
    expect(retrySection.text()).not.toContain('private upstream detail')

    await button.trigger('click')
    await settle()
    const posts = fetchMock.mock.calls.filter(([, options]) => options?.method === 'POST')
    expect(posts).toHaveLength(2)
    expect(posts[0]?.[0]).toBe('/api/v1/wasalx/tickets/42/articles/19/routing/retry')
    expect(posts[1]?.[1]?.headers).toMatchObject({ 'X-CSRF-Token': 'csrf-test-token' })
    expect(wrapper.text()).toContain('Applied')
    expect(wrapper.find('[data-test-id="wasalx-email-routing-retry"]').exists()).toBe(false)
    await expectComponentAccessible(wrapper)
  })

  test('ignores deferred retry success and failure after the agent navigates to another ticket', async () => {
    const firstRetry = deferred<Response>()
    const secondRetry = deferred<Response>()
    let retryAttempt = 0
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (init?.method === 'POST') return retryAttempt++ === 0 ? firstRetry.promise : secondRetry.promise
      const ticket = Number(/\/tickets\/(\d+)\/panel$/u.exec(path)?.[1])
      return response(panelFor(ticket)) as Response
    })
    const wrapper = mountSidebar()
    await settle()

    await wrapper.get('[data-test-id="wasalx-delivery-retry"] button').trigger('click')
    expect(retryAttempt).toBe(1)
    await wrapper.setProps({ context: { ticket: { value: { internalId: 43 } } } })
    await settle()
    expect(wrapper.text()).toContain('Jeddah Operations')
    firstRetry.resolve(response({ state: 'QUEUED' }) as Response)
    await settle()
    expect(wrapper.text()).toContain('Jeddah Operations')
    expect(wrapper.text()).not.toContain('Delivery was queued for retry.')
    expect(wrapper.find('[data-test-id="wasalx-delivery-retry"] button').attributes()).not.toHaveProperty('disabled')

    await wrapper.get('[data-test-id="wasalx-delivery-retry"] button').trigger('click')
    expect(retryAttempt).toBe(2)
    await wrapper.setProps({ context: { ticket: { value: { internalId: 42 } } } })
    await settle()
    expect(wrapper.text()).toContain('Riyadh Operations')
    secondRetry.reject(new Error('stale retry failure'))
    await settle()
    expect(wrapper.text()).toContain('Riyadh Operations')
    expect(wrapper.text()).not.toContain('The delivery could not be queued for retry.')
    expect(wrapper.find('[data-test-id="wasalx-delivery-retry"] button').attributes()).not.toHaveProperty('disabled')
  })
})


function mountMobileOperations(): VueWrapper {
  const wrapper = mount(TicketInformationWasalx, {
    attachTo: document.body,
    global: {
      provide: { 'wasalx-mobile-ticket-information': { ticket: ref({ internalId: 42 }) } },
      config: { globalProperties: { $t: (message: string) => message } },
      stubs: { RouterLink: { props: ['to'], template: '<a :href="typeof to === \'string\' ? to : `/wasalx/groups?group=${to.query.group}&message=${to.query.message}`"><slot /></a>' } },
    },
  })
  mounted.push(wrapper)
  return wrapper
}

describe.each(['desktop', 'mobile'] as const)('%s shared ticket operations', (view) => {
  beforeEach(() => {
    fetchMock.mockReset()
    vi.stubGlobal('fetch', fetchMock)
  })
  afterEach(() => {
    vi.useRealTimers()
    while (mounted.length) mounted.pop()?.unmount()
    document.head.querySelector('meta[name="csrf-token"]')?.remove()
    vi.unstubAllGlobals()
  })

  const open = () => view === 'desktop' ? mountSidebar() : mountMobileOperations()
  test('preserves permission denial and exact triggering-message destination', async () => {
    const value = panel('SENT')
    value.can_retry = false
    fetchMock.mockResolvedValue(response(value) as Response)
    const wrapper = open()
    await flushPromises()
    expect(wrapper.find('[data-test-id="wasalx-delivery-retry"]').exists()).toBe(false)
    expect(wrapper.findAll('a').map(link => link.attributes('href'))).toContain(`/wasalx/groups?group=${value.message_contexts[0].group_id}&message=${value.message_contexts[0].message_id}`)
    expect(wrapper.text()).toContain('Human support')
    await expectComponentAccessible(wrapper)
  })
  test('requires exact confirmation for outcome-unknown and submits one existing retry contract', async () => {
    fetchMock.mockResolvedValue(response(panel('OUTCOME_UNKNOWN', true)) as Response)
    const wrapper = open()
    await flushPromises()
    const region = wrapper.get('[data-test-id="wasalx-delivery-retry"]')
    const submit = region.get('button')
    expect(submit.attributes('disabled')).toBeDefined()
    await region.get('input').setValue('RETRY')
    fetchMock.mockImplementation(async (url) => String(url).endsWith('/retry') ? response({}) as Response : response(panel('SENT')) as Response)
    await submit.trigger('click')
    await flushPromises()
    expect(fetchMock.mock.calls.filter(([url]) => String(url).endsWith('/retry'))).toHaveLength(1)
  })
  test('keeps safe dependency recovery visible', async () => {
    fetchMock.mockResolvedValue(response({}, 503) as Response)
    const wrapper = open()
    await flushPromises()
    expect(wrapper.text()).toContain('WasalX status is unavailable')
    expect(wrapper.text()).toContain('Retry status check')
  })
  test('does not expose operations or retries for an ordinary ticket', async () => {
    fetchMock.mockResolvedValue(response({}, 404) as Response)
    const wrapper = open()
    await flushPromises()
    expect(wrapper.find('[data-test-id="wasalx-ticket-panel"]').exists()).toBe(false)
    expect(wrapper.find('[data-test-id="wasalx-delivery-retry"]').exists()).toBe(false)
    if (view === 'mobile') expect(wrapper.text()).toContain('No WasalX operations are available for this ticket.')
  })
})

test('mobile background 404 removes old status and exact triggering-message context', async () => {
  vi.useFakeTimers()
  fetchMock.mockReset()
  vi.stubGlobal('fetch', fetchMock)
  try {
    fetchMock.mockResolvedValueOnce(response(panel('SENT')) as Response).mockResolvedValueOnce(response({}, 404) as Response)
    const wrapper = mountMobileOperations()
    await flushPromises()
    expect(wrapper.text()).toContain('Human support')
    Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' })
    await vi.advanceTimersByTimeAsync(15_000)
    await flushPromises()
    expect(wrapper.find('[data-test-id="wasalx-ticket-panel"]').exists()).toBe(false)
    expect(wrapper.findAll('a').some(link => link.attributes('href')?.includes('?group='))).toBe(false)
    expect(wrapper.text()).not.toContain('Human support')
    expect(wrapper.text()).toContain('No WasalX operations are available for this ticket.')
  } finally {
    while (mounted.length) mounted.pop()?.unmount()
    vi.useRealTimers()
    vi.unstubAllGlobals()
    delete (document as unknown as { visibilityState?: string }).visibilityState
  }
})

describe('direct ticket customer-service window', () => {
  const composers: ReturnType<typeof composer>[] = []
  const start = Date.parse('2026-08-12T10:00:00.000Z')
  const open = (expiresAt: string | null | undefined) => {
    const value = panel('SENT')
    if (expiresAt !== undefined) value.service_window_expires_at = expiresAt
    fetchMock.mockImplementation(async (url) => response(String(url).endsWith('/reply-preview')
      ? { text: 'Prepared reply' } : value) as Response)
    const draft = composer()
    composers.push(draft)
    return { ...draft, wrapper: mountSidebar(true, draft.form) }
  }
  const line = (wrapper: VueWrapper) => wrapper.find('[data-test-id="wasalx-service-window"]')
  const blocker = (body: FormKitNode) => body.store.wasalxServiceWindowClosed
  const advance = async (milliseconds: number) => {
    await vi.advanceTimersByTimeAsync(milliseconds)
    await settle()
  }
  beforeEach(() => {
    vi.useFakeTimers({ now: start })
    fetchMock.mockReset()
    vi.stubGlobal('fetch', fetchMock)
  })
  afterEach(() => {
    while (mounted.length) mounted.pop()?.unmount()
    while (composers.length) composers.pop()?.root.destroy()
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  test('counts down open and closing, then blocks only public free text once closed', async () => {
    const { wrapper, body, nodes } = open(new Date(start + 3 * 60 * 60 * 1000).toISOString())
    await settle()
    expect(line(wrapper).get('dd').attributes('data-state')).toBe('open')
    expect(line(wrapper).text()).toContain('Customer-service window')
    expect(line(wrapper).text()).toContain('Send window expires')
    expect(line(wrapper).text()).toContain('in 3 hours')
    expect(blocker(body)).toBeUndefined()

    await advance(2 * 60 * 60 * 1000 + 30 * 60 * 1000)
    expect(line(wrapper).get('dd').attributes('data-state')).toBe('closing')
    expect(line(wrapper).text()).toContain('in 30 minutes')
    expect(blocker(body)).toBeUndefined()

    await advance(30 * 60 * 1000)
    expect(line(wrapper).get('dd').attributes('data-state')).toBe('closed')
    expect(line(wrapper).text()).toContain('Window closed: send an approved template')
    expect(blocker(body)).toMatchObject({ blocking: true, visible: true,
      value: 'Window closed: send an approved template' })
    await expectComponentAccessible(wrapper)

    await nodes.internal.input(true, false)
    await settle()
    expect(blocker(body)).toBeUndefined()
    await nodes.internal.input(false, false)
    await settle()
    expect(blocker(body)).toMatchObject({ blocking: true })
    wrapper.unmount()
    expect(blocker(body)).toBeUndefined()
  })

  test.each([undefined, null, 'not-a-time'])('shows no window and never blocks when the expiry is %s', async (expiresAt) => {
    const { wrapper, body } = open(expiresAt)
    await settle()
    expect(wrapper.get('[data-test-id="wasalx-ticket-panel"]').exists()).toBe(true)
    expect(line(wrapper).exists()).toBe(false)
    await advance(48 * 60 * 60 * 1000)
    expect(line(wrapper).exists()).toBe(false)
    expect(blocker(body)).toBeUndefined()
  })
})
