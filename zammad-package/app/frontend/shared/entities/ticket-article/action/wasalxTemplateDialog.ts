// SPDX-License-Identifier: AGPL-3.0-only

type Template = {
  id: string
  name: string
  language: string
  text: string
  parameterCount: number
  semanticSha256: string
}

export async function openWasalxTemplateDialog(ticketId: string) {
  if (!/^[1-9][0-9]{0,15}$/.test(ticketId) || document.getElementById('wasalx-template-dialog')) return

  const trigger = document.activeElement
  const endpoint = `/api/v1/wasalx/tickets/${ticketId}/templates`
  const csrf = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content
  const request = (body?: object) => fetch(endpoint, {
    method: body ? 'POST' : 'GET',
    credentials: 'same-origin',
    cache: 'no-store',
    signal: AbortSignal.timeout(20_000),
    headers: { Accept: 'application/json', ...(csrf ? { 'X-CSRF-Token': csrf } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}) },
    ...(body ? { body: JSON.stringify({ input: body }) } : {}),
  })

  const dialog = document.createElement('dialog')
  dialog.id = 'wasalx-template-dialog'
  dialog.dir = document.documentElement.dir || (/^ar(?:-|$)/i.test(document.documentElement.lang) ? 'rtl' : 'ltr')
  dialog.className = 'rounded-lg border bg-white p-5 text-start text-black dark:bg-gray-900 dark:text-white'
  dialog.style.inlineSize = 'min(32rem, calc(100% - 2rem))'
  dialog.setAttribute('aria-labelledby', 'wasalx-template-heading')
  const heading = document.createElement('h2')
  heading.id = 'wasalx-template-heading'
  heading.textContent = __('Send WhatsApp template')
  heading.className = 'text-lg font-semibold'

  const status = document.createElement('p')
  status.setAttribute('role', 'status')
  status.textContent = __('Loading approved templates…')
  const close = document.createElement('button')
  close.type = 'button'
  close.textContent = __('Close')
  close.className = 'rounded border px-3 py-2'
  close.autofocus = true
  close.addEventListener('click', () => dialog.close())
  dialog.addEventListener('cancel', event => {
    if (close.disabled) event.preventDefault()
  })
  dialog.addEventListener('close', () => {
    dialog.remove()
    if (trigger instanceof HTMLElement && trigger.isConnected) trigger.focus()
  }, { once: true })
  dialog.append(heading, status, close)
  document.body.append(dialog)
  dialog.showModal()

  let templates: Template[]
  try {
    const response = await request()
    if (!response.ok) throw new Error('Catalog unavailable')
    const catalog = await response.json() as { window: 'OPEN' | 'CLOSED' | 'UNKNOWN'; templates: Template[] }
    if (!dialog.open) return
    if (catalog.window !== 'CLOSED') {
      status.textContent = catalog.window === 'OPEN'
        ? __('The customer-service window is open. Use Reply on WhatsApp.')
        : __('The customer-service window could not be verified.')
      return
    }
    templates = catalog.templates
    if (!templates.length) {
      status.textContent = __('There are no approved templates available for this ticket.')
      return
    }
  } catch {
    status.textContent = __('Approved templates could not be loaded. Close this window and try again.')
    return
  }

  const form = document.createElement('form')
  form.className = 'my-3 grid gap-3'
  const label = document.createElement('label')
  label.className = 'grid gap-1'
  const select = document.createElement('select')
  select.className = 'w-full rounded border bg-transparent p-2'
  select.required = true
  select.append(new Option(__('Select an approved template'), ''))
  for (const template of templates) select.append(new Option(`${template.name} (${template.language})`, template.id))
  label.append(__('Approved template'), select)
  const body = document.createElement('p')
  body.className = 'whitespace-pre-wrap wrap-break-word rounded border p-2'
  body.dir = 'auto'
  body.hidden = true
  const parameters = document.createElement('div')
  parameters.className = 'grid gap-2'
  const send = document.createElement('button')
  send.type = 'submit'
  send.textContent = __('Send template')
  send.className = 'rounded border px-3 py-2 font-semibold'
  send.disabled = true

  let selected: Template | undefined
  let fields: HTMLInputElement[] = []
  select.addEventListener('change', () => {
    selected = templates.find(template => template.id === select.value)
    body.hidden = !selected
    body.lang = selected?.language.replaceAll('_', '-') ?? ''
    body.textContent = selected?.text ?? ''
    send.disabled = !selected
    parameters.replaceChildren()
    fields = Array.from({ length: selected?.parameterCount ?? 0 }, (_, index) => {
      const parameter = document.createElement('label')
      parameter.className = 'grid gap-1'
      const input = document.createElement('input')
      input.className = 'rounded border bg-transparent p-2'
      input.type = 'text'
      input.dir = 'auto'
      input.maxLength = 1024
      input.required = true
      parameter.append(`${__('Template parameter')} ${index + 1}`, input)
      parameters.append(parameter)
      return input
    })
  })

  const requestToken = crypto.randomUUID()
  form.addEventListener('submit', async event => {
    event.preventDefault()
    if (!selected || send.disabled) return
    const values = fields.map(field => field.value.trim())
    if (values.some(value => !value)) {
      status.textContent = __('Enter a value for each template parameter.')
      fields[values.indexOf('')]?.focus()
      return
    }
    send.disabled = close.disabled = select.disabled = true
    for (const field of fields) field.readOnly = true
    status.textContent = __('Queueing the template…')
    try {
      const response = await request({ request_token: requestToken, template_id: selected.id,
        template_sha256: selected.semanticSha256, parameters: values })
      if (!response.ok) throw new Error('Template delivery unavailable')
      form.remove()
      status.textContent = __('Template queued. Follow its delivery status on this ticket.')
    } catch {
      status.textContent = __('Could not confirm the send. Retry this same template to check.')
      send.disabled = false
    } finally {
      close.disabled = false
      if (send.isConnected) send.focus()
      else close.focus()
    }
  })
  form.append(label, body, parameters, send)
  status.textContent = ''
  dialog.insertBefore(form, status)
  select.focus()
}
