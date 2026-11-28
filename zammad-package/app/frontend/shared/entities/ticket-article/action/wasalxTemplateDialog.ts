// SPDX-License-Identifier: AGPL-3.0-only

import { i18n } from '#shared/i18n/index.ts'

type Template = {
  id: string
  name: string
  language: string
  text: string
  parameterCount: number
  semanticSha256: string
}
type Receipt = { id: string; state: string }
type Recovery = { token: string; id?: string }
const uuid =
  /^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i
const settled = new Set(['SENT', 'DELIVERED', 'READ', 'FAILED_TERMINAL'])

export async function openWasalxTemplateDialog(
  ticketId: string,
  stateLabel: (state: string) => string,
) {
  if (
    !/^[1-9][0-9]{0,15}$/.test(ticketId) ||
    document.getElementById('wasalx-template-dialog')
  )
    return

  const trigger = document.activeElement
  const endpoint = `/api/v1/wasalx/tickets/${ticketId}/templates`
  const csrf = document.querySelector<HTMLMetaElement>(
    'meta[name="csrf-token"]',
  )?.content
  const request = (body?: object, query = '') =>
    fetch(endpoint + query, {
      method: body ? 'POST' : 'GET',
      credentials: 'same-origin',
      cache: 'no-store',
      signal: AbortSignal.timeout(20_000),
      headers: {
        Accept: 'application/json',
        ...(csrf ? { 'X-CSRF-Token': csrf } : {}),
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      ...(body ? { body: JSON.stringify({ input: body }) } : {}),
    })

  const dialog = document.createElement('dialog')
  dialog.id = 'wasalx-template-dialog'
  dialog.dir =
    document.documentElement.dir ||
    (/^ar(?:-|$)/i.test(document.documentElement.lang) ? 'rtl' : 'ltr')
  dialog.className =
    'rounded-lg border bg-white p-5 text-start text-black dark:bg-gray-900 dark:text-white'
  dialog.style.inlineSize = 'min(32rem, calc(100% - 2rem))'
  dialog.setAttribute('aria-labelledby', 'wasalx-template-heading')
  const heading = document.createElement('h2')
  heading.id = 'wasalx-template-heading'
  heading.textContent = i18n.t('Send WhatsApp template')
  heading.className = 'text-lg font-semibold'

  const status = document.createElement('p')
  status.setAttribute('role', 'status')
  status.textContent = i18n.t('Loading approved templates…')
  const close = document.createElement('button')
  close.type = 'button'
  close.textContent = i18n.t('Close')
  close.className = 'rounded border px-3 py-2'
  close.autofocus = true
  close.addEventListener('click', () => dialog.close())
  dialog.addEventListener('cancel', (event) => {
    if (close.disabled) event.preventDefault()
  })
  dialog.addEventListener(
    'close',
    () => {
      dialog.remove()
      if (trigger instanceof HTMLElement && trigger.isConnected) trigger.focus()
    },
    { once: true },
  )
  dialog.append(heading, status, close)
  document.body.append(dialog)
  dialog.showModal()

  let storageKey: string
  let recoveryScope: string
  let recovery: Recovery | undefined
  const retryMessage = i18n.t(
    'Could not confirm the send. You can change the template or its values and try again.',
  )
  const refresh = document.createElement('button')
  const another = document.createElement('button')
  for (const button of [refresh, another]) {
    button.type = 'button'
    button.className = close.className
    button.hidden = true
    dialog.insertBefore(button, close)
  }
  refresh.textContent = i18n.t('Check template delivery status')
  another.textContent = i18n.t('Send another template')

  // Only opaque identifiers survive a reload. The server scopes the storage
  // key to this signed-in agent and ticket, independently of the CSRF mask.
  const save = (value: Recovery) => {
    sessionStorage.setItem(storageKey, JSON.stringify(value))
    recovery = value
  }
  const showReceipt = (receipt: Receipt) => {
    status.textContent = stateLabel(receipt.state)
    refresh.hidden = false
    another.hidden = !settled.has(receipt.state)
  }
  const recover = async () => {
    if (!recovery) return null
    const query = new URLSearchParams({
      request_token: recovery.token,
      scope: recoveryScope,
    })
    if (recovery.id) query.set('delivery_id', recovery.id)
    const response = await request(undefined, `?${query}`)
    if (!response.ok) throw new Error('Template receipt unavailable')
    const { delivery } = (await response.json()) as { delivery: Receipt | null }
    if (!dialog.open) return null
    if (delivery === null && !recovery.id) return null
    if (
      !delivery ||
      !uuid.test(delivery.id) ||
      (recovery.id && recovery.id !== delivery.id) ||
      typeof delivery.state !== 'string'
    )
      throw new Error('Invalid template receipt')
    save({ token: recovery.token, id: delivery.id })
    return delivery
  }
  refresh.addEventListener('click', async () => {
    refresh.disabled = another.disabled = true
    try {
      const receipt = await recover()
      if (receipt && dialog.open) showReceipt(receipt)
    } catch {
      another.hidden = true
      status.textContent = i18n.t(
        'Template delivery status could not be checked.',
      )
    } finally {
      refresh.disabled = another.disabled = false
    }
  })

  // A resolved receipt is replaced only after the agent requests a new send.
  another.addEventListener('click', () => {
    try {
      sessionStorage.removeItem(storageKey)
    } catch {
      status.textContent = i18n.t(
        'Template delivery status could not be checked.',
      )
      return
    }
    recovery = undefined
    another.hidden = refresh.hidden = true
    status.textContent = i18n.t('Loading approved templates…')
    void loadCatalog()
  })

  try {
    const response = await request(undefined, '?recovery=1')
    if (!response.ok) throw new Error('Template recovery scope unavailable')
    const { scope } = (await response.json()) as { scope: string }
    if (typeof scope !== 'string' || !/^[a-f0-9]{64}$/.test(scope))
      throw new Error('Invalid template recovery scope')
    recoveryScope = scope
    storageKey = `wasalx:ticket-template:${scope}`
    const saved = sessionStorage.getItem(storageKey)
    if (saved !== null) {
      const value = JSON.parse(saved) as Recovery
      if (
        !value ||
        typeof value.token !== 'string' ||
        !uuid.test(value.token) ||
        (value.id !== undefined &&
          (typeof value.id !== 'string' || !uuid.test(value.id)))
      )
        throw new Error('Invalid template recovery record')
      recovery = value
      const receipt = await recover()
      if (!dialog.open) return
      if (receipt) {
        showReceipt(receipt)
        return
      }
    }
  } catch {
    status.textContent = i18n.t(
      'Template delivery status could not be checked.',
    )
    return
  }

  async function loadCatalog() {
    if (!dialog.open) return
    let templates: Template[]
    try {
      const response = await request()
      if (!response.ok) throw new Error('Catalog unavailable')
      const catalog = (await response.json()) as {
        window: 'OPEN' | 'CLOSED' | 'UNKNOWN'
        templates: Template[]
      }
      if (!dialog.open) return
      if (catalog.window !== 'CLOSED') {
        status.textContent =
          catalog.window === 'OPEN'
            ? i18n.t(
                'The customer-service window is open. Use Reply on WhatsApp.',
              )
            : i18n.t('The customer-service window could not be verified.')
        return
      }
      templates = catalog.templates
      if (!templates.length) {
        status.textContent = i18n.t(
          'There are no approved templates available for this ticket.',
        )
        return
      }
    } catch {
      status.textContent = i18n.t(
        'Approved templates could not be loaded. Close this window and try again.',
      )
      return
    }

    const form = document.createElement('form')
    form.className = 'my-3 grid gap-3'
    const label = document.createElement('label')
    label.className = 'grid gap-1'
    const select = document.createElement('select')
    select.className = 'w-full rounded border bg-transparent p-2'
    select.required = true
    select.append(new Option(i18n.t('Select an approved template'), ''))
    for (const template of templates)
      select.append(
        new Option(`${template.name} (${template.language})`, template.id),
      )
    label.append(i18n.t('Approved template'), select)
    const body = document.createElement('p')
    body.className = 'whitespace-pre-wrap wrap-break-word rounded border p-2'
    body.dir = 'auto'
    body.hidden = true
    const parameters = document.createElement('div')
    parameters.className = 'grid gap-2'
    const send = document.createElement('button')
    send.type = 'submit'
    send.textContent = i18n.t('Send template')
    send.className = 'rounded border px-3 py-2 font-semibold'
    send.disabled = true

    let selected: Template | undefined
    let fields: HTMLInputElement[] = []
    select.addEventListener('change', () => {
      selected = templates.find((template) => template.id === select.value)
      body.hidden = !selected
      body.lang = selected?.language.replaceAll('_', '-') ?? ''
      body.textContent = selected?.text ?? ''
      send.disabled = !selected
      parameters.replaceChildren()
      fields = Array.from(
        { length: selected?.parameterCount ?? 0 },
        (_, index) => {
          const parameter = document.createElement('label')
          parameter.className = 'grid gap-1'
          const input = document.createElement('input')
          input.className = 'rounded border bg-transparent p-2'
          input.type = 'text'
          input.dir = 'auto'
          input.maxLength = 1024
          input.required = true
          parameter.append(i18n.t('Template parameter %s', index + 1), input)
          parameters.append(parameter)
          return input
        },
      )
    })

    form.addEventListener('submit', async (event) => {
      event.preventDefault()
      if (!selected || send.disabled) return
      const values = fields.map((field) => field.value.trim())
      if (values.some((value) => !value)) {
        status.textContent = i18n.t(
          'Enter a value for each template parameter.',
        )
        fields[values.indexOf('')]?.focus()
        return
      }
      const token = recovery?.token ?? crypto.randomUUID()
      try {
        save({ token })
      } catch {
        status.textContent = i18n.t(
          'This browser could not save the template request. The template was not sent.',
        )
        return
      }
      send.disabled = close.disabled = select.disabled = true
      for (const field of fields) field.readOnly = true
      status.textContent = i18n.t('Queueing the template…')
      try {
        const response = await request({
          scope: recoveryScope,
          request_token: token,
          template_id: selected.id,
          template_sha256: selected.semanticSha256,
          parameters: values,
        })
        if (!response.ok && response.status !== 409)
          throw new Error('Template delivery unavailable')
        // A changed selection can only queue under this token if it is unused.
        // If the earlier send won, show its receipt instead.
        const receipt = response.ok
          ? ((await response.json()) as Receipt)
          : await recover()
        if (
          !receipt ||
          !uuid.test(receipt.id) ||
          typeof receipt.state !== 'string'
        )
          throw new Error('Invalid template receipt')
        if (response.ok) save({ token, id: receipt.id })
        form.remove()
        showReceipt(receipt)
        if (response.status === 409)
          status.append(
            document.createElement('br'),
            i18n.t(
              'An earlier send was already queued. Your changes were not sent.',
            ),
          )
      } catch {
        status.textContent = retryMessage
        send.disabled = select.disabled = false
        for (const field of fields) field.readOnly = false
      } finally {
        close.disabled = false
        if (send.isConnected) send.focus()
        else close.focus()
      }
    })
    form.append(label, body, parameters, send)
    status.textContent = recovery ? retryMessage : ''
    dialog.insertBefore(form, status)
    select.focus()
  }

  await loadCatalog()
}
