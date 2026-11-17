// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'

import { enableAutoUnmount, flushPromises, mount } from '@vue/test-utils'
import axe from 'axe-core'
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { nextTick, ref } from 'vue'

import WasalxGroups from '../../zammad-package/app/frontend/apps/desktop/pages/wasalx-groups/views/WasalxGroups.vue'
import {
  clearGroupSendRecovery, composerRecoveryScope, readGroupSendRecovery, writeGroupSendRecovery,
} from '../../zammad-package/app/frontend/apps/desktop/pages/wasalx-groups/composerRecovery'
import { replace, route } from './stubs/vue-router'

const groupId = '12000000-0000-4000-8000-000000000001'
const secondGroupId = '12000000-0000-4000-8000-000000000002'
const messageId = '13000000-0000-4000-8000-000000000001'
const wahaMediaCapabilities = {
  accepted: [
    { mime_type: 'image/png', maximum_bytes: 15_000_000 },
    { mime_type: 'audio/webm', maximum_bytes: 25_000_000 },
  ],
  voice_recording: true,
}
const metaMediaCapabilities = {
  accepted: [
    { mime_type: 'image/png', maximum_bytes: 5 * 1024 * 1024 },
    { mime_type: 'audio/ogg', maximum_bytes: 16 * 1024 * 1024 },
    { mime_type: 'video/mp4', maximum_bytes: 16 * 1024 * 1024 },
  ],
  voice_recording: false,
}
const fetchMock = vi.fn<typeof fetch>()
enableAutoUnmount(afterEach)
let mediaTrackStop: ReturnType<typeof vi.fn>
let messageSnapshot: Array<Record<string, unknown>>

class FakeMediaRecorder {
  static deferStop = false
  static deferredStops: Array<() => void> = []
  static isTypeSupported(type: string) { return type.startsWith('audio/webm') }
  static flushNextStop() { this.deferredStops.shift()?.() }
  state = 'inactive'
  private readonly listeners = new Map<string, Array<EventListenerOrEventListenerObject>>()

  addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener])
  }

  start() { this.state = 'recording' }
  stop() {
    this.state = 'inactive'
    const finish = () => {
      const data = Object.assign(new Event('dataavailable'), { data: new Blob([Uint8Array.from([1, 2, 3])], { type: 'audio/webm' }) })
      this.emit('dataavailable', data)
      this.emit('stop', new Event('stop'))
    }
    if (FakeMediaRecorder.deferStop) FakeMediaRecorder.deferredStops.push(finish)
    else finish()
  }

  private emit(type: string, event: Event) {
    for (const listener of this.listeners.get(type) ?? []) {
      if (typeof listener === 'function') listener(event)
      else listener.handleEvent(event)
    }
  }
}

const response = (body: unknown) => ({ ok: true, status: 200, json: async () => body }) as Response
const errorResponse = (status = 503) => ({ ok: false, status, json: async () => ({ error: 'unavailable' }) }) as Response
const groupPage = (items: unknown[], nextCursor: string | null = null) => ({ items, next_cursor: nextCursor })
const deferred = <T,>() => {
  let resolve!: (value: T) => void
  let reject!: (reason?: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

describe('WhatsApp Groups workspace', () => {
  test('initial populated conversation anchors after rendering without animation', async () => {
    const previous = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'scrollTo')
    const calls: Array<{ timeline: boolean; options: ScrollToOptions }> = []
    Object.defineProperty(HTMLElement.prototype, 'scrollTo', { configurable: true, value: function (this: HTMLElement, options: ScrollToOptions) {
      calls.push({ timeline: this.classList.contains('wasalx-timeline'), options })
    } })
    try {
      const wrapper = mount(WasalxGroups, {
        global: { config: { globalProperties: { $t: (message: string) => message } } },
      })
      await flushPromises()
      await nextTick()
      expect(wrapper.text()).toContain('Shipment SHIP-42')
      expect(calls.some(call => call.timeline && call.options.behavior === 'auto')).toBe(true)
    } finally {
      if (previous) Object.defineProperty(HTMLElement.prototype, 'scrollTo', previous)
      else Reflect.deleteProperty(HTMLElement.prototype, 'scrollTo')
    }
  })

  test.each([false, true])('follows content growth and viewport shrink but preserves history scrolling (scroll event first: %s)', async (scrollEventFirst) => {
    const observed = new Set<Element>()
    let resize: (target: Element) => void = () => {}
    vi.stubGlobal('ResizeObserver', class {
      constructor(callback: ResizeObserverCallback) {
        resize = (target) => { if (observed.has(target)) callback([], {} as ResizeObserver) }
      }
      observe(target: Element) { observed.add(target) }
      disconnect() { observed.clear() }
    })
    const previous = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'scrollTo')
    const calls: number[] = []
    Object.defineProperty(HTMLElement.prototype, 'scrollTo', { configurable: true, value: function (this: HTMLElement, options: ScrollToOptions) {
      calls.push(Number(options.top))
      this.scrollTop = Math.max(0, Number(options.top) - this.clientHeight)
    } })
    try {
      const wrapper = mount(WasalxGroups, { global: { config: { globalProperties: { $t: (message: string) => message } } } })
      await flushPromises()
      const timeline = wrapper.get('.wasalx-timeline').element as HTMLElement
      const list = timeline.querySelector('ol')!
      let height = 4819
      let clientHeight = 585
      Object.defineProperties(timeline, {
        scrollHeight: { configurable: true, get: () => height },
        clientHeight: { configurable: true, get: () => clientHeight },
        scrollTop: { configurable: true, writable: true, value: 4234 },
      })
      resize(list)
      await flushPromises()
      height = 4974
      resize(list)
      await flushPromises()
      expect(timeline.scrollTop).toBe(4389)
      clientHeight = 430
      if (scrollEventFirst) timeline.dispatchEvent(new Event('scroll'))
      resize(timeline)
      if (!scrollEventFirst) timeline.dispatchEvent(new Event('scroll'))
      await flushPromises()
      expect(timeline.scrollTop).toBe(4544)
      const settled = calls.length
      resize(list)
      resize(timeline)
      await flushPromises()
      expect(calls).toHaveLength(settled)
      timeline.scrollTop = 100
      timeline.dispatchEvent(new Event('scroll'))
      const before = calls.length
      height = 5129
      clientHeight = 300
      resize(list)
      resize(timeline)
      await flushPromises()
      expect(calls).toHaveLength(before)
      expect(timeline.scrollTop).toBe(100)
      wrapper.unmount()
      expect(observed.size).toBe(0)
    } finally {
      if (previous) Object.defineProperty(HTMLElement.prototype, 'scrollTo', previous)
      else Reflect.deleteProperty(HTMLElement.prototype, 'scrollTo')
    }
  })

  beforeEach(() => {
    route.query = {}
    replace.mockReset()
    clearGroupSendRecovery(composerRecoveryScope('test-csrf-token'), groupId)
    clearGroupSendRecovery(composerRecoveryScope('test-csrf-token'), secondGroupId)
    fetchMock.mockReset()
    vi.mocked(globalThis.crypto.randomUUID).mockReturnValue('00000000-0000-4000-8000-000000000042')
    vi.stubGlobal('fetch', fetchMock)
    vi.stubGlobal('MediaRecorder', FakeMediaRecorder)
    FakeMediaRecorder.deferStop = false
    FakeMediaRecorder.deferredStops = []
    mediaTrackStop = vi.fn()
    messageSnapshot = [
      { id: messageId, participant_name: 'Customer', sender_phone: '+12025550184', message_text: 'Shipment SHIP-42', from_me: false, provider_timestamp: '2026-08-20T10:00:00.000Z', latest_mutation: null, quote_allowed: true, ticket_creatable: true, linked_to_ticket: false },
    ]
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: { getUserMedia: vi.fn(async () => ({ getTracks: () => [{ stop: mediaTrackStop }] })) },
    })
    const csrf = document.createElement('meta')
    csrf.name = 'csrf-token'
    csrf.content = 'test-csrf-token'
    document.head.appendChild(csrf)
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 2, send_available: true, reactions_available: true, media_capabilities: wahaMediaCapabilities },
        { id: '12000000-0000-4000-8000-000000000002', name: 'Jeddah Team', access_scope: 'TEAM', unread_count: 0, send_available: false, reactions_available: false, media_capabilities: metaMediaCapabilities },
      ]))
      if (path.endsWith('/group_workspace/ticket_groups')) return response([
        { id: '4', name: 'Customer Care' },
      ])
      if (path.includes('/participants?')) return response([
        { id: '14165550167@lid', name: 'Customer One', phone: '+12025550184' },
      ])
      if (path.includes('/api/v1/upload_caches/')) {
        if (init?.method === 'DELETE') return response({ success: true })
        const file = (init?.body as FormData).get('File') as File
        return response({ data: { id: 27, filename: file.name, size: String(file.size), contentType: file.type } })
      }
      if (path.includes('/messages/') && path.endsWith('/context')) return response([
        { id: messageId, participant_name: 'Customer', sender_phone: '+12025550184', message_text: 'Shipment SHIP-42', from_me: false, provider_timestamp: '2026-08-20T10:00:00.000Z', latest_mutation: null, quote_allowed: true, ticket_creatable: true, linked_to_ticket: false },
      ])
      if (path.includes('/messages?')) return response(messageSnapshot)
      if (init?.method === 'POST' && path.includes(`/messages/${messageId}/tickets`)) return response({ ticket_id: '43', ticket_number: '1043', article_id: '92' })
      if (init?.method === 'POST' && path.endsWith('/ticket_links')) return response({ ticket_id: '42', ticket_number: '1042', article_id: '91' })
      if (init?.method === 'POST' && path.endsWith(`/messages/${messageId}/reactions`)) return response({ id: 'reaction-delivery', state: 'QUEUED', duplicate: false })
      if (path.includes('/tickets?')) return response({ items: [
        { ticket_id: '42', ticket_number: '1042', reference: 'SHIP-42', state_category: 'OPEN', links: [{ article_id: '91', message_id: messageId }] },
        { ticket_id: '44', ticket_number: '1044', reference: 'Resolved shipment', state_category: 'CLOSED', links: [] },
      ], next_cursor: null })
      if (init?.method === 'POST' && path.endsWith('/send')) {
        const payload = JSON.parse(String(init.body)) as { message: string, upload_store_ids?: number[] }
        return response({
        id: '14000000-0000-4000-8000-000000000001', participant_name: 'Agent One', sender_phone: '+13125550190', message_text: payload.message,
        from_me: true, provider_timestamp: '2026-08-20T10:01:00.000Z', latest_mutation: null, quote_allowed: false,
        ticket_creatable: false, linked_to_ticket: false, source_kind: 'DELIVERY', delivery_state: 'QUEUED',
      })
      }
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
  })

  afterEach(() => {
    vi.useRealTimers()
    document.documentElement.lang = 'en'
    document.querySelector('meta[name="csrf-token"]')?.remove()
    Reflect.deleteProperty(navigator, 'mediaDevices')
    vi.unstubAllGlobals()
  })

  test('retries initial catalog failure with the requested group instead of the first group', async () => {
    route.query = { group: secondGroupId }
    const normal = fetchMock.getMockImplementation()!
    let first = true
    fetchMock.mockImplementation(async (input, init) => {
      if (String(input).includes('/group_workspace/groups?') && first) {
        first = false
        return new Response('{}', { status: 503 })
      }
      return normal(input, init)
    })
    const wrapper = mount(WasalxGroups, { global: { config: { globalProperties: { $t: (s: string) => s } }, stubs: { RouterLink: true } } })
    await flushPromises()
    expect(wrapper.text()).toContain('WhatsApp Groups is unavailable')
    await wrapper.findAll('button').find(b => b.text() === 'Try again')!.trigger('click')
    await flushPromises()
    expect(wrapper.find('.wasalx-conversation').attributes('aria-label')).toBe('Jeddah Team')
    expect(fetchMock.mock.calls.some(([url]) => String(url).includes(`/groups/${secondGroupId}/messages?`))).toBe(true)
    expect(wrapper.find(`[data-message-id="${messageId}"]`).exists()).toBe(true)
  })

  test('repeated exact jumps focus the current timeline rather than another mounted page', async () => {
    const duplicate = document.createElement('div')
    duplicate.dataset.messageId = messageId
    duplicate.tabIndex = -1
    document.body.appendChild(duplicate)
    const wrapper = mount(WasalxGroups, { attachTo: document.body, global: { config: { globalProperties: { $t: (s: string) => s } }, stubs: { RouterLink: true } } })
    try {
      await flushPromises()
      for (let i = 0; i < 2; i++) {
        await wrapper.findAll('button').find(b => b.text().startsWith('Show linked message'))!.trigger('click')
        await flushPromises()
        expect(document.activeElement).toBe(wrapper.get(`[data-message-id="${messageId}"]`).element)
        expect(document.activeElement).not.toBe(duplicate)
        await wrapper.findAll('button').find(b => b.text() === 'Return to latest')!.trigger('click')
        await flushPromises()
      }
    } finally { wrapper.unmount(); duplicate.remove() }
  })

  test('does not focus after unmount while exact-message route navigation is pending', async () => {
    const navigation = deferred<undefined>()
    const wrapper = mount(WasalxGroups, { attachTo: document.body, global: { config: { globalProperties: { $t: (s: string) => s } }, stubs: { RouterLink: true } } })
    await flushPromises()
    const focus = vi.spyOn(HTMLElement.prototype, 'focus')
    replace.mockImplementationOnce(() => navigation.promise)
    try {
      await wrapper.findAll('button').find(b => b.text().startsWith('Show linked message'))!.trigger('click')
      await flushPromises()
      wrapper.unmount()
      focus.mockClear()
      navigation.resolve(undefined)
      await flushPromises()
      expect(focus).not.toHaveBeenCalled()
    } finally { focus.mockRestore() }
  })

  test('recovers the exact idempotent send after a hard module reload', async () => {
    const scope = composerRecoveryScope('test-csrf-token')
    writeGroupSendRecovery(scope, {
      groupId, signature: 'same-payload', token: '00000000-0000-4000-8000-000000000090', message: 'Hard reload proof',
      replyToMessage: null, mentions: [], uploadCacheId: '00000000-0000-4000-8000-000000000091',
      attachments: [{ id: 91, filename: 'proof.png', size: 4, contentType: 'image/png' }],
    })

    vi.resetModules()
    const reloaded = await import('../../zammad-package/app/frontend/apps/desktop/pages/wasalx-groups/composerRecovery')
    expect(reloaded.readGroupSendRecovery(scope, groupId)).toMatchObject({
      signature: 'same-payload', token: '00000000-0000-4000-8000-000000000090', message: 'Hard reload proof',
      attachments: [{ id: 91, filename: 'proof.png' }],
    })
  })

  test('keeps the latest in-memory recovery when browser storage stops accepting writes', () => {
    const scope = composerRecoveryScope('test-csrf-token')
    const recovery = {
      groupId, signature: 'old-payload', token: 'old-token', message: 'Older reply',
      replyToMessage: null, mentions: [], uploadCacheId: 'cache-id', attachments: [],
    }
    writeGroupSendRecovery(scope, recovery)
    const setItem = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new DOMException('Full', 'QuotaExceededError') })
    const removeItem = vi.spyOn(Storage.prototype, 'removeItem').mockImplementation(() => { throw new DOMException('Denied', 'SecurityError') })
    try {
      writeGroupSendRecovery(scope, { ...recovery, signature: 'new-payload', token: 'new-token', message: 'Latest reply' })
      expect(readGroupSendRecovery(scope, groupId)).toMatchObject({ token: 'new-token', message: 'Latest reply' })
      // A delayed old acknowledgement must never clear the newer draft.
      clearGroupSendRecovery(scope, groupId, 'old-token')
      expect(readGroupSendRecovery(scope, groupId)?.token).toBe('new-token')
      clearGroupSendRecovery(scope, groupId, 'new-token')
      expect(readGroupSendRecovery(scope, groupId)).toBeUndefined()
    } finally {
      setItem.mockRestore()
      removeItem.mockRestore()
      sessionStorage.clear()
    }
  })

  test('shows every selected attachment immediately while the send is pending', async () => {
    const original = fetchMock.getMockImplementation()
    let uploadId = 30
    const pendingSend = deferred<Response>()
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/api/v1/upload_caches/') && init?.method === 'POST') {
        const file = (init.body as FormData).get('File') as File
        return response({ data: { id: uploadId++, filename: file.name, size: String(file.size), contentType: file.type } })
      }
      if (init?.method === 'POST' && path.endsWith('/send')) return pendingSend.promise
      assert.ok(original)
      return original(input, init)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const input = wrapper.get('input[type="file"]')
    const files = [
      new File([Uint8Array.from([1])], 'front.png', { type: 'image/png' }),
      new File([Uint8Array.from([2])], 'back.png', { type: 'image/png' }),
    ]
    Object.defineProperty(input.element, 'files', { configurable: true, value: files })
    await input.trigger('change')
    await flushPromises()
    await wrapper.get('form').trigger('submit')
    await nextTick()

    expect(wrapper.text()).toContain('front.png')
    expect(wrapper.text()).toContain('back.png')
    expect(wrapper.text()).toContain('Sending…')

    pendingSend.resolve(response({
      id: '14000000-0000-4000-8000-000000000099', participant_name: 'Agent One', message_text: null,
      from_me: true, provider_timestamp: '2026-08-20T10:01:00.000Z', latest_mutation: null, quote_allowed: false,
      ticket_creatable: false, linked_to_ticket: false, source_kind: 'DELIVERY', delivery_state: 'QUEUED',
    }))
    await flushPromises()
    wrapper.unmount()
  })

  test.each([false, true])('contains the hidden composer label without breaking its accessible target (mobile=%s)', async (mobile) => {
    const wrapper = mount(WasalxGroups, {
      props: { mobile },
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const composer = wrapper.get<HTMLTextAreaElement>('#wasalx-group-message')
    const label = wrapper.get<HTMLLabelElement>('label[for="wasalx-group-message"]')
    const containingBlock = composer.element.parentElement
    // The absolute sr-only label must share the composer's positioned scroll boundary.
    expect(containingBlock?.classList.contains('relative')).toBe(true)
    expect(label.element.parentElement).toBe(containingBlock)
    expect(label.element.control).toBe(composer.element)
    expect(wrapper.get('a[href="#wasalx-group-message"]').text()).toBe('Skip to message composer')
    wrapper.unmount()
  })

  test('covers filters, transcript, exact ticket jump, message context, and accessibility', async () => {
    const wrapper = mount(WasalxGroups, {
      attachTo: document.body,
      global: {
        config: { globalProperties: { $t: (message: string) => message } },
        stubs: { RouterLink: { props: ['to'], template: '<a :href="to"><slot /></a>' } },
      },
    })
    await flushPromises()
    await nextTick()

    expect(wrapper.text()).toContain('Riyadh Operations')
    expect(wrapper.text()).toContain('Shipment SHIP-42')
    expect(wrapper.text()).toContain('+12025550184')
    expect(wrapper.text()).toContain('WhatsApp contact')
    expect(wrapper.text()).toContain('Ticket #1042')
    expect(wrapper.get('a[href="#wasalx-group-message"]').text()).toBe('Skip to message composer')
    expect(wrapper.findAll('button').some((button) => button.text() === 'Load earlier messages')).toBe(false)
    expect(wrapper.find('a[href="/tickets/42#article-91"]').exists()).toBe(true)
    for (const label of ['My Groups', 'My Team', 'Unassigned', 'All Accessible'])
      expect(wrapper.findAll('button').some((button) => button.text() === label)).toBe(true)
    const selectedGroup = wrapper.findAll('button').find((button) => button.text().includes('Riyadh Operations'))
    assert.ok(selectedGroup)
    expect(selectedGroup.attributes('aria-current')).toBe('true')
    await wrapper.findAll('button').find((button) => button.text() === 'All Accessible')?.trigger('click')
    await flushPromises()
    const otherGroup = wrapper.findAll('button').find((button) => button.text().includes('Jeddah Team'))
    assert.ok(otherGroup)
    expect(otherGroup.attributes()).not.toHaveProperty('aria-current')

    const showMessage = wrapper.findAll('button').find((button) => button.text().startsWith('Show linked message'))
    assert.ok(showMessage)
    expect(showMessage.text()).toContain('Customer')
    expect(showMessage.text()).toContain('Shipment SHIP-42')
    expect(showMessage.classes()).toContain('min-h-8')
    await showMessage.trigger('click')
    await flushPromises()
    expect(document.activeElement?.getAttribute('data-message-id')).toBe(messageId)

    const quote = wrapper.findAll('button').find((button) => button.text() === 'Quote')
    assert.ok(quote)
    expect(quote.classes()).toContain('min-h-8')
    await quote.trigger('click')
    await wrapper.get('textarea').setValue('Checking shipment 42 now.')
    await wrapper.get('form').trigger('submit')
    await flushPromises()
    const sendRequest = fetchMock.mock.calls.find(([input, init]) => String(input).endsWith('/send') && init?.method === 'POST')
    assert.ok(sendRequest)
    const payload = JSON.parse(String(sendRequest[1]?.body))
    const headers = new Headers(sendRequest[1]?.headers)
    assert.equal(payload.message, 'Checking shipment 42 now.')
    assert.equal(payload.reply_to_message_id, messageId)
    assert.match(payload.request_token, /^[0-9a-f-]{36}$/iu)
    expect(headers.get('content-type')).toBe('application/json')
    expect(headers.get('x-csrf-token')).toBe('test-csrf-token')
    const readRequest = fetchMock.mock.calls.find(([input, init]) => String(input).endsWith('/read') && init?.method === 'POST')
    assert.ok(readRequest)
    expect(new Headers(readRequest[1]?.headers).get('x-csrf-token')).toBe('test-csrf-token')
    expect(wrapper.get('textarea').element.value).toBe('')
    expect(wrapper.text()).not.toContain('Replying to')
    expect(wrapper.text()).toContain('Queued')
    expect(wrapper.text()).toContain('Agent One')
    expect(wrapper.text()).toContain('+13125550190')
    expect(wrapper.text()).toContain('Sent through')

    await wrapper.get('textarea').setValue('@Cus')
    await wrapper.get('textarea').trigger('input')
    await new Promise((resolve) => setTimeout(resolve, 180))
    await flushPromises()
    const mention = wrapper.findAll('[role="option"]').find((option) => option.text().includes('Customer One'))
    assert.ok(mention)
    expect(mention.attributes('tabindex')).toBe('-1')
    expect(mention.text()).toContain('+12025550184')
    expect(mention.text()).not.toContain('14165550167')
    await mention.trigger('click')
    expect(wrapper.get('textarea').element.value).toBe('@12025550184 ')
    await wrapper.get('textarea').setValue('@12025550184 please review')
    await wrapper.get('form').trigger('submit')
    await flushPromises()
    const mentionSend = fetchMock.mock.calls.filter(([input, init]) => String(input).endsWith('/send') && init?.method === 'POST').at(-1)
    assert.ok(mentionSend)
    assert.deepEqual(JSON.parse(String(mentionSend[1]?.body)).mentions, ['14165550167@lid'])

    const fileInput = wrapper.get('input[type="file"]')
    expect(fileInput.attributes()).toHaveProperty('hidden')
    const file = new File([Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0])], 'proof.png', { type: 'image/png' })
    Object.defineProperty(fileInput.element, 'files', { configurable: true, value: [file] })
    await fileInput.trigger('change')
    await flushPromises()
    expect(wrapper.text()).toContain('proof.png')
    await wrapper.findAll('form').find((form) => form.attributes('aria-busy') !== undefined)?.trigger('submit')
    await flushPromises()
    const mediaSend = fetchMock.mock.calls.filter(([input, init]) => String(input).endsWith('/send') && init?.method === 'POST').at(-1)
    assert.ok(mediaSend)
    const mediaPayload = JSON.parse(String(mediaSend[1]?.body))
    assert.deepEqual(mediaPayload.upload_store_ids, [27])
    assert.match(mediaPayload.upload_cache_id, /^[0-9a-f-]{36}$/iu)
    expect(wrapper.text()).toContain('proof.png')
    expect(wrapper.text()).toContain('Preparing attachment…')
    expect(wrapper.text()).not.toContain('Unsupported message')
    expect(wrapper.findAll('button').filter((button) => button.text() === 'Link to ticket')).toHaveLength(1)

    await wrapper.findAll('button').find((button) => button.text() === 'Record voice')?.trigger('click')
    await flushPromises()
    expect(wrapper.text()).toContain('Recording…')
    await wrapper.findAll('button').find((button) => button.text() === 'Stop recording')?.trigger('click')
    await flushPromises()
    await nextTick()
    expect(mediaTrackStop).toHaveBeenCalledOnce()
    expect(wrapper.text()).toMatch(/voice-.*\.webm/u)
    await wrapper.get('form').trigger('submit')
    await flushPromises()
    const voiceUpload = fetchMock.mock.calls
      .filter(([input, init]) => String(input).includes('/api/v1/upload_caches/') && init?.method === 'POST')
      .at(-1)
    assert.ok(voiceUpload)
    const voiceFile = (voiceUpload[1]?.body as FormData).get('File') as File
    assert.equal(voiceFile.type, 'audio/webm')
    assert.ok(voiceFile.size > 0)

    await wrapper.findAll('button').find((button) => button.text() === 'Closed')?.trigger('click')
    expect(wrapper.text()).toContain('Resolved shipment')
    await wrapper.findAll('button').find((button) => button.text() === 'Open')?.trigger('click')
    expect(wrapper.text()).toContain('Ticket #1042')

    const createTicket = wrapper.findAll('button').find((button) => button.text() === 'Create ticket')
    assert.ok(createTicket)
    await createTicket.trigger('click')
    await flushPromises()
    expect((wrapper.get('input[id^="wasalx-ticket-title-"]').element as HTMLInputElement).value).toBe('Riyadh Operations — Shipment SHIP-42')
    expect(wrapper.get('select').element.value).toBe('4')
    await wrapper.findAll('form').find((form) => form.text().includes('Create a ticket from this message'))?.trigger('submit')
    await flushPromises()
    const createRequest = fetchMock.mock.calls.find(([input, init]) => String(input).endsWith(`/messages/${messageId}/tickets`) && init?.method === 'POST')
    assert.ok(createRequest)
    assert.deepEqual(JSON.parse(String(createRequest[1]?.body)).target_group_id, '4')
    expect(wrapper.text()).toContain('Open ticket #1043')

    const linkTicket = wrapper.findAll('button').find((button) => button.text() === 'Link to ticket')
    assert.ok(linkTicket)
    await linkTicket.trigger('click')
    await wrapper.get('input[id^="wasalx-ticket-number-"]').setValue('1042')
    await wrapper.findAll('form').find((form) => form.text().includes('Link this message to a ticket'))?.trigger('submit')
    await flushPromises()
    const linkRequest = fetchMock.mock.calls.find(([input, init]) => String(input).endsWith('/ticket_links') && init?.method === 'POST')
    assert.ok(linkRequest)
    assert.equal(JSON.parse(String(linkRequest[1]?.body)).ticket_number, '1042')

    await wrapper.findAll('button').find((button) => button.text() === 'My Team')?.trigger('click')
    await wrapper.findAll('button').find((button) => button.text().includes('Jeddah Team'))?.trigger('click')
    await flushPromises()
    expect(wrapper.find('form').exists()).toBe(false)
    expect(wrapper.text()).toContain('Messaging is unavailable until the WhatsApp connection recovers.')

    await wrapper.findAll('button').find((button) => button.text() === 'Unassigned')?.trigger('click')
    await flushPromises()
    expect(wrapper.text()).toContain('No groups in this view.')
    expect(wrapper.text()).toContain('Choose a group to view its conversation.')
    expect(wrapper.text()).not.toContain('Jeddah Team')

    const result = await axe.run(wrapper.element, { rules: { 'color-contrast': { enabled: false } } })
    expect(result.violations).toEqual([])
    wrapper.unmount()
  })

  test('keeps inbound messages unread while browsing earlier content and advances the cursor on return', async () => {
    vi.useFakeTimers()
    const wrapper = mount(WasalxGroups, {
      attachTo: document.body,
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const timeline = wrapper.get('.wasalx-timeline').element as HTMLElement
    Object.defineProperties(timeline, {
      scrollHeight: { configurable: true, value: 1_000 },
      clientHeight: { configurable: true, value: 200 },
      scrollTop: { configurable: true, writable: true, value: 120 },
    })
    fetchMock.mockClear()
    const inboundId = '13000000-0000-4000-8000-000000000099'
    messageSnapshot = [
      { id: inboundId, participant_name: 'Driver', message_text: 'New while reviewing history', from_me: false,
        provider_timestamp: '2026-08-20T10:02:00.000Z', latest_mutation: null, quote_allowed: true,
        ticket_creatable: true, linked_to_ticket: false },
      ...messageSnapshot,
    ]

    await vi.advanceTimersByTimeAsync(6_100)
    await flushPromises()

    expect(wrapper.text()).toContain('New messages: 1')
    expect(fetchMock.mock.calls.some(([input, init]) => String(input).endsWith('/read') && init?.method === 'POST')).toBe(false)

    await wrapper.findAll('button').find((button) => button.text() === 'New messages: 1')?.trigger('click')
    await flushPromises()
    const readRequest = fetchMock.mock.calls.find(([input, init]) => String(input).endsWith('/read') && init?.method === 'POST')
    assert.ok(readRequest)
    expect(JSON.parse(String(readRequest[1]?.body)).message_id).toBe(inboundId)
    wrapper.unmount()
  })

  test('retries conversation and ticket-page failures through their own truthful recovery controls', async () => {
    let messageLoads = 0
    let ticketLoads = 0
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: false },
      ]))
      if (path.includes('/messages?')) return ++messageLoads === 1 ? errorResponse() : response(messageSnapshot)
      if (path.includes('/tickets?')) {
        ticketLoads += 1
        if (path.includes('before=') && ticketLoads === 3) return errorResponse()
        return response({
          items: path.includes('before=')
            ? [{ ticket_id: '45', ticket_number: '1045', reference: 'Recovered page', state_category: 'OPEN', links: [] }]
            : [{ ticket_id: '42', ticket_number: '1042', reference: 'SHIP-42', state_category: 'OPEN', links: [] }],
          next_cursor: path.includes('before=') ? null : 'ticket-cursor',
        })
      }
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()

    expect(wrapper.text()).toContain('Group conversation is unavailable')
    expect(wrapper.text()).not.toContain('No captured messages yet')
    await wrapper.get('[role="alert"] button').trigger('click')
    await flushPromises()
    expect(wrapper.text()).toContain('Shipment SHIP-42')
    expect(messageLoads).toBe(2)

    await wrapper.findAll('button').find((button) => button.text() === 'Load more tickets')?.trigger('click')
    await flushPromises()
    const ticketAlert = wrapper.findAll('[role="alert"]').find((item) => item.text().includes('More tickets could not be loaded'))
    assert.ok(ticketAlert)
    await ticketAlert.get('button').trigger('click')
    await flushPromises()
    expect(wrapper.text()).toContain('Recovered page')
    expect(ticketLoads).toBe(4)
    wrapper.unmount()
  })

  test('keeps the current group loading when a stale conversation request fails after a switch', async () => {
    const riyadh = deferred<Response>()
    const jeddah = deferred<Response>()
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true },
        { id: secondGroupId, name: 'Jeddah Team', access_scope: 'MY', unread_count: 0, send_available: true },
      ]))
      if (path.includes(`/groups/${groupId}/messages?`)) return riyadh.promise
      if (path.includes(`/groups/${secondGroupId}/messages?`)) return jeddah.promise
      if (path.includes('/tickets?')) return response({ items: [], next_cursor: null })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    await wrapper.findAll('button').find((button) => button.text().includes('Jeddah Team'))?.trigger('click')
    await flushPromises()

    riyadh.reject(new Error('stale Riyadh failure'))
    await flushPromises()
    expect(wrapper.findAll('[role="status"]').some((item) => item.text() === 'Loading…')).toBe(true)
    expect(wrapper.text()).not.toContain('Group conversation could not be loaded')

    jeddah.resolve(response([{ ...messageSnapshot[0], id: secondGroupId, message_text: 'Jeddah current conversation' }]))
    await flushPromises()
    expect(wrapper.text()).toContain('Jeddah current conversation')
    expect(wrapper.findAll('[role="status"]').some((item) => item.text() === 'Loading…')).toBe(false)
    wrapper.unmount()
  })

  test('ignores an ordinary denied failure from an aborted group-page request', async () => {
    const first = deferred<Response>()
    const second = deferred<Response>()
    let groupLoads = 0
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return (groupLoads++ === 0 ? first : second).promise
      if (path.includes('/messages?')) return response([])
      if (path.includes('/tickets?')) return response({ items: [], next_cursor: null })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const supersedingLoad = (
      wrapper.vm as unknown as { loadGroups: (quiet?: boolean, after?: string | null) => Promise<boolean> }
    ).loadGroups(false, null)
    await flushPromises()
    expect(groupLoads).toBe(2)

    first.reject(Object.assign(new Error('stale denied response from internal host'), { status: 403 }))
    await flushPromises()
    expect(wrapper.findAll('[role="status"]').some((item) => item.text() === 'Loading…')).toBe(true)
    expect(wrapper.text()).not.toContain('WhatsApp groups could not be loaded')

    second.resolve(response(groupPage([
      { id: secondGroupId, name: 'Jeddah current page', access_scope: 'MY', unread_count: 0, send_available: true },
    ])))
    await supersedingLoad
    await flushPromises()
    expect(wrapper.text()).toContain('Jeddah current page')
    expect(wrapper.text()).not.toContain('stale denied response')
    wrapper.unmount()
  })

  test('keeps a newer same-group ticket snapshot loading when the superseded request rejects', async () => {
    const snapshots = [deferred<Response>(), deferred<Response>()]
    let snapshotLoads = 0
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true },
      ]))
      if (path.includes('/messages?')) return response(messageSnapshot)
      if (path.includes('/tickets?')) return snapshots[snapshotLoads++]!.promise
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    expect(snapshotLoads).toBe(1)

    for (let index = 0; index < 6; index += 1) {
      document.dispatchEvent(new Event('visibilitychange'))
      await flushPromises()
    }
    expect(snapshotLoads).toBe(2)

    snapshots[0]!.reject(new Error('stale internal ticket failure'))
    await flushPromises()
    expect(wrapper.text()).not.toContain('Related tickets could not be loaded')
    expect(wrapper.findAll('[role="status"]').some((item) => item.text() === 'Loading…')).toBe(true)

    snapshots[1]!.resolve(response({ items: [
      { ticket_id: '84', ticket_number: '1084', reference: 'Current snapshot', state_category: 'OPEN', links: [] },
    ], next_cursor: null }))
    await flushPromises()
    expect(wrapper.text()).toContain('Current snapshot')
    expect(wrapper.text()).not.toContain('stale internal ticket failure')
    wrapper.unmount()
  })

  test.each(['success', 'failure'] as const)('discards a stale ticket-page %s after a newer same-group snapshot', async (outcome) => {
    const oldPage = deferred<Response>()
    const freshSnapshot = deferred<Response>()
    let snapshotLoads = 0
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true },
      ]))
      if (path.includes('/messages?')) return response(messageSnapshot)
      if (path.includes('before=older-page')) return oldPage.promise
      if (path.includes('/tickets?')) {
        snapshotLoads += 1
        return snapshotLoads === 1
          ? response({ items: [{ ticket_id: '42', ticket_number: '1042', reference: 'Initial ticket', state_category: 'OPEN', links: [] }], next_cursor: 'older-page' })
          : freshSnapshot.promise
      }
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    await wrapper.findAll('button').find((button) => button.text() === 'Load more tickets')?.trigger('click')
    await flushPromises()

    for (let index = 0; index < 6; index += 1) {
      document.dispatchEvent(new Event('visibilitychange'))
      await flushPromises()
    }
    expect(snapshotLoads).toBe(2)
    freshSnapshot.resolve(response({ items: [
      { ticket_id: '84', ticket_number: '1084', reference: 'Fresh ticket list', state_category: 'OPEN', links: [] },
    ], next_cursor: null }))
    await flushPromises()

    if (outcome === 'success') {
      oldPage.resolve(response({ items: [
        { ticket_id: '43', ticket_number: '1043', reference: 'Stale older page', state_category: 'OPEN', links: [] },
      ], next_cursor: 'stale-cursor' }))
    } else {
      oldPage.reject(new Error('stale page failure'))
    }
    await flushPromises()

    expect(wrapper.text()).toContain('Fresh ticket list')
    expect(wrapper.text()).not.toMatch(/Initial ticket|Stale older page|More tickets could not be loaded/u)
    wrapper.unmount()
  })

  test('retains the transcript through a failed quiet refresh and recovers in place', async () => {
    vi.useFakeTimers()
    let messageLoads = 0
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true },
      ]))
      if (path.includes('/messages?')) {
        messageLoads += 1
        if (messageLoads === 2) return errorResponse()
        return response(messageLoads === 1 ? messageSnapshot : [{ ...messageSnapshot[0], message_text: 'Recovered conversation' }])
      }
      if (path.includes('/tickets?')) return response({ items: [], next_cursor: null })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()

    await vi.advanceTimersByTimeAsync(6_100)
    await flushPromises()
    expect(wrapper.text()).toContain('Shipment SHIP-42')
    const alert = wrapper.findAll('[role="alert"]').find((item) => item.text().includes('Group conversation could not be loaded'))
    assert.ok(alert)
    await alert.get('button').trigger('click')
    await flushPromises()

    expect(wrapper.text()).toContain('Recovered conversation')
    expect(wrapper.text()).not.toContain('Group conversation could not be loaded')
    expect(messageLoads).toBe(3)
    wrapper.unmount()
  })

  test('keeps healthy history and the composer usable when the initial related-ticket request fails', async () => {
    let ticketLoads = 0
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true,
          media_capabilities: wahaMediaCapabilities },
      ]))
      if (path.includes('/messages?')) return response(messageSnapshot)
      if (path.includes('/tickets?')) {
        ticketLoads += 1
        return ticketLoads === 1 ? errorResponse() : response({ items: [
          { ticket_id: '42', ticket_number: '1042', reference: 'Recovered tickets', state_category: 'OPEN', links: [] },
        ], next_cursor: null })
      }
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()

    expect(wrapper.text()).toContain('Shipment SHIP-42')
    expect(wrapper.find('textarea').exists()).toBe(true)
    expect(wrapper.text()).not.toContain('Group conversation is unavailable')
    expect(wrapper.text()).toContain('Related tickets could not be loaded. Try again.')
    expect(wrapper.text()).not.toContain('No tickets in this view.')

    const ticketAlert = wrapper.findAll('[role="alert"]').find((item) => item.text().includes('Related tickets could not be loaded'))
    assert.ok(ticketAlert)
    await ticketAlert.get('button').trigger('click')
    await flushPromises()

    expect(wrapper.text()).toContain('Ticket #1042')
    expect(wrapper.text()).toContain('Recovered tickets')
    expect(wrapper.text()).not.toContain('Related tickets could not be loaded')
    expect(ticketLoads).toBe(2)
    wrapper.unmount()
  })

  test('keeps the active keyboard mention visible within a twenty-result list', async () => {
    const defaultImplementation = fetchMock.getMockImplementation()
    fetchMock.mockImplementation(async (input, init) => {
      if (String(input).includes('/participants?')) return response(Array.from({ length: 20 }, (_, index) => ({
        id: `9665000000${String(index).padStart(2, '0')}@c.us`, name: `Participant ${index + 1}`,
      })))
      assert.ok(defaultImplementation)
      return defaultImplementation(input, init)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const composer = wrapper.get('textarea')
    await composer.setValue('@Par')
    await composer.trigger('input')
    await new Promise((resolve) => setTimeout(resolve, 180))
    await flushPromises()
    const options = wrapper.findAll('[role="option"]')
    expect(options).toHaveLength(20)
    const scrollIntoView = vi.fn()
    for (const option of options) Object.defineProperty(option.element, 'scrollIntoView', { configurable: true, value: scrollIntoView })

    for (let index = 0; index < 12; index += 1) await composer.trigger('keydown', { key: 'ArrowDown' })
    await flushPromises()

    expect(composer.attributes('aria-activedescendant')).toBe('wasalx-mention-12')
    expect(options[12]?.attributes('aria-selected')).toBe('true')
    expect(scrollIntoView).toHaveBeenLastCalledWith({ block: 'nearest' })
    wrapper.unmount()
  })

  test('restores focus after ticket-action cancellation and create or link success', async () => {
    const wrapper = mount(WasalxGroups, {
      attachTo: document.body,
      global: {
        config: { globalProperties: { $t: (message: string) => message } },
        stubs: { RouterLink: { props: ['to'], template: '<a :href="to"><slot /></a>' } },
      },
    })
    await flushPromises()
    const create = wrapper.findAll('button').find((button) => button.text() === 'Create ticket')
    assert.ok(create)
    create.element.focus()
    await create.trigger('click')
    await flushPromises()
    await wrapper.findAll('button').find((button) => button.text() === 'Cancel')?.trigger('click')
    await nextTick()
    expect(document.activeElement).toBe(create.element)

    await create.trigger('click')
    await flushPromises()
    await wrapper.findAll('form').find((form) => form.text().includes('Create a ticket from this message'))?.trigger('submit')
    await flushPromises()
    expect((document.activeElement as HTMLAnchorElement).getAttribute('href')).toBe('/tickets/43#article-92')

    const link = wrapper.findAll('button').find((button) => button.text() === 'Link to ticket')
    assert.ok(link)
    await link.trigger('click')
    await wrapper.get('input[id^="wasalx-ticket-number-"]').setValue('1042')
    await wrapper.findAll('form').find((form) => form.text().includes('Link this message to a ticket'))?.trigger('submit')
    await flushPromises()
    expect((document.activeElement as HTMLAnchorElement).getAttribute('href')).toBe('/tickets/42#article-91')
    wrapper.unmount()
  })

  test('shows new inbound group messages without a manual refresh', async () => {
    vi.useFakeTimers()
    const wrapper = mount(WasalxGroups, {
      global: {
        config: { globalProperties: { $t: (message: string) => message } },
        stubs: { RouterLink: { props: ['to'], template: '<a :href="to"><slot /></a>' } },
      },
    })
    await flushPromises()
    expect(wrapper.text()).not.toContain('Driver reached the hub')

    messageSnapshot = [
      { id: '13000000-0000-4000-8000-000000000002', participant_name: 'Driver', message_text: 'Driver reached the hub', from_me: false, provider_timestamp: '2026-08-20T10:02:00.000Z', latest_mutation: null, quote_allowed: true, ticket_creatable: true, linked_to_ticket: false },
      ...messageSnapshot,
    ]
    await vi.advanceTimersByTimeAsync(6_100)
    await flushPromises()

    expect(wrapper.text()).toContain('Driver reached the hub')
    expect(wrapper.text()).toContain('Mobile number unavailable')
    wrapper.unmount()
  })

  test('keeps mention results scoped across query, close, reopen, and group switches', async () => {
    const participantRequests: Array<ReturnType<typeof deferred<Response>>> = []
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true },
        { id: secondGroupId, name: 'Jeddah Team', access_scope: 'TEAM', unread_count: 0, send_available: true },
      ]))
      if (path.includes('/participants?')) {
        const request = deferred<Response>()
        participantRequests.push(request)
        return request.promise
      }
      if (path.includes('/messages?')) return response(messageSnapshot)
      if (path.includes('/tickets?')) return response({ items: [], next_cursor: null })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const composer = wrapper.get('textarea')

    await composer.setValue('@Old')
    await new Promise((resolve) => setTimeout(resolve, 180))
    await composer.setValue('@Current')
    await new Promise((resolve) => setTimeout(resolve, 180))
    expect(participantRequests).toHaveLength(2)
    participantRequests[0]!.reject(new Error('stale query failure'))
    await flushPromises()
    expect(wrapper.text()).toContain('Finding participants…')
    participantRequests[1]!.resolve(response([{ id: 'current@lid', name: 'Current participant', phone: '+12025550184' }]))
    await flushPromises()
    expect(wrapper.text()).toContain('Current participant')

    await composer.setValue('@Closing')
    expect(wrapper.text()).not.toContain('Current participant')
    expect(wrapper.text()).toContain('Finding participants…')
    await new Promise((resolve) => setTimeout(resolve, 180))
    await composer.trigger('blur')
    await composer.setValue('@Reopened')
    await new Promise((resolve) => setTimeout(resolve, 180))
    expect(participantRequests).toHaveLength(4)
    participantRequests[2]!.resolve(response([{ id: 'closed@lid', name: 'Closed result' }]))
    await flushPromises()
    expect(wrapper.text()).toContain('Finding participants…')
    expect(wrapper.text()).not.toContain('Closed result')
    participantRequests[3]!.resolve(response([{ id: 'reopened@lid', name: 'Reopened result', phone: '+14165550184' }]))
    await flushPromises()
    expect(wrapper.text()).toContain('Reopened result')

    await composer.setValue('@Riyadh')
    await new Promise((resolve) => setTimeout(resolve, 180))
    await wrapper.findAll('button').find((button) => button.text().includes('Jeddah Team'))?.trigger('click')
    await flushPromises()
    await wrapper.findAll('button').find((button) => button.text().includes('Riyadh Operations'))?.trigger('click')
    await flushPromises()
    const restoredComposer = wrapper.get('textarea')
    await restoredComposer.setValue('@Final')
    await new Promise((resolve) => setTimeout(resolve, 180))
    expect(participantRequests).toHaveLength(6)
    participantRequests[4]!.resolve(response([{ id: 'old-group@lid', name: 'Old group result' }]))
    await flushPromises()
    expect(wrapper.text()).toContain('Finding participants…')
    expect(wrapper.text()).not.toContain('Old group result')
    participantRequests[5]!.resolve(response([{ id: 'final@lid', name: 'Final participant', phone: '+19175550193' }]))
    await flushPromises()
    expect(wrapper.text()).toContain('Final participant')
    wrapper.unmount()
  })

  test('retains the live workspace while a background group refresh fails and retries', async () => {
    vi.useFakeTimers()
    const original = fetchMock.getMockImplementation()
    const retry = deferred<Response>()
    let groupLoads = 0
    fetchMock.mockImplementation(async (input, init) => {
      if (String(input).includes('/group_workspace/groups?')) {
        groupLoads += 1
        if (groupLoads === 2) return errorResponse()
        if (groupLoads === 3) return retry.promise
      }
      assert.ok(original)
      return original(input, init)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()

    await vi.advanceTimersByTimeAsync(37_000)
    await flushPromises()
    expect(groupLoads).toBe(2)
    expect(wrapper.text()).toContain('Riyadh Operations')
    expect(wrapper.get('[role="status"]').text()).toContain('WhatsApp groups could not be loaded. Try again.')

    const retryButton = wrapper.findAll('button').find((button) => button.text() === 'Try again')
    assert.ok(retryButton)
    await retryButton.trigger('click')
    await nextTick()
    expect(wrapper.text()).toContain('Riyadh Operations')
    expect(wrapper.text()).not.toContain('WhatsApp Groups is unavailable')

    retry.resolve(response(groupPage([
      { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 2, send_available: true, reactions_available: true, media_capabilities: wahaMediaCapabilities },
      { id: secondGroupId, name: 'Jeddah Team', access_scope: 'TEAM', unread_count: 0, send_available: false, reactions_available: false, media_capabilities: metaMediaCapabilities },
    ])))
    await flushPromises()
    expect(wrapper.text()).not.toContain('WhatsApp groups could not be loaded. Try again.')
    expect(wrapper.text()).toContain('Riyadh Operations')
    wrapper.unmount()
  })

  test('reacts to locale changes in group and ticket filters', async () => {
    const locale = ref<'en' | 'ar'>('en')
    const Arabic: Record<string, string> = {
      'My Groups': 'مجموعاتي', 'My Team': 'فريقي', Unassigned: 'غير معيّنة',
      'All Accessible': 'كل المجموعات المتاحة', Open: 'مفتوحة', Closed: 'مغلقة', All: 'الكل',
    }
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => locale.value === 'ar' ? Arabic[message] ?? message : message } } },
    })
    await flushPromises()
    expect(wrapper.text()).toContain('My Groups')
    expect(wrapper.text()).toContain('Open')

    locale.value = 'ar'
    document.documentElement.lang = 'ar'
    await nextTick()

    expect(wrapper.text()).toContain('مجموعاتي')
    expect(wrapper.text()).toContain('مفتوحة')
    expect(wrapper.text()).not.toContain('My Groups')
    wrapper.unmount()
  })

  test('keeps automatic refreshes non-overlapping', async () => {
    vi.useFakeTimers()
    const original = fetchMock.getMockImplementation()
    let messageLoads = 0
    let resolveRefresh: ((value: Response) => void) | undefined
    fetchMock.mockImplementation(async (input, init) => {
      if (String(input).includes('/messages?')) {
        messageLoads += 1
        if (messageLoads > 1) return new Promise<Response>((resolve) => { resolveRefresh = resolve })
      }
      assert.ok(original)
      return original(input, init)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()

    await vi.advanceTimersByTimeAsync(6_100)
    expect(messageLoads).toBe(2)
    await vi.advanceTimersByTimeAsync(20_000)
    expect(messageLoads).toBe(2)

    resolveRefresh?.(response(messageSnapshot))
    await flushPromises()
    wrapper.unmount()
  })

  test('shows a pending send immediately and reconciles it with the durable delivery', async () => {
    const original = fetchMock.getMockImplementation()
    let finishSend: ((value: Response) => void) | undefined
    fetchMock.mockImplementation(async (input, init) => {
      if (init?.method === 'POST' && String(input).endsWith('/send')) {
        return new Promise<Response>((resolve) => { finishSend = resolve })
      }
      assert.ok(original)
      return original(input, init)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    await wrapper.get('textarea').setValue('Visible without refresh')
    await wrapper.get('form').trigger('submit')
    await nextTick()

    const pending = wrapper.get('[data-message-id^="pending-"]')
    expect(pending.text()).toContain('Visible without refresh')
    expect(pending.text()).toContain('You')
    expect(pending.text()).toContain('Sending…')
    expect(wrapper.get('textarea').attributes('disabled')).toBeDefined()

    finishSend?.(response({ id: '14000000-0000-4000-8000-000000000087', participant_name: 'Agent One',
      sender_phone: '+13125550190', message_text: 'Visible without refresh', from_me: true,
      provider_timestamp: '2026-08-20T10:01:00.000Z', latest_mutation: null, quote_allowed: false,
      ticket_creatable: false, linked_to_ticket: false, source_kind: 'DELIVERY', delivery_state: 'QUEUED' }))
    await flushPromises()

    expect(wrapper.find('[data-message-id^="pending-"]').exists()).toBe(false)
    expect(wrapper.text()).toContain('Agent One')
    expect(wrapper.text()).toContain('Queued')
    expect(wrapper.get('textarea').attributes('disabled')).toBeUndefined()
    wrapper.unmount()
  })

  test('never renders an opaque WhatsApp identity from a legacy response', async () => {
    messageSnapshot = [{
      id: messageId, participant_name: 'Customer One', sender_phone: null, sender_identifier: '12025550135@lid',
      message_text: 'Opaque identity', from_me: false, provider_timestamp: '2026-08-20T10:00:00.000Z',
      latest_mutation: null, quote_allowed: true, ticket_creatable: true, linked_to_ticket: false,
    }]
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()

    const message = wrapper.get(`[data-message-id="${messageId}"]`)
    expect(message.text()).toContain('Customer One')
    expect(message.text()).not.toContain('WhatsApp ID')
    expect(message.text()).not.toContain('12025550135@lid')
    expect(message.text()).toContain('Mobile number unavailable')
    wrapper.unmount()
  })

  test('preserves message emoji and sends an authorized idempotent reaction', async () => {
    messageSnapshot = [{
      id: messageId, participant_name: 'Customer One', sender_phone: '+12025550184',
      message_text: 'وصل الطلب 👨‍👩‍👧‍👦 ✅', from_me: false, provider_timestamp: '2026-08-20T10:00:00.000Z',
      latest_mutation: null, quote_allowed: true, ticket_creatable: true, linked_to_ticket: false,
    }]
    const wrapper = mount(WasalxGroups, { global: { config: { globalProperties: { $t: (message: string) => message } } } })
    await flushPromises()
    expect(wrapper.get(`[data-message-id="${messageId}"]`).text()).toContain('وصل الطلب 👨‍👩‍👧‍👦 ✅')
    await wrapper.get(`button[aria-label="React with ✅"]`).trigger('click')
    await flushPromises()
    const reaction = fetchMock.mock.calls.find(([input, init]) => init?.method === 'POST' && String(input).endsWith(`/messages/${messageId}/reactions`))
    expect(JSON.parse(String(reaction?.[1]?.body))).toEqual({ emoji: '✅', request_token: '00000000-0000-4000-8000-000000000042' })
    expect(wrapper.get(`[data-message-id="${messageId}"]`).text()).toContain('Sending reaction…')
    expect(wrapper.get('button[aria-label="React with ✅"]').attributes('aria-pressed')).toBe('false')
    wrapper.unmount()

    messageSnapshot = [{
      id: messageId, participant_name: 'Customer One', sender_phone: '+12025550184',
      message_text: 'وصل الطلب 👨‍👩‍👧‍👦 ✅', from_me: false, provider_timestamp: '2026-08-20T10:00:00.000Z',
      latest_mutation: null, quote_allowed: true, ticket_creatable: true, linked_to_ticket: false,
      reaction_active_emoji: '✅', reaction_requested_emoji: '✅', reaction_delivery_state: 'SENT',
    }]
    const reloaded = mount(WasalxGroups, { global: { config: { globalProperties: { $t: (message: string) => message } } } })
    await flushPromises()
    const remove = reloaded.get('button[aria-label="Remove reaction ✅"]')
    expect(remove.attributes('aria-pressed')).toBe('true')
    await remove.trigger('click')
    await flushPromises()
    const removal = fetchMock.mock.calls.filter(([input, init]) => init?.method === 'POST' && String(input).endsWith(`/messages/${messageId}/reactions`)).at(-1)
    expect(JSON.parse(String(removal?.[1]?.body))).toEqual({ removed: true, request_token: '00000000-0000-4000-8000-000000000042' })
    expect(reloaded.get(`[data-message-id="${messageId}"]`).text()).toContain('Removing reaction…')
    expect(reloaded.get('button[aria-label="Remove reaction ✅"]').attributes('aria-pressed')).toBe('true')
    reloaded.unmount()

    messageSnapshot = [{
      id: messageId, participant_name: 'Customer One', sender_phone: '+12025550184',
      message_text: 'وصل الطلب 👨‍👩‍👧‍👦 ✅', from_me: false, provider_timestamp: '2026-08-20T10:00:00.000Z',
      latest_mutation: null, quote_allowed: true, ticket_creatable: true, linked_to_ticket: false,
      reaction_active_emoji: '', reaction_requested_emoji: '', reaction_delivery_state: 'SENT',
    }]
    const removed = mount(WasalxGroups, { global: { config: { globalProperties: { $t: (message: string) => message } } } })
    await flushPromises()
    expect(removed.get(`[data-message-id="${messageId}"]`).text()).toContain('Reaction removed.')
    expect(removed.get('button[aria-label="React with ✅"]').attributes('aria-pressed')).toBe('false')
    removed.unmount()
  })

  test('keeps failed reactions retryable and unknown outcomes fail-closed after reload', async () => {
    messageSnapshot = [{
      id: messageId, participant_name: 'Customer One', sender_phone: '+12025550184', message_text: 'Reaction target',
      from_me: false, provider_timestamp: '2026-08-20T10:00:00.000Z', latest_mutation: null,
      quote_allowed: true, ticket_creatable: true, linked_to_ticket: false,
      reaction_active_emoji: null, reaction_requested_emoji: '✅', reaction_delivery_state: 'FAILED_RETRYABLE',
    }]
    const retrying = mount(WasalxGroups, { global: { config: { globalProperties: { $t: (message: string) => message } } } })
    await flushPromises()
    expect(retrying.get(`[data-message-id="${messageId}"]`).text()).toContain('Retrying reaction…')
    expect(retrying.get('button[aria-label="React with ✅"]').attributes('disabled')).toBeDefined()
    retrying.unmount()

    messageSnapshot = [{
      id: messageId, participant_name: 'Customer One', sender_phone: '+12025550184', message_text: 'Reaction target',
      from_me: false, provider_timestamp: '2026-08-20T10:00:00.000Z', latest_mutation: null,
      quote_allowed: true, ticket_creatable: true, linked_to_ticket: false,
      reaction_active_emoji: '✅', reaction_requested_emoji: '', reaction_delivery_state: 'FAILED_RETRYABLE',
    }]
    const removing = mount(WasalxGroups, { global: { config: { globalProperties: { $t: (message: string) => message } } } })
    await flushPromises()
    expect(removing.get(`[data-message-id="${messageId}"]`).text()).toContain('Retrying reaction removal…')
    expect(removing.get('button[aria-label="Remove reaction ✅"]').attributes('disabled')).toBeDefined()
    removing.unmount()

    messageSnapshot = [{
      id: messageId, participant_name: 'Customer One', sender_phone: '+12025550184', message_text: 'Reaction target',
      from_me: false, provider_timestamp: '2026-08-20T10:00:00.000Z', latest_mutation: null,
      quote_allowed: true, ticket_creatable: true, linked_to_ticket: false,
      reaction_active_emoji: null, reaction_requested_emoji: '✅', reaction_delivery_state: 'FAILED_TERMINAL',
    }]
    const failed = mount(WasalxGroups, { global: { config: { globalProperties: { $t: (message: string) => message } } } })
    await flushPromises()
    expect(failed.get(`[data-message-id="${messageId}"]`).text()).toContain('Reaction could not be sent. Try again.')
    expect(failed.get('button[aria-label="React with ✅"]').attributes('disabled')).toBeUndefined()
    failed.unmount()

    messageSnapshot = [{
      id: messageId, participant_name: 'Customer One', sender_phone: '+12025550184', message_text: 'Reaction target',
      from_me: false, provider_timestamp: '2026-08-20T10:00:00.000Z', latest_mutation: null,
      quote_allowed: true, ticket_creatable: true, linked_to_ticket: false,
      reaction_active_emoji: null, reaction_requested_emoji: '✅', reaction_delivery_state: 'OUTCOME_UNKNOWN',
    }]
    const unknown = mount(WasalxGroups, { global: { config: { globalProperties: { $t: (message: string) => message } } } })
    await flushPromises()
    expect(unknown.get(`[data-message-id="${messageId}"]`).text()).toContain('Reaction status is unknown. Check WhatsApp before trying again.')
    expect(unknown.get('button[aria-label="React with ✅"]').attributes('disabled')).toBeDefined()
    unknown.unmount()
  })

  test('reports a rejected reaction removal as a removal failure', async () => {
    messageSnapshot = [{
      id: messageId, participant_name: 'Customer One', sender_phone: '+12025550184', message_text: 'Reaction target',
      from_me: false, provider_timestamp: '2026-08-20T10:00:00.000Z', latest_mutation: null,
      quote_allowed: true, ticket_creatable: true, linked_to_ticket: false,
      reaction_active_emoji: '✅', reaction_requested_emoji: '✅', reaction_delivery_state: 'SENT',
    }]
    const wrapper = mount(WasalxGroups, { global: { config: { globalProperties: { $t: (message: string) => message } } } })
    await flushPromises()
    const normalFetch = fetchMock.getMockImplementation()
    fetchMock.mockImplementation(async (input, init) => init?.method === 'POST' && String(input).endsWith(`/messages/${messageId}/reactions`)
      ? errorResponse(400)
      : normalFetch!(input, init))
    await wrapper.get('button[aria-label="Remove reaction ✅"]').trigger('click')
    await flushPromises()
    expect(wrapper.get(`[data-message-id="${messageId}"]`).text()).toContain('Reaction could not be removed. Try again.')
  })

  test('shows a truthful missing-mobile note once for consecutive messages from the same participant', async () => {
    messageSnapshot = [
      { id: 'message-2', participant_name: 'Driver', message_text: 'Second update', from_me: false,
        provider_timestamp: '2026-08-20T10:01:00.000Z', latest_mutation: null, quote_allowed: true,
        ticket_creatable: true, linked_to_ticket: false },
      { id: 'message-1', participant_name: 'Driver', message_text: 'First update', from_me: false,
        provider_timestamp: '2026-08-20T10:00:00.000Z', latest_mutation: null, quote_allowed: true,
        ticket_creatable: true, linked_to_ticket: false },
    ]
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()

    expect(wrapper.text().match(/Mobile number unavailable/gu)).toHaveLength(1)
    wrapper.unmount()
  })

  test('keeps backend-permitted actions on a durable sent delivery', async () => {
    messageSnapshot = [{
      id: messageId, participant_name: 'Agent One', sender_phone: '+13125550190', message_text: 'Shipment sent',
      from_me: true, provider_timestamp: '2026-08-20T10:00:00.000Z', latest_mutation: null,
      quote_allowed: true, ticket_creatable: false, linked_to_ticket: false, source_kind: 'DELIVERY', delivery_state: 'SENT',
    }]
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()

    const delivery = wrapper.get(`[data-message-id="${messageId}"]`)
    expect(delivery.findAll('button').some((button) => button.text() === 'Quote')).toBe(true)
    expect(delivery.findAll('button').some((button) => button.text() === 'Create ticket')).toBe(false)
    expect(delivery.findAll('button').some((button) => button.text() === 'Link to ticket')).toBe(false)
    wrapper.unmount()
  })

  test('shows ticket state on every related ticket card', async () => {
    const wrapper = mount(WasalxGroups, {
      global: {
        config: { globalProperties: { $t: (message: string) => message } },
        stubs: { RouterLink: { props: ['to'], template: '<a :href="to"><slot /></a>' } },
      },
    })
    await flushPromises()
    expect(wrapper.findAll('article').find((article) => article.text().includes('#1042'))?.text()).toContain('Open')

    await wrapper.findAll('button').find((button) => button.text() === 'Closed')?.trigger('click')
    expect(wrapper.findAll('article').find((article) => article.text().includes('#1044'))?.text()).toContain('Closed')
    wrapper.unmount()
  })

  test('shows truthful manual attribution and accessible quoted-message previews', async () => {
    const sourceId = '13000000-0000-4000-8000-000000000021'
    const replyId = '13000000-0000-4000-8000-000000000022'
    const unavailableId = '13000000-0000-4000-8000-000000000023'
    messageSnapshot = [
      { id: unavailableId, external_message_id: 'provider-unavailable-reply', quoted_external_message_id: 'provider-missing',
        participant_name: 'Customer', sender_phone: '+12025550184', message_text: 'Which message?', from_me: false,
        provider_timestamp: '2026-08-20T10:02:00.000Z', latest_mutation: null, quote_allowed: true,
        ticket_creatable: true, linked_to_ticket: false },
      { id: replyId, external_message_id: 'provider-manual-reply', quoted_external_message_id: 'provider-original',
        participant_name: null, sender_phone: '+13125550190', message_text: 'Handled from the phone', from_me: true,
        provider_timestamp: '2026-08-20T10:01:00.000Z', latest_mutation: null, quote_allowed: true,
        ticket_creatable: false, linked_to_ticket: false },
      { id: sourceId, external_message_id: 'provider-original', participant_name: 'Customer', sender_phone: '+12025550184',
        message_text: 'Original shipment request', from_me: false, provider_timestamp: '2026-08-20T10:00:00.000Z',
        latest_mutation: null, quote_allowed: true, ticket_creatable: true, linked_to_ticket: false },
    ]
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()

    const manual = wrapper.get(`[data-message-id="${replyId}"]`)
    expect(manual.get('strong').text()).toBe('+13125550190')
    expect(manual.get('blockquote').attributes('aria-label')).toBe('Quoted message')
    expect(manual.get('blockquote').text()).toContain('Original shipment request')
    expect(wrapper.get(`[data-message-id="${unavailableId}"] blockquote`).text()).toContain('Quoted message unavailable')
    wrapper.unmount()
  })

  test('reconciles a queued send when its normalized echo arrives between refreshes', async () => {
    vi.useFakeTimers()
    const deliveryId = '14000000-0000-4000-8000-000000000091'
    const echoId = '13000000-0000-4000-8000-000000000091'
    let messageLoads = 0
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true },
      ]))
      if (path.includes('/messages?')) {
        messageLoads += 1
        return response(messageLoads < 3 ? messageSnapshot : [{
          id: echoId, external_message_id: 'provider-message-91', delivery_id: deliveryId,
          participant_name: 'Agent One', sender_phone: '+13125550190', message_text: 'Shipment sent', from_me: true,
          provider_timestamp: '2026-08-20T10:01:00.000Z', latest_mutation: null, quote_allowed: true,
          ticket_creatable: false, linked_to_ticket: false, source_kind: 'MESSAGE', delivery_state: null,
        }, ...messageSnapshot])
      }
      if (path.includes('/tickets?')) return response({ items: [], next_cursor: null })
      if (init?.method === 'POST' && path.endsWith('/send')) return response({
        id: deliveryId, external_message_id: null, delivery_id: deliveryId, participant_name: 'Agent One',
        sender_phone: '+13125550190', message_text: 'Shipment sent', from_me: true,
        provider_timestamp: '2026-08-20T10:01:00.000Z', latest_mutation: null, quote_allowed: false,
        ticket_creatable: false, linked_to_ticket: false, source_kind: 'DELIVERY', delivery_state: 'QUEUED',
      })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    await wrapper.get('textarea').setValue('Shipment sent')
    await wrapper.get('form').trigger('submit')
    await flushPromises()
    expect(wrapper.text().match(/Shipment sent/gu)).toHaveLength(1)
    expect(wrapper.text()).toContain('Queued')

    await vi.advanceTimersByTimeAsync(6_100)
    await flushPromises()
    expect(wrapper.text().match(/Shipment sent/gu)).toHaveLength(1)
    expect(wrapper.text()).not.toContain('Queued')
    wrapper.unmount()
  })

  test('reuses one request token after a lost attachment response and rotates it when the payload changes', async () => {
    let uuidSequence = 100
    vi.mocked(globalThis.crypto.randomUUID).mockImplementation(() =>
      `00000000-0000-4000-8000-${String(uuidSequence++).padStart(12, '0')}` as ReturnType<typeof globalThis.crypto.randomUUID>)
    const original = fetchMock.getMockImplementation()
    const payloads: Array<{ message: string, request_token: string, upload_cache_id?: string, upload_store_ids?: number[] }> = []
    let sendAttempt = 0
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (init?.method === 'POST' && path.endsWith('/send')) {
        const payload = JSON.parse(String(init.body)) as { message: string, request_token: string, upload_cache_id?: string, upload_store_ids?: number[] }
        payloads.push(payload)
        sendAttempt += 1
        if (sendAttempt === 1) throw new Error('response lost')
        return response({ id: `14000000-0000-4000-8000-00000000000${sendAttempt}`, participant_name: 'Agent One',
          message_text: payload.message, from_me: true, provider_timestamp: '2026-08-20T10:01:00.000Z', latest_mutation: null,
          quote_allowed: false, ticket_creatable: false, linked_to_ticket: false, source_kind: 'DELIVERY', delivery_state: 'QUEUED' })
      }
      assert.ok(original)
      return original(input, init)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const input = wrapper.get('input[type="file"]')
    const file = new File([Uint8Array.from([137, 80, 78, 71])], 'proof.png', { type: 'image/png' })
    Object.defineProperty(input.element, 'files', { configurable: true, value: [file] })
    await input.trigger('change')
    await flushPromises()
    await wrapper.get('textarea').setValue('Retry this exact attachment')
    await wrapper.get('form').trigger('submit')
    await flushPromises()
    expect(wrapper.text()).toContain('Delivery could not be confirmed. Retry the unchanged message safely; it will not be sent twice.')
    expect(wrapper.text()).toContain('proof.png')
    await wrapper.get('form').trigger('submit')
    await flushPromises()
    assert.equal(payloads[0]?.request_token, payloads[1]?.request_token)
    assert.equal(payloads[0]?.upload_cache_id, payloads[1]?.upload_cache_id)
    assert.deepEqual(payloads[0]?.upload_store_ids, payloads[1]?.upload_store_ids)
    expect(fetchMock.mock.calls.filter(([input, init]) => String(input).includes(`/api/v1/upload_caches/${payloads[1]?.upload_cache_id}`) && init?.method === 'DELETE')).toHaveLength(1)
    await wrapper.get('textarea').setValue('A changed message')
    await wrapper.get('form').trigger('submit')
    await flushPromises()
    assert.notEqual(payloads[1]?.request_token, payloads[2]?.request_token)
    wrapper.unmount()
  })

  test('keeps an in-flight send scoped to its original group when the operator switches groups', async () => {
    const original = fetchMock.getMockImplementation()
    let finishSend: ((value: Response) => void) | undefined
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true, media_capabilities: wahaMediaCapabilities },
        { id: secondGroupId, name: 'Jeddah Operations', access_scope: 'TEAM', unread_count: 0, send_available: true, media_capabilities: wahaMediaCapabilities },
      ]))
      if (init?.method === 'POST' && path.endsWith('/send')) return new Promise<Response>((resolve) => { finishSend = resolve })
      assert.ok(original)
      return original(input, init)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const input = wrapper.get('input[type="file"]')
    const file = new File([Uint8Array.from([1, 2, 3, 4])], 'riyadh.png', { type: 'image/png' })
    Object.defineProperty(input.element, 'files', { configurable: true, value: [file] })
    await input.trigger('change')
    await flushPromises()
    await wrapper.get('textarea').setValue('Riyadh only')
    await wrapper.get('form').trigger('submit')
    await nextTick()

    await wrapper.findAll('button').find((button) => button.text() === 'My Team')?.trigger('click')
    await flushPromises()
    expect(wrapper.text()).toContain('Jeddah Operations')
    expect(wrapper.text()).not.toContain('riyadh.png')
    await wrapper.get('textarea').setValue('Jeddah draft')
    finishSend?.(response({ id: '14000000-0000-4000-8000-000000000088', participant_name: 'Agent One', message_text: 'Riyadh only',
      from_me: true, provider_timestamp: '2026-08-20T10:01:00.000Z', latest_mutation: null, quote_allowed: false,
      ticket_creatable: false, linked_to_ticket: false, source_kind: 'DELIVERY', delivery_state: 'QUEUED' }))
    await flushPromises()

    expect((wrapper.get('textarea').element as HTMLTextAreaElement).value).toBe('Jeddah draft')
    expect(wrapper.text()).not.toContain('Riyadh only')
    expect(fetchMock.mock.calls.some(([value, options]) => String(value).includes('/api/v1/upload_caches/')
      && options?.method === 'DELETE' && !String(value).includes('/items/'))).toBe(true)
    wrapper.unmount()
  })

  test('discards deferred history, context, and ticket-page success or failure after a group switch', async () => {
    const historyRequests = [deferred<Response>(), deferred<Response>()]
    const contextRequests = [deferred<Response>(), deferred<Response>()]
    const ticketPageRequests = [deferred<Response>(), deferred<Response>()]
    let historyAttempt = 0
    let contextAttempt = 0
    let ticketPageAttempt = 0
    const latest = Array.from({ length: 50 }, (_, index) => ({
      id: index ? `13000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}` : messageId,
      participant_name: 'Customer', message_text: `Riyadh message ${index + 1}`, from_me: false,
      provider_timestamp: `2026-08-20T10:${String(index).padStart(2, '0')}:00.000Z`, latest_mutation: null,
      quote_allowed: true, ticket_creatable: true, linked_to_ticket: index === 0,
    }))
    const jeddahMessage = {
      id: '13000000-0000-4000-8000-000000000099', participant_name: 'Jeddah customer', message_text: 'Jeddah current conversation',
      from_me: false, provider_timestamp: '2026-08-20T11:00:00.000Z', latest_mutation: null,
      quote_allowed: true, ticket_creatable: true, linked_to_ticket: false,
    }
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true },
        { id: secondGroupId, name: 'Jeddah Team', access_scope: 'MY', unread_count: 0, send_available: true },
      ]))
      if (path.includes(`/groups/${groupId}/messages?`) && path.includes('before=')) return historyRequests[historyAttempt++]!.promise
      if (path.includes(`/groups/${groupId}/messages/`) && path.endsWith('/context')) return contextRequests[contextAttempt++]!.promise
      if (path.includes(`/groups/${groupId}/tickets?`) && path.includes('before=')) return ticketPageRequests[ticketPageAttempt++]!.promise
      if (path.includes(`/groups/${groupId}/messages?`)) return response(latest)
      if (path.includes(`/groups/${secondGroupId}/messages?`)) return response([jeddahMessage])
      if (path.includes(`/groups/${groupId}/tickets?`)) return response({
        items: [{ ticket_id: '42', ticket_number: '1042', reference: 'Riyadh ticket', state_category: 'OPEN', links: [{ article_id: '91', message_id: messageId }] }],
        next_cursor: 'ticket-cursor',
      })
      if (path.includes(`/groups/${secondGroupId}/tickets?`)) return response({
        items: [{ ticket_id: '52', ticket_number: '1052', reference: 'Jeddah ticket', state_category: 'OPEN', links: [] }],
        next_cursor: null,
      })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: {
        config: { globalProperties: { $t: (message: string) => message } },
        stubs: { RouterLink: { props: ['to'], template: '<a :href="to"><slot /></a>' } },
      },
    })
    await flushPromises()

    const startDeferredReads = async () => {
      await wrapper.findAll('button').find((button) => button.text() === 'Load earlier messages')?.trigger('click')
      await wrapper.findAll('button').find((button) => button.text().startsWith('Show linked message'))?.trigger('click')
      await wrapper.findAll('button').find((button) => button.text() === 'Load more tickets')?.trigger('click')
      await wrapper.findAll('button').find((button) => button.text().includes('Jeddah Team'))?.trigger('click')
      await flushPromises()
      expect(wrapper.text()).toContain('Jeddah current conversation')
    }

    await startDeferredReads()
    expect([historyAttempt, contextAttempt, ticketPageAttempt]).toEqual([1, 1, 1])
    historyRequests[0]!.resolve(response([{ ...jeddahMessage, message_text: 'Stale Riyadh history' }]))
    contextRequests[0]!.resolve(response([{ ...jeddahMessage, message_text: 'Stale Riyadh context' }]))
    ticketPageRequests[0]!.resolve(response({
      items: [{ ticket_id: '99', ticket_number: '1099', reference: 'Stale Riyadh ticket', state_category: 'OPEN', links: [] }], next_cursor: null,
    }))
    await flushPromises()
    expect(wrapper.text()).toContain('Jeddah current conversation')
    expect(wrapper.text()).not.toMatch(/Stale Riyadh/u)

    await wrapper.findAll('button').find((button) => button.text().includes('Riyadh Operations'))?.trigger('click')
    await flushPromises()
    await startDeferredReads()
    expect([historyAttempt, contextAttempt, ticketPageAttempt]).toEqual([2, 2, 2])
    historyRequests[1]!.reject(new Error('stale history failure'))
    contextRequests[1]!.reject(new Error('stale context failure'))
    ticketPageRequests[1]!.reject(new Error('stale ticket failure'))
    await flushPromises()
    expect(wrapper.text()).toContain('Jeddah current conversation')
    expect(wrapper.text()).not.toMatch(/Earlier messages could not|Linked message context could not|More tickets could not/u)
    wrapper.unmount()
  })

  test('keeps only the latest linked-message intent and invalidates pending context on unmount', async () => {
    const secondMessageId = '13000000-0000-4000-8000-000000000002'
    const contexts = Array.from({ length: 6 }, () => deferred<Response>())
    let contextAttempt = 0
    const currentMessages = [
      { ...messageSnapshot[0], id: secondMessageId, message_text: 'Second linked message', provider_timestamp: '2026-08-20T10:01:00.000Z' },
      { ...messageSnapshot[0], message_text: 'First linked message' },
    ]
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true },
      ]))
      if (path.includes('/messages/') && path.endsWith('/context')) return contexts[contextAttempt++]!.promise
      if (path.includes('/messages?')) return response(currentMessages)
      if (path.includes('/tickets?')) return response({
        items: [{
          ticket_id: '42', ticket_number: '1042', reference: 'Riyadh ticket', state_category: 'OPEN',
          links: [{ article_id: '91', message_id: messageId }, { article_id: '92', message_id: secondMessageId }],
        }],
        next_cursor: null,
      })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const mountWorkspace = () => mount(WasalxGroups, {
      global: {
        config: { globalProperties: { $t: (message: string) => message } },
        stubs: { RouterLink: { props: ['to'], template: '<a :href="to"><slot /></a>' } },
      },
    })
    const linkedButtons = (wrapper: ReturnType<typeof mountWorkspace>) => wrapper.findAll('button')
      .filter((button) => button.text().startsWith('Show linked message'))

    const wrapper = mountWorkspace()
    await flushPromises()
    await linkedButtons(wrapper)[0]!.trigger('click')
    await linkedButtons(wrapper)[1]!.trigger('click')
    expect(contextAttempt).toBe(2)
    contexts[1]!.resolve(response([{ ...currentMessages[0], message_text: 'Newest context wins' }, currentMessages[1]]))
    await flushPromises()
    contexts[0]!.resolve(response([{ ...currentMessages[1], message_text: 'Older context must not win' }]))
    await flushPromises()
    expect(wrapper.text()).toContain('Newest context wins')
    expect(wrapper.text()).not.toContain('Older context must not win')
    const lastReplace = replace.mock.calls.at(-1) as unknown as [{ query: Record<string, string> }] | undefined
    expect(lastReplace?.[0]).toMatchObject({ query: { group: groupId, message: secondMessageId } })

    await linkedButtons(wrapper)[0]!.trigger('click')
    await linkedButtons(wrapper)[1]!.trigger('click')
    expect(contextAttempt).toBe(4)
    contexts[3]!.resolve(response([{ ...currentMessages[0], message_text: 'Newer context remains healthy' }, currentMessages[1]]))
    await flushPromises()
    contexts[2]!.reject(new Error('older context failure'))
    await flushPromises()
    expect(wrapper.text()).toContain('Newer context remains healthy')
    expect(wrapper.text()).not.toContain('Linked message context could not be loaded')

    await linkedButtons(wrapper)[0]!.trigger('click')
    expect(contextAttempt).toBe(5)
    const replaceCountBeforeUnmount = replace.mock.calls.length
    wrapper.unmount()
    contexts[4]!.resolve(response([{ ...currentMessages[1], message_text: 'Unmounted context' }]))
    await flushPromises()
    expect(replace.mock.calls).toHaveLength(replaceCountBeforeUnmount)

    const rejectedWrapper = mountWorkspace()
    await flushPromises()
    await linkedButtons(rejectedWrapper)[0]!.trigger('click')
    expect(contextAttempt).toBe(6)
    const replaceCountBeforeRejectedUnmount = replace.mock.calls.length
    rejectedWrapper.unmount()
    contexts[5]!.reject(new Error('unmounted context failure'))
    await flushPromises()
    expect(replace.mock.calls).toHaveLength(replaceCountBeforeRejectedUnmount)
  })

  test('keeps deferred create and link completion scoped to the group where each mutation began', async () => {
    const createRequest = deferred<Response>()
    const linkRequest = deferred<Response>()
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true },
        { id: secondGroupId, name: 'Jeddah Team', access_scope: 'MY', unread_count: 0, send_available: true },
      ]))
      if (path.endsWith('/group_workspace/ticket_groups')) return response([{ id: '4', name: 'Customer Care' }])
      if (path.includes(`/groups/${groupId}/messages?`)) return response(messageSnapshot)
      if (path.includes(`/groups/${secondGroupId}/messages?`)) return response([{
        ...messageSnapshot[0], id: '13000000-0000-4000-8000-000000000099', message_text: 'Jeddah current conversation',
      }])
      if (path.includes('/tickets?')) return response({ items: [], next_cursor: null })
      if (init?.method === 'POST' && path.includes(`/messages/${messageId}/tickets`)) return createRequest.promise
      if (init?.method === 'POST' && path.endsWith('/ticket_links')) return linkRequest.promise
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: {
        config: { globalProperties: { $t: (message: string) => message } },
        stubs: { RouterLink: { props: ['to'], template: '<a :href="to"><slot /></a>' } },
      },
    })
    await flushPromises()

    await wrapper.findAll('button').find((button) => button.text() === 'Create ticket')?.trigger('click')
    await flushPromises()
    await wrapper.findAll('form').find((form) => form.text().includes('Create a ticket from this message'))?.trigger('submit')
    expect(fetchMock.mock.calls.some(([input, init]) => init?.method === 'POST' && String(input).includes(`/messages/${messageId}/tickets`))).toBe(true)
    const linkWhilePending = wrapper.findAll('button').find((button) => button.text() === 'Link to ticket')
    assert.ok(linkWhilePending)
    expect(linkWhilePending.attributes()).toHaveProperty('disabled')
    await linkWhilePending.trigger('click')
    expect(wrapper.text()).toContain('Create a ticket from this message')
    expect(wrapper.text()).not.toContain('Link this message to a ticket')
    await wrapper.findAll('button').find((button) => button.text().includes('Jeddah Team'))?.trigger('click')
    await flushPromises()
    createRequest.resolve(response({ ticket_id: '43', ticket_number: '1043', article_id: '92' }))
    await flushPromises()
    expect(wrapper.text()).toContain('Jeddah current conversation')
    expect(wrapper.text()).not.toContain('Ticket updated.')

    await wrapper.findAll('button').find((button) => button.text().includes('Riyadh Operations'))?.trigger('click')
    await flushPromises()
    await wrapper.findAll('button').find((button) => button.text() === 'Link to ticket')?.trigger('click')
    await wrapper.get('input[id^="wasalx-ticket-number-"]').setValue('1042')
    await wrapper.findAll('form').find((form) => form.text().includes('Link this message to a ticket'))?.trigger('submit')
    expect(fetchMock.mock.calls.some(([input, init]) => init?.method === 'POST' && String(input).endsWith('/ticket_links'))).toBe(true)
    await wrapper.findAll('button').find((button) => button.text().includes('Jeddah Team'))?.trigger('click')
    await flushPromises()
    linkRequest.reject(new Error('stale link failure'))
    await flushPromises()
    expect(wrapper.text()).toContain('Jeddah current conversation')
    expect(wrapper.text()).not.toContain('Message could not be linked.')
    wrapper.unmount()
  })

  test('restores an in-flight attachment send after a route remount and replays the same operation safely', async () => {
    let uuidSequence = 500
    vi.mocked(globalThis.crypto.randomUUID).mockImplementation(() =>
      `00000000-0000-4000-8000-${String(uuidSequence++).padStart(12, '0')}` as ReturnType<typeof globalThis.crypto.randomUUID>)
    const original = fetchMock.getMockImplementation()
    const payloads: Array<{ request_token: string, upload_cache_id?: string, upload_store_ids?: number[] }> = []
    let sendAttempt = 0
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (init?.method === 'POST' && path.endsWith('/send')) {
        const payload = JSON.parse(String(init.body)) as { request_token: string, upload_cache_id?: string, upload_store_ids?: number[] }
        payloads.push(payload)
        sendAttempt += 1
        if (sendAttempt === 1) return new Promise<Response>(() => undefined)
        return response({ id: '14000000-0000-4000-8000-000000000089', participant_name: 'Agent One', message_text: 'Remount proof',
          from_me: true, provider_timestamp: '2026-08-20T10:01:00.000Z', latest_mutation: null, quote_allowed: false,
          ticket_creatable: false, linked_to_ticket: false, source_kind: 'DELIVERY', delivery_state: 'QUEUED' })
      }
      assert.ok(original)
      return original(input, init)
    })
    const first = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const input = first.get('input[type="file"]')
    const file = new File([Uint8Array.from([1, 2, 3, 4])], 'remount.png', { type: 'image/png' })
    Object.defineProperty(input.element, 'files', { configurable: true, value: [file] })
    await input.trigger('change')
    await flushPromises()
    await first.get('textarea').setValue('Remount proof')
    await first.get('form').trigger('submit')
    await nextTick()
    first.unmount()

    const second = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    expect((second.get('textarea').element as HTMLTextAreaElement).value).toBe('Remount proof')
    expect(second.text()).toContain('remount.png')
    expect(second.text()).toContain('Delivery could not be confirmed. Retry the unchanged message safely; it will not be sent twice.')
    await second.get('form').trigger('submit')
    await flushPromises()

    assert.equal(payloads[0]?.request_token, payloads[1]?.request_token)
    assert.equal(payloads[0]?.upload_cache_id, payloads[1]?.upload_cache_id)
    assert.deepEqual(payloads[0]?.upload_store_ids, payloads[1]?.upload_store_ids)
    expect(second.text()).not.toContain('remount.png')
    second.unmount()
  })

  test('enforces the visible total limit and removes an abandoned item through Zammad upload-cache DELETE', async () => {
    const original = fetchMock.getMockImplementation()
    fetchMock.mockImplementation(async (input, init) => {
      if (String(input).includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true,
          media_capabilities: { ...wahaMediaCapabilities, maximum_files: 2, maximum_total_bytes: 5 } },
      ]))
      assert.ok(original)
      return original(input, init)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const input = wrapper.get('input[type="file"]')
    const tooLarge = new File([Uint8Array.from([1, 2, 3, 4, 5, 6])], 'too-large.png', { type: 'image/png' })
    Object.defineProperty(input.element, 'files', { configurable: true, value: [tooLarge] })
    await input.trigger('change')
    await flushPromises()
    expect(wrapper.get('[role="alert"]').text()).toBe('These files exceed the total upload limit for this group.')
    expect(fetchMock.mock.calls.filter(([value, options]) => String(value).includes('/api/v1/upload_caches/') && options?.method === 'POST')).toHaveLength(0)

    const valid = new File([Uint8Array.from([1, 2, 3, 4])], 'remove-me.png', { type: 'image/png' })
    Object.defineProperty(input.element, 'files', { configurable: true, value: [valid] })
    await input.trigger('change')
    await flushPromises()
    expect(wrapper.text()).toContain('4 byte / 5 byte')
    await wrapper.findAll('button').find((button) => button.text() === 'Remove')?.trigger('click')
    await flushPromises()
    expect(wrapper.text()).not.toContain('remove-me.png')
    expect(fetchMock.mock.calls.some(([value, options]) => String(value).endsWith('/items/27') && options?.method === 'DELETE')).toBe(true)
    wrapper.unmount()
  })

  test.each([true, false])('waits for an attachment removal before sending (removed=%s)', async (removed) => {
    const removal = deferred<Response>()
    const original = fetchMock.getMockImplementation()!
    fetchMock.mockImplementation(async (input, init) => String(input).endsWith('/items/27') && init?.method === 'DELETE'
      ? removal.promise : original(input, init))
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const input = wrapper.get('input[type="file"]')
    Object.defineProperty(input.element, 'files', { configurable: true,
      value: [new File([Uint8Array.from([1, 2, 3, 4])], 'remove-me.png', { type: 'image/png' })] })
    await input.trigger('change')
    await flushPromises()
    await wrapper.get('textarea').setValue('Send after removing the file')
    await wrapper.get('button[aria-label="Remove remove-me.png"]').trigger('click')
    const sendButton = () => wrapper.findAll('button').find(button => button.text() === 'Send')!
    expect(sendButton().attributes('disabled')).toBeDefined()
    await wrapper.get('form').trigger('submit')
    await flushPromises()
    expect(fetchMock.mock.calls.filter(([url]) => String(url).endsWith('/send'))).toHaveLength(0)
    removal.resolve(removed ? response({ success: true }) : errorResponse())
    await flushPromises()
    expect(sendButton().attributes('disabled')).toBeUndefined()
    await wrapper.get('form').trigger('submit')
    await flushPromises()
    const sent = fetchMock.mock.calls.find(([url]) => String(url).endsWith('/send'))!
    expect(JSON.parse(String(sent[1]?.body)).upload_store_ids).toEqual(removed ? undefined : [27])
    wrapper.unmount()
  })

  test('does not expose a raw transport error when an attachment upload fails', async () => {
    const original = fetchMock.getMockImplementation()
    fetchMock.mockImplementation(async (input, init) => {
      if (String(input).includes('/api/v1/upload_caches/') && init?.method === 'POST') {
        throw new Error('socket hang up at private-upstream.internal')
      }
      assert.ok(original)
      return original(input, init)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const input = wrapper.get('input[type="file"]')
    const file = new File([Uint8Array.from([1, 2, 3])], 'proof.png', { type: 'image/png' })
    Object.defineProperty(input.element, 'files', { configurable: true, value: [file] })
    await input.trigger('change')
    await flushPromises()

    expect(wrapper.get('[role="alert"]').text()).toBe('Attachment could not be uploaded.')
    expect(wrapper.text()).not.toContain('private-upstream.internal')
    wrapper.unmount()
  })

  test('a delayed stop from the previous group cannot clear or upload into a new recording', async () => {
    FakeMediaRecorder.deferStop = true
    const original = fetchMock.getMockImplementation()
    fetchMock.mockImplementation(async (input, init) => {
      if (String(input).includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true, media_capabilities: wahaMediaCapabilities },
        { id: '12000000-0000-4000-8000-000000000002', name: 'Jeddah Operations', access_scope: 'TEAM', unread_count: 0, send_available: true, media_capabilities: wahaMediaCapabilities },
      ]))
      assert.ok(original)
      return original(input, init)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    await wrapper.findAll('button').find((button) => button.text() === 'Record voice')?.trigger('click')
    await flushPromises()
    await wrapper.findAll('button').find((button) => button.text() === 'My Team')?.trigger('click')
    await wrapper.findAll('button').find((button) => button.text().includes('Jeddah Operations'))?.trigger('click')
    await flushPromises()
    await wrapper.findAll('button').find((button) => button.text() === 'Record voice')?.trigger('click')
    await flushPromises()
    const uploadsBefore = fetchMock.mock.calls.filter(([value]) => String(value).includes('/api/v1/upload_caches/')).length
    FakeMediaRecorder.flushNextStop()
    await flushPromises()
    const uploadsAfter = fetchMock.mock.calls.filter(([value]) => String(value).includes('/api/v1/upload_caches/')).length
    expect(uploadsAfter).toBe(uploadsBefore)
    expect(wrapper.text()).toContain('Recording…')
    expect(wrapper.findAll('button').some((button) => button.text() === 'Stop recording')).toBe(true)
    wrapper.unmount()
  })

  test.each([
    ['GOWS', wahaMediaCapabilities, true, true],
    ['official API', metaMediaCapabilities, false, false],
  ])('derives %s attachment and voice controls from group capabilities', async (_label, mediaCapabilities, voiceVisible, webmAccepted) => {
    const original = fetchMock.getMockImplementation()
    fetchMock.mockImplementation(async (input, init) => {
      if (String(input).includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true, media_capabilities: mediaCapabilities },
      ]))
      assert.ok(original)
      return original(input, init)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const input = wrapper.get('input[type="file"]')
    const accepted = (input.attributes('accept') ?? '').split(',')
    expect(accepted).toContain('image/png')
    expect(accepted.includes('audio/webm')).toBe(webmAccepted)
    expect(wrapper.findAll('button').some((button) => button.text() === 'Record voice')).toBe(voiceVisible)

    const uploadsBefore = fetchMock.mock.calls.filter(([value]) => String(value).includes('/api/v1/upload_caches/')).length
    const voice = new File([Uint8Array.from([1, 2, 3])], 'voice.webm', { type: 'audio/webm' })
    Object.defineProperty(input.element, 'files', { configurable: true, value: [voice] })
    await input.trigger('change')
    await flushPromises()
    const uploadsAfter = fetchMock.mock.calls.filter(([value]) => String(value).includes('/api/v1/upload_caches/')).length
    expect(uploadsAfter - uploadsBefore).toBe(webmAccepted ? 1 : 0)
    if (webmAccepted) expect(wrapper.text()).toContain('voice.webm')
    else expect(wrapper.get('[role="alert"]').text()).toBe('This file type or size is not supported for this group.')
    wrapper.unmount()
  })

  test('hides unavailable recording controls and reports microphone denial without browser details', async () => {
    const denied = vi.fn(async () => { throw new DOMException('device name and policy details', 'NotAllowedError') })
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getUserMedia: denied } })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    await wrapper.findAll('button').find((button) => button.text() === 'Record voice')?.trigger('click')
    await flushPromises()
    expect(wrapper.get('[role="alert"]').text()).toBe('Microphone access was not available. You can attach an audio file instead.')
    expect(wrapper.text()).not.toContain('device name and policy details')
    wrapper.unmount()

    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: undefined })
    const unsupported = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    expect(unsupported.findAll('button').some((button) => button.text() === 'Record voice')).toBe(false)
    unsupported.unmount()
  })

  test('shows a bounded pending state while microphone permission is unresolved', async () => {
    const permission = deferred<MediaStream>()
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: { getUserMedia: vi.fn(() => permission.promise) },
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    await wrapper.get('textarea').setValue('Retained while asking for microphone access')
    const button = wrapper.findAll('button').find((item) => item.text() === 'Record voice')
    await button?.trigger('click')
    await flushPromises()
    expect(button?.attributes('disabled')).toBeDefined()
    expect(wrapper.get('[role="status"]').text()).toBe('Waiting for microphone permission…')
    expect(wrapper.findAll('button').find(item => item.text() === 'Send')?.attributes('disabled')).toBeDefined()
    await wrapper.get('form').trigger('submit')
    await flushPromises()
    expect(fetchMock.mock.calls.filter(([url]) => String(url).endsWith('/send'))).toHaveLength(0)
    await wrapper.findAll('button').find(item => item.text() === 'Cancel')!.trigger('click')
    expect(wrapper.findAll('button').find(item => item.text() === 'Send')?.attributes('disabled')).toBeUndefined()
    permission.resolve({ getTracks: () => [{ stop: mediaTrackStop }] } as unknown as MediaStream)
    await flushPromises()
    expect(mediaTrackStop).toHaveBeenCalledOnce()
    expect(wrapper.findAll('button').some(item => item.text() === 'Stop recording')).toBe(false)
    wrapper.unmount()
  })

  test('clears a revoked group transcript and tickets before an in-flight refresh can restore them', async () => {
    vi.useFakeTimers()
    let groupLoads = 0
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) {
        groupLoads += 1
        return response(groupPage(groupLoads === 1
          ? [{ id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true }]
          : []))
      }
      if (path.includes('/messages?')) return response(messageSnapshot)
      if (path.includes('/tickets?')) return response({ items: [
        { ticket_id: '42', ticket_number: '1042', reference: 'SHIP-42', state_category: 'OPEN', links: [] },
      ], next_cursor: null })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    expect(wrapper.text()).toContain('Shipment SHIP-42')
    expect(wrapper.text()).toContain('Ticket #1042')
    await vi.advanceTimersByTimeAsync(37_000)
    await flushPromises()
    expect(wrapper.text()).not.toContain('Shipment SHIP-42')
    expect(wrapper.text()).not.toContain('Ticket #1042')
    expect(wrapper.text()).toContain('Choose a group to view its conversation.')
    wrapper.unmount()
  })

  test('fails closed when a quiet conversation refresh loses group access', async () => {
    vi.useFakeTimers()
    let conversationLoads = 0
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true, media_capabilities: wahaMediaCapabilities },
      ]))
      if (path.includes('/messages?')) {
        conversationLoads += 1
        if (conversationLoads > 1) return { ok: false, status: 404, json: async () => ({}) } as Response
        return response(messageSnapshot)
      }
      if (path.includes('/tickets?')) return response({ items: [
        { ticket_id: '42', ticket_number: '1042', reference: 'SHIP-42', state_category: 'OPEN', links: [] },
      ], next_cursor: null })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    expect(wrapper.text()).toContain('Shipment SHIP-42')
    await vi.advanceTimersByTimeAsync(6_100)
    await flushPromises()
    expect(wrapper.text()).not.toContain('Shipment SHIP-42')
    expect(wrapper.text()).not.toContain('Ticket #1042')
    expect(wrapper.text()).toContain('Choose a group to view its conversation.')
    wrapper.unmount()
  })

  test('drops loaded older tickets until every page is reauthorized again', async () => {
    vi.useFakeTimers()
    const cursor = '18000000-0000-4000-8000-000000000001'
    let refreshed = false
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true, media_capabilities: wahaMediaCapabilities },
      ]))
      if (path.includes('/messages?')) return response(messageSnapshot)
      if (path.includes('/tickets?') && path.includes('before=')) return response({ items: [
        { ticket_id: '45', ticket_number: '1045', reference: 'Older authorized ticket', state_category: 'OPEN', links: [] },
      ], next_cursor: null })
      if (path.includes('/tickets?')) return response({ items: [refreshed
        ? { ticket_id: '46', ticket_number: '1046', reference: 'New first page', state_category: 'OPEN', links: [] }
        : { ticket_id: '42', ticket_number: '1042', reference: 'Old first page', state_category: 'OPEN', links: [] }], next_cursor: cursor })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    await wrapper.findAll('button').find((button) => button.text() === 'Load more tickets')?.trigger('click')
    await flushPromises()
    expect(wrapper.text()).toContain('Ticket #1042')
    expect(wrapper.text()).toContain('Ticket #1045')
    refreshed = true
    await vi.advanceTimersByTimeAsync(37_000)
    await flushPromises()
    expect(wrapper.text()).not.toContain('Ticket #1042')
    expect(wrapper.text()).not.toContain('Ticket #1045')
    expect(wrapper.text()).toContain('Ticket #1046')
    expect(wrapper.findAll('button').some((button) => button.text() === 'Load more tickets')).toBe(true)
    wrapper.unmount()
  })

  test.each([
    ['OUTCOME_UNKNOWN', 'Delivery outcome unconfirmed', 'Attachment delivery outcome is unconfirmed.'],
    ['BLOCKED', 'Waiting for previous message', 'Attachment is waiting for the previous message.'],
  ])('does not leave %s attachment deliveries looking like active uploads', async (deliveryState, deliveryLabel, attachmentLabel) => {
    messageSnapshot = [{
      id: '14000000-0000-4000-8000-000000000001', participant_name: 'Agent One', message_text: 'Proof attached',
      from_me: true, provider_timestamp: '2026-08-20T10:01:00.000Z', latest_mutation: null, quote_allowed: false,
      ticket_creatable: false, linked_to_ticket: false, source_kind: 'DELIVERY', delivery_state: deliveryState,
      media_filename: 'proof.png', media_mime_type: 'image/png', media_available: false,
    }]
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()

    expect(wrapper.text()).toContain(deliveryLabel)
    expect(wrapper.text()).toContain(attachmentLabel)
    expect(wrapper.text()).not.toContain('Preparing attachment…')
    wrapper.unmount()
  })

  test('explains a safely held group send with its bounded expiry instead of a generic queue label', async () => {
    messageSnapshot = [{
      id: '14000000-0000-4000-8000-000000000001', participant_name: 'Agent One', message_text: 'Operations update',
      from_me: true, provider_timestamp: '2026-08-20T10:01:00.000Z', latest_mutation: null, quote_allowed: false,
      ticket_creatable: false, linked_to_ticket: false, source_kind: 'DELIVERY', delivery_state: 'QUEUED',
      delivery_hold_reason: 'WAITING_FOR_INBOUND', delivery_next_attempt_at: '2026-08-20T10:06:00.000Z',
      delivery_hold_expires_at: '2026-08-21T10:01:00.000Z',
    }]
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()

    expect(wrapper.text()).toContain('Waiting for a recent inbound group message')
    expect(wrapper.text()).toContain('Send window expires')
    expect(wrapper.text()).not.toContain('Queued')
    wrapper.unmount()
  })

  test('renders filename-less history media and keeps revoked or expired objects safe', async () => {
    const revokedId = '13000000-0000-4000-8000-000000000014'
    messageSnapshot = [
      { id: '13000000-0000-4000-8000-000000000010', participant_name: 'Customer', message_text: '', from_me: false,
        provider_timestamp: '2026-08-20T10:05:00.000Z', latest_mutation: null, quote_allowed: true,
        ticket_creatable: false, linked_to_ticket: false, media_filename: 'proof.mp4', media_mime_type: 'video/mp4', media_kind: 'video', media_available: true },
      { id: '13000000-0000-4000-8000-000000000011', participant_name: 'Customer', message_text: '', from_me: false,
        provider_timestamp: '2026-08-20T10:04:00.000Z', latest_mutation: null, quote_allowed: true,
        ticket_creatable: false, linked_to_ticket: false, media_filename: null, media_mime_type: 'image/png', media_kind: 'image', media_available: true },
      { id: '13000000-0000-4000-8000-000000000012', participant_name: 'Customer', message_text: '', from_me: false,
        provider_timestamp: '2026-08-20T10:03:00.000Z', latest_mutation: null, quote_allowed: true,
        ticket_creatable: false, linked_to_ticket: false, media_filename: null, media_mime_type: 'audio/ogg', media_kind: 'audio', media_available: false },
      { id: '13000000-0000-4000-8000-000000000013', participant_name: 'Customer', message_text: '', from_me: false,
        provider_timestamp: '2026-08-20T10:02:00.000Z', latest_mutation: null, quote_allowed: true,
        ticket_creatable: false, linked_to_ticket: false, media_filename: null, media_mime_type: 'application/pdf', media_kind: 'document', media_available: true },
      { id: revokedId, participant_name: 'Customer', message_text: 'server fallback', from_me: false,
        provider_timestamp: '2026-08-20T10:01:00.000Z', latest_mutation: 'REVOKED', quote_allowed: true,
        ticket_creatable: true, linked_to_ticket: false, media_filename: 'private.pdf', media_mime_type: 'application/pdf', media_kind: 'document', media_available: true },
      { id: '13000000-0000-4000-8000-000000000015', participant_name: 'Customer', message_text: '', from_me: false,
        provider_timestamp: '2026-08-20T10:00:00.000Z', latest_mutation: null, quote_allowed: true,
        ticket_creatable: false, linked_to_ticket: false, media_filename: null, media_mime_type: 'image/jpeg', media_kind: 'image', media_available: false },
    ]
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()

    expect(wrapper.text()).toContain('Image')
    expect(wrapper.text()).toContain('Audio')
    expect(wrapper.text()).toContain('Document')
    expect(wrapper.text()).toContain('Attachment is unavailable.')
    expect(wrapper.text()).toContain('Message deleted')
    expect(wrapper.text()).not.toContain('Unsupported message')
    expect(wrapper.text()).not.toContain('private.pdf')
    expect(wrapper.text()).not.toContain('image/png')
    expect(wrapper.get('video[aria-label="proof.mp4"]').attributes('preload')).toBe('none')
    expect(wrapper.get('img[alt="Image"]').attributes('src')).toContain('/messages/13000000-0000-4000-8000-000000000011/media')
    expect(wrapper.findAll('a').some((link) => link.text() === 'Download file')).toBe(true)
    const revoked = wrapper.get(`[data-message-id="${revokedId}"]`)
    expect(revoked.text()).toContain('Message deleted')
    expect(revoked.text()).not.toContain('server fallback')
    expect(revoked.text()).not.toContain('private.pdf')
    expect(revoked.findAll('button').some((button) => button.text() === 'Quote')).toBe(false)
    expect(revoked.findAll('button').some((button) => button.text() === 'Create ticket')).toBe(false)
    expect(revoked.findAll('button').some((button) => button.text() === 'Link to ticket')).toBe(false)
    wrapper.unmount()
  })

  test('reflows the package-owned workspace for narrow and 200% zoom layouts', async () => {
    const wrapper = mount(WasalxGroups, {
      global: {
        config: { globalProperties: { $t: (message: string) => message } },
        stubs: { RouterLink: { props: ['to'], template: '<a :href="to"><slot /></a>' } },
      },
    })
    await flushPromises()

    expect(wrapper.find('.wasalx-workspace').exists()).toBe(true)
    expect(wrapper.find('.wasalx-group-list').exists()).toBe(true)
    expect(wrapper.find('.wasalx-conversation').exists()).toBe(true)
    expect(wrapper.find('.wasalx-ticket-list').exists()).toBe(true)
    expect(wrapper.get('.wasalx-ticket-list article p').classes()).toEqual(expect.arrayContaining(['line-clamp-2', 'break-words']))
    const source = await readFile(resolve(process.cwd(), '../../zammad-package/app/frontend/apps/desktop/pages/wasalx-groups/views/WasalxGroups.vue'), 'utf8')
    expect(source).toMatch(/<p v-if="loadingTickets && !tickets\.length"[^>]*role="status"/u)
    expect(source).toMatch(/container: wasalx-groups \/ inline-size/u)
    expect(source).toMatch(/@container wasalx-groups \(max-width: 80rem\)[\s\S]*grid-template-columns: minmax\(14rem, 18rem\) minmax\(0, 1fr\)/u)
    expect(source).toMatch(/@container wasalx-groups \(max-width: 56rem\)[\s\S]*flex-direction: column[\s\S]*overflow-y: auto/u)
    wrapper.unmount()
  })

  test('transitions a projected media send to the refreshed attachment without a blank duplicate', async () => {
    vi.useFakeTimers()
    const deliveryId = '14000000-0000-4000-8000-000000000099'
    let messageLoads = 0
    const inbound = { id: messageId, participant_name: 'Customer', message_text: 'Shipment SHIP-42', from_me: false,
      provider_timestamp: '2026-08-20T10:00:00.000Z', latest_mutation: null, quote_allowed: true,
      ticket_creatable: true, linked_to_ticket: false }
    const delivered = { id: deliveryId, participant_name: 'Agent One', sender_phone: '+13125550190', message_text: '',
      from_me: true, provider_timestamp: '2026-08-20T10:01:00.000Z', latest_mutation: null, quote_allowed: false,
      ticket_creatable: false, linked_to_ticket: false, source_kind: 'DELIVERY', delivery_state: 'SENT',
      media_filename: 'proof.png', media_mime_type: 'image/png', media_available: true }
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true, media_capabilities: wahaMediaCapabilities },
      ]))
      if (path.includes('/api/v1/upload_caches/')) return response({ data: { id: 27, filename: 'proof.png', size: '12', contentType: 'image/png' } })
      if (path.includes('/messages?')) {
        messageLoads += 1
        return response(messageLoads >= 3 ? [delivered, inbound] : [inbound])
      }
      if (path.includes('/tickets?')) return response({ items: [], next_cursor: null })
      if (init?.method === 'POST' && path.endsWith('/send')) return response({ ...delivered, delivery_state: 'QUEUED', media_available: false })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const fileInput = wrapper.get('input[type="file"]')
    const file = new File([Uint8Array.from({ length: 12 }, () => 1)], 'proof.png', { type: 'image/png' })
    Object.defineProperty(fileInput.element, 'files', { configurable: true, value: [file] })
    await fileInput.trigger('change')
    await flushPromises()
    await wrapper.get('form').trigger('submit')
    await flushPromises()
    expect(wrapper.text().match(/proof\.png/gu)).toHaveLength(1)
    expect(wrapper.text()).toContain('Preparing attachment…')
    expect(wrapper.text()).not.toContain('Unsupported message')
    await vi.advanceTimersByTimeAsync(6_100)
    await flushPromises()
    expect(wrapper.text().match(/proof\.png/gu)).toHaveLength(1)
    expect(wrapper.text()).not.toContain('Preparing attachment…')
    expect(wrapper.find(`img[alt="proof.png"]`).attributes('src')).toContain(`/messages/${deliveryId}/media`)
    expect(wrapper.text()).not.toContain('Unsupported message')
    wrapper.unmount()
  })

  test('hides exhausted earlier history after the last page', async () => {
    messageSnapshot = Array.from({ length: 50 }, (_, index) => ({
      id: `message-${index}`,
      participant_name: 'Customer',
      message_text: `Message ${index}`,
      from_me: false,
      provider_timestamp: `2026-08-20T10:${String(index).padStart(2, '0')}:00.000Z`,
      latest_mutation: null,
      quote_allowed: true,
      ticket_creatable: true,
      linked_to_ticket: false,
    }))
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true },
      ]))
      if (path.includes('/messages?') && path.includes('before=')) return response([])
      if (path.includes('/messages?')) return response(messageSnapshot)
      if (path.includes('/tickets?')) return response({ items: [], next_cursor: null })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    const button = wrapper.findAll('button').find((candidate) => candidate.text() === 'Load earlier messages')
    assert.ok(button)
    await button.trigger('click')
    await flushPromises()
    expect(wrapper.findAll('button').some((candidate) => candidate.text() === 'Load earlier messages')).toBe(false)
    wrapper.unmount()
  })

  test('keeps failed history pagination recoverable', async () => {
    messageSnapshot = Array.from({ length: 50 }, (_, index) => ({
      id: `message-${index}`,
      participant_name: 'Customer',
      message_text: `Message ${index}`,
      from_me: false,
      provider_timestamp: `2026-08-20T10:${String(index).padStart(2, '0')}:00.000Z`,
      latest_mutation: null,
      quote_allowed: true,
      ticket_creatable: true,
      linked_to_ticket: false,
    }))
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: true },
      ]))
      if (path.includes('/messages?') && path.includes('before=')) throw new Error('offline')
      if (path.includes('/messages?')) return response(messageSnapshot)
      if (path.includes('/tickets?')) return response({ items: [], next_cursor: null })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    await wrapper.findAll('button').find((candidate) => candidate.text() === 'Load earlier messages')?.trigger('click')
    await flushPromises()

    expect(wrapper.get('[role="alert"]').text()).toBe('Earlier messages could not be loaded. Try again.')
    expect(wrapper.findAll('button').some((candidate) => candidate.text() === 'Load earlier messages')).toBe(true)
    wrapper.unmount()
  })

  test('keeps the accessible-group DOM to one cursor page', async () => {
    const firstPage = Array.from({ length: 50 }, (_, index) => ({
      id: `12000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`,
      name: `Group ${String(index + 1).padStart(2, '0')}`, access_scope: 'MY', unread_count: index ? 0 : 100, send_available: false,
    }))
    const secondPage = Array.from({ length: 7 }, (_, index) => ({
      id: `12000000-0000-4000-8000-${String(index + 51).padStart(12, '0')}`,
      name: `Group ${index + 51}`, access_scope: 'MY', unread_count: 0, send_available: false,
    }))
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(path.includes('after=')
        ? groupPage(secondPage)
        : groupPage(firstPage, firstPage.at(-1)?.id ?? null))
      if (path.includes('/messages?')) return response([])
      if (path.includes('/tickets?')) return response({ items: [], next_cursor: null })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    expect(wrapper.findAll('aside [aria-current], aside button').filter((button) => /^Group \d/u.test(button.text()))).toHaveLength(50)
    expect(wrapper.text()).toContain('99+')
    await wrapper.findAll('button').find((button) => button.text() === 'Next')?.trigger('click')
    await flushPromises()
    expect(wrapper.findAll('aside button').filter((button) => /^Group \d/u.test(button.text()))).toHaveLength(7)
    expect(fetchMock.mock.calls.some(([input]) => String(input).includes(`after=${firstPage.at(-1)?.id}`))).toBe(true)
    expect(wrapper.findAll('button').some((button) => button.text() === 'Previous')).toBe(true)
    wrapper.unmount()
  })

  test('restarts a deep-linked group on its own scope before paging', async () => {
    const deepGroupId = '12000000-0000-4000-8000-000000000099'
    const allCursor = '12000000-0000-4000-8000-000000000050'
    const teamCursor = '12000000-0000-4000-8000-000000000051'
    const groupRequests: URL[] = []
    route.query = { group: deepGroupId }
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) {
        const url = new URL(path, 'https://zammad.example.invalid')
        groupRequests.push(url)
        const scope = url.searchParams.get('scope')
        const after = url.searchParams.get('after')
        if (scope === 'ALL') return response(groupPage([
          { id: deepGroupId, name: 'Deep team group', access_scope: 'TEAM', unread_count: 0, send_available: false },
        ], allCursor))
        if (scope === 'TEAM' && !after) return response(groupPage([
          { id: deepGroupId, name: 'Deep team group', access_scope: 'TEAM', unread_count: 0, send_available: false },
          { id: teamCursor, name: 'Team page one', access_scope: 'TEAM', unread_count: 0, send_available: false },
        ], teamCursor))
        if (scope === 'TEAM' && after === teamCursor) return response(groupPage([
          { id: secondGroupId, name: 'Team page two', access_scope: 'TEAM', unread_count: 0, send_available: false },
        ]))
      }
      if (path.includes('/messages?')) return response([])
      if (path.includes('/tickets?')) return response({ items: [], next_cursor: null })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    expect(groupRequests.map((request) => request.searchParams.get('scope'))).toEqual(['ALL', 'TEAM'])
    expect(groupRequests[1]?.searchParams.get('selected')).toBe(deepGroupId)
    expect(wrapper.findAll('button').find((button) => button.text().includes('Deep team group'))?.attributes('aria-current')).toBe('true')
    await wrapper.findAll('button').find((button) => button.text() === 'Next')?.trigger('click')
    await flushPromises()
    expect(groupRequests.at(-1)?.searchParams.get('scope')).toBe('TEAM')
    expect(groupRequests.at(-1)?.searchParams.get('after')).toBe(teamCursor)
    expect(groupRequests.some((request) => request.searchParams.get('after') === allCursor)).toBe(false)
    wrapper.unmount()
  })

  test('retains at most 150 transcript rows while paging through older history', async () => {
    let olderPage = 0
    const messagesForPage = (page: number) => Array.from({ length: 50 }, (_, index) => ({
      id: `message-${page}-${index}`,
      participant_name: 'Customer', message_text: `Page ${page} message ${index}`, from_me: false,
      provider_timestamp: new Date(Date.UTC(2026, 7, 20, 10) - ((page * 50) + index) * 60_000).toISOString(),
      latest_mutation: null, quote_allowed: true, ticket_creatable: true, linked_to_ticket: false,
    }))
    fetchMock.mockImplementation(async (input, init) => {
      const path = String(input)
      if (path.includes('/group_workspace/groups?')) return response(groupPage([
        { id: groupId, name: 'Riyadh Operations', access_scope: 'MY', unread_count: 0, send_available: false },
      ]))
      if (path.includes('/messages?') && path.includes('before=')) return response(messagesForPage(++olderPage))
      if (path.includes('/messages?')) return response(messagesForPage(0))
      if (path.includes('/tickets?')) return response({ items: [], next_cursor: null })
      if (init?.method === 'POST' && path.endsWith('/read')) return response({ read: true })
      throw new Error(`Unexpected request ${path}`)
    })
    const wrapper = mount(WasalxGroups, {
      global: { config: { globalProperties: { $t: (message: string) => message } } },
    })
    await flushPromises()
    for (let page = 0; page < 3; page += 1) {
      await wrapper.findAll('button').find((button) => button.text() === 'Load earlier messages')?.trigger('click')
      await flushPromises()
    }
    expect(wrapper.findAll('[data-message-id]')).toHaveLength(150)
    expect(wrapper.findAll('button').some((button) => button.text() === 'Return to latest')).toBe(true)
    wrapper.unmount()
  })
})
