// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX
import { readFileSync } from 'node:fs'
import { afterEach, describe, expect, test } from 'vitest'
import axe from 'axe-core'

import { installNativeAccessibility } from '../../zammad-package/app/frontend/shared/wasalx/accessibility.ts'

const disposers: Array<() => void> = []
const settle = () => new Promise(resolve => setTimeout(resolve, 0))
const css = readFileSync(`${process.cwd()}/../../zammad-package/app/frontend/shared/wasalx/accessibility.css`, 'utf8')
// Pinned Zammad 7.1.3 sources (tag commit 8facd9250f4e); refresh them from the new tag in each Zammad bump.
const upstream = (file: string) => readFileSync(`${process.cwd()}/../fixtures/zammad-7.1.3/app/frontend/${file}`, 'utf8')
const tokens: Record<string, string> = Object.fromEntries([...upstream('apps/desktop/styles/tokens.css').matchAll(/(--color-[\w-]+):\s*(#[\da-f]+);/gu)].map(([, name, value]) => [name, value]))
const sheet = (text: string) => Object.assign(document.createElement('style'), { textContent: text })
const overlay = () => sheet(css)
const root = () => sheet(`:root { ${Object.entries(tokens).map(([name, value]) => `${name}: ${value};`).join(' ')} }`)
const channels = (colour: string) => {
  const value = colour.replace(/var\((--[\w-]+)[^)]*\)/u, (_, name: string) => tokens[name]) // In case jsdom leaves var() unresolved.
  if (!value.startsWith('#')) return value.match(/\d+/gu)!.slice(0, 3).map(Number)
  const hex = value.length < 7 ? [...value.slice(1, 4)].map(digit => digit + digit) : value.slice(1, 7).match(/../gu)!
  return hex.map(pair => parseInt(pair, 16))
}
const luminance = (colour: string) => channels(colour).map(value => {
  const v = value / 255
  return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
}).reduce((sum, value, i) => sum + value * [0.2126, 0.7152, 0.0722][i], 0)
const contrast = (a: string, b: string) => {
  const [light, dark] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (light + 0.05) / (dark + 0.05)
}

afterEach(() => {
  disposers.splice(0).forEach(dispose => dispose())
  document.body.innerHTML = ''
  document.head.innerHTML = ''
  document.documentElement.removeAttribute('lang')
  document.documentElement.removeAttribute('data-theme')
})

describe('native desktop/mobile accessibility overlay', () => {
  test('names collapsed navigation and mobile Notifications, including late-rendered icons', async () => {
    disposers.push(installNativeAccessibility())
    document.body.innerHTML = `<nav><button id="overviews"><svg class="icon-all-tickets" aria-hidden="true"></svg></button>
      <button id="groups"></button><button aria-label="Existing action"><svg class="icon-whatsapp"></svg></button></nav>
      <footer><a href="/mobile/notifications"><svg aria-hidden="true"></svg></a></footer>`
    await settle()
    document.getElementById('groups')!.innerHTML = '<svg class="icon-whatsapp" aria-hidden="true"></svg>'
    await settle()
    expect(document.getElementById('overviews')!.getAttribute('aria-label'), document.body.innerHTML).toBe('Overviews')
    expect(document.getElementById('groups')!.getAttribute('aria-label')).toBe('WhatsApp Groups')
    expect(document.querySelector('footer a')!.getAttribute('aria-label')).toBe('Notifications')
    expect(document.querySelector('[aria-label="Existing action"]')).not.toBeNull()
    const result = await axe.run(document.body, { runOnly: ['button-name', 'link-name'] })
    expect(result.violations).toEqual([])
  })

  test('refreshes managed names on locale change without overriding native names or visible text', async () => {
    document.body.innerHTML = `<nav><button id="translated"><svg class="icon-whatsapp"></svg></button>
      <button id="native" aria-label="Native label"><svg class="icon-whatsapp"></svg></button>
      <button id="visible"><svg class="icon-whatsapp"></svg>Visible label</button></nav>`
    disposers.push(installNativeAccessibility(document, text => document.documentElement.lang === 'ar' ? `عربي ${text}` : text))
    document.documentElement.lang = 'ar'
    await settle()
    expect(document.getElementById('translated')!.getAttribute('aria-label')).toBe('عربي WhatsApp Groups')
    expect(document.getElementById('native')!.getAttribute('aria-label')).toBe('Native label')
    expect(document.getElementById('visible')!.hasAttribute('aria-label')).toBe(false)
  })

  test.each(['desktop', 'mobile'])('associates the %s blank reply with its own visible label', async shell => {
    document.body.innerHTML = `<main data-shell="${shell}"><label for="body-one">Text</label>
      <div id="body-one" name="body" contenteditable="true" role="textbox"><p></p></div>
      <label id="existing-label" for="body-two">نص</label>
      <div id="body-two" name="body" contenteditable="true" role="textbox"></div>
      <div id="custom" name="body" contenteditable="true" role="textbox" aria-label="Custom reply"></div></main>`
    disposers.push(installNativeAccessibility())
    expect(document.getElementById('body-one')!.getAttribute('aria-labelledby')).toBe('body-one-wasalx-label')
    expect(document.getElementById('body-two')!.getAttribute('aria-labelledby')).toBe('existing-label')
    expect(document.getElementById('custom')!.getAttribute('aria-label')).toBe('Custom reply')
    const result = await axe.run(document.body, { runOnly: ['aria-input-field-name'] })
    expect(result.violations).toEqual([])
  })

  test('labels an editor when its native label arrives later, without changing draft contents', async () => {
    document.body.innerHTML = '<div id="body-late" name="body" contenteditable="true" role="textbox"><p>Unsent draft</p></div>'
    disposers.push(installNativeAccessibility())
    document.body.insertAdjacentHTML('afterbegin', '<label for="body-late">Text</label>')
    await settle()
    expect(document.getElementById('body-late')!.getAttribute('aria-labelledby')).toBe('body-late-wasalx-label')
    expect(document.getElementById('body-late')!.innerHTML).toBe('<p>Unsent draft</p>')
  })

  test('keeps hidden compact header controls inert and restores their visible state', async () => {
    document.body.innerHTML = '<header class="ticket-detail-grid-compact opacity-0" aria-hidden="true"><button tabindex="0">Highlighter color: Yellow</button></header><header id="other" aria-hidden="true"></header>'
    disposers.push(installNativeAccessibility())
    const header = document.querySelector('header')!
    expect(header.hasAttribute('inert')).toBe(true)
    expect(document.getElementById('other')!.hasAttribute('inert')).toBe(false)
    header.setAttribute('aria-hidden', 'false')
    await settle()
    expect(header.hasAttribute('inert')).toBe(false)
    expect(header.querySelector('button')!.tabIndex).toBe(0)
    header.setAttribute('aria-hidden', 'true')
    header.innerHTML = '<button>New hidden control</button>'
    await settle()
    expect(header.hasAttribute('inert')).toBe(true)
  })

  test('pinned Zammad 7.1.3 still renders the roles and attributes the contrast overrides match', () => {
    const indicator = upstream('apps/desktop/components/CommonTicketStateIndicator/CommonTicketStateIndicator.vue')
    expect(indicator).toMatch(/<CommonBadge :variant="badgeVariant" role="group"[^>]*>\s*<CommonTicketStateIndicatorIcon/u)
    expect(indicator).toMatch(/case EnumTicketStateColorCode\.Closed:\s*return 'success'/u)
    const icon = upstream('apps/desktop/components/CommonTicketStateIndicator/CommonTicketStateIndicatorIcon.vue')
    expect(icon).toMatch(/<CommonIcon\s+role="status"/u)
    expect(icon).toMatch(/case EnumTicketStateColorCode\.Closed:\s*return 'check-circle-outline'\s/u)
    expect(upstream('shared/components/CommonIcon/CommonIcon.vue')).toMatch(/<svg[^>]*>\s*<use :href="`#icon-\$\{iconName\}`" \/>\s*<\/svg>/u)
    expect(upstream('apps/desktop/initializer/initializeGlobalComponentStyles.ts')).toContain("success: 'bg-green-300 text-green-500 dark:bg-green-900 dark:text-green-500',")
    const sso = upstream('apps/desktop/components/CommonThirdPartyAuthenticationButton/CommonThirdPartyAuthenticationButton.vue')
    expect(sso).toMatch(/<form role="form" method="post" :action="url">/u)
    expect(sso).toMatch(/<CommonButton\s+type="submit"/u)
    const button = upstream('apps/desktop/components/CommonButton/CommonButton.vue')
    expect(button).toMatch(/<button\s[^>]*:type="type"/u)
    expect(button).toMatch(/case 'primary':\s*return \['bg-blue-800', 'hover:bg-blue-800', 'text-white'\]/u)
    expect(button).toMatch(/<CommonIcon\s+v-if="icon"[\s\S]*?\/>\s*<span v-else class="truncate">\s*<slot>/u)
    expect(upstream('apps/desktop/pages/authentication/components/LoginThirdParty.vue')).toMatch(/<CommonThirdPartyAuthenticationButton[^>]*button-variant="primary"/u)
    expect(upstream('apps/mobile/pages/authentication/components/LoginThirdParty.vue')).not.toContain('role="form"')
    expect(upstream('shared/components/CommonIcon/CommonIcon.vue')).toContain('Zammad Foundation')
    // Overrides must not depend on Zammad's utility classes.
    const selectors = css.replace(/\/\*[\s\S]*?\*\//gu, '').match(/[^{}]+(?=\{)/gu)!.map(selector => selector.replace(/'[^']*'/gu, ''))
    expect(selectors.filter(selector => selector.includes('.'))).toEqual([])
  })

  test('makes every native CLOSED chip readable in both themes and leaves other chips alone', () => {
    const t = tokens
    const native = document.createElement('style')
    native.textContent = `.bg-green-300 { background-color: ${t['--color-green-300']} } .text-green-500 { color: ${t['--color-green-500']} }
      [data-theme='dark'] .dark\\:bg-green-900 { background-color: ${t['--color-green-900']} } [data-theme='dark'] .dark\\:text-green-500 { color: ${t['--color-green-500']} }
      .bg-blue-200 { background-color: ${t['--color-blue-200']} } .text-stone-200 { color: ${t['--color-stone-200']} }`
    const chip = (id: string, variant: string, iconName: string, label: string) => `<span id="${id}" role="group" class="cursor-default inline-flex justify-center items-center border-0 ${variant} px-2 py-1 text-xs rounded-md uppercase"><svg xmlns="http://www.w3.org/2000/svg" class="icon fill-current ltr:mr-1.5 rtl:ml-1.5" width="12" height="12" role="status" aria-live="polite" aria-roledescription="(ticket status: ${label})" aria-label="${label}"><use href="#icon-${iconName}"></use></svg>${label.toUpperCase()}</span>`
    const success = 'bg-green-300 text-green-500 dark:bg-green-900 dark:text-green-500'
    document.body.innerHTML = `<table><tr><td>${chip('closed', success, 'check-circle-outline', 'closed')}</td></tr></table>
      <header>${chip('pending', 'bg-blue-200 text-stone-200', 'check-circle-outline-dashed', 'pending reminder')}</header>
      <div id="alert" role="group" class="bg-green-300 text-green-500"><svg role="img"><use href="#icon-check-circle-outline"></use></svg>Saved</div>
      <div id="mobile" role="group" class="bg-green-300 text-green-500"><svg aria-label="(state: closed)"><use href="#icon-check-circle-no"></use></svg></div>`
    for (const theme of ['light', 'dark']) {
      document.documentElement.setAttribute('data-theme', theme)
      for (const order of [[native, overlay(), root()], [overlay(), native, root()]]) {
        document.head.replaceChildren(...order)
        const closed = getComputedStyle(document.getElementById('closed')!)
        expect(contrast(closed.color, closed.backgroundColor), theme).toBeGreaterThanOrEqual(4.5)
        expect(channels(closed.color)).toEqual(channels(t[theme === 'dark' ? '--color-green-300' : '--color-green-700']))
        expect(channels(closed.backgroundColor)).toEqual(channels(t[theme === 'dark' ? '--color-green-900' : '--color-green-300']))
        expect(channels(getComputedStyle(document.getElementById('pending')!).color)).toEqual(channels(t['--color-stone-200']))
        for (const id of ['alert', 'mobile']) {
          expect(channels(getComputedStyle(document.getElementById(id)!).color)).toEqual(channels(t['--color-green-500']))
        }
      }
    }
    expect(document.querySelector('[data-test-id]')).toBeNull() // Production transform strips test IDs.
    expect(css).toContain('@media (forced-colors: active)')
    expect(css).toContain('color: CanvasText')
  })

  test('makes desktop OpenID login text readable in both themes without changing other providers, mobile or linked accounts', () => {
    const t = tokens
    const native = document.createElement('style')
    native.textContent = `.bg-blue-800 { background-color: ${t['--color-blue-800']} } .text-white { color: ${t['--color-white']} }
      .bg-gray-600 { background-color: ${t['--color-gray-600']} } .bg-transparent { background-color: transparent } .text-blue-800 { color: ${t['--color-blue-800']} }`
    const base = 'inline-flex h-min min-h-min shrink-0 flex-nowrap items-center justify-center gap-x-1 border-0 font-normal shadow-none'
    const desktop = (id: string, action: string, label: string) => `<form role="form" method="post" action="${action}" class="grow basis-[calc(50%-theme(spacing.2))]"><input type="hidden" name="authenticity_token" value="synthetic"><button id="${id}" type="submit" aria-label="${label}" tabindex="0" class="${base} bg-blue-800 hover:bg-blue-800 text-white text-base px-4 py-2.5 rounded-xl w-full"><svg aria-hidden="true" class="icon fill-current pointer-events-none shrink-0"><use href="#icon-openid-connect"></use></svg><span class="truncate">${label}</span></button></form>`
    document.body.innerHTML = `<section class="mt-2.5 w-full"><div class="flex flex-wrap gap-2">
      ${desktop('sso-query', '/auth/openid_connect?fingerprint=synthetic', 'WasalX SSO')}${desktop('sso-plain', '/auth/openid_connect', 'WasalX SSO')}
      ${desktop('other-provider', '/auth/google_oauth2?fingerprint=synthetic', 'Other provider')}${desktop('prefix-collision', '/auth/openid_connect_extra?fingerprint=synthetic', 'Other path')}
      </div></section>
      <form class="flex min-w-1/2 grow" method="post" action="/auth/openid_connect?fingerprint=synthetic"><button id="mobile" class="m-1 flex h-14 w-full rounded-xl bg-gray-600 px-4 py-2 text-white"><svg aria-hidden="true"><use href="#icon-openid-connect"></use></svg><span class="truncate text-xl leading-7">Mobile SSO</span></button></form>
      <form role="form" method="post" action="/auth/openid_connect?fingerprint=synthetic"><button id="linked" type="submit" aria-label="Link account" class="${base} bg-transparent hover:bg-transparent text-blue-800 flex"><svg aria-hidden="true" class="icon fill-current pointer-events-none block shrink-0"><use href="#icon-plus"></use></svg></button></form>`
    for (const theme of ['light', 'dark']) {
      document.documentElement.setAttribute('data-theme', theme)
      for (const order of [[native, overlay(), root()], [overlay(), native, root()]]) {
        document.head.replaceChildren(...order)
        for (const id of ['sso-query', 'sso-plain']) {
          const button = document.getElementById(id)!
          const style = getComputedStyle(button)
          expect(contrast(getComputedStyle(button.querySelector('span')!).color, style.backgroundColor), `${theme} ${id}`).toBeGreaterThanOrEqual(4.5)
          expect(channels(style.backgroundColor)).toEqual(channels(t['--color-blue-800']))
        }
        for (const id of ['other-provider', 'prefix-collision', 'mobile']) {
          expect(channels(getComputedStyle(document.getElementById(id)!).color), id).toEqual(channels(t['--color-white']))
        }
        expect(channels(getComputedStyle(document.getElementById('linked')!).color)).toEqual(channels(t['--color-blue-800']))
      }
    }
    expect(document.querySelector('[data-test-id]')).toBeNull() // Production transform strips test IDs.
    const form = document.getElementById('sso-query')!.closest('form')!
    expect(form.querySelector('[name="authenticity_token"]')?.getAttribute('value')).toBe('synthetic')
    expect(css).not.toContain('forced-color-adjust: none')
    expect(css).toContain('color: ButtonText')
  })

})
