// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
import { readFileSync } from 'node:fs'
import { afterEach, describe, expect, test } from 'vitest'
import axe from 'axe-core'

import { installNativeAccessibility } from '../../zammad-package/app/frontend/shared/wasalx/accessibility.ts'

const disposers: Array<() => void> = []
const settle = () => new Promise(resolve => setTimeout(resolve, 0))
const css = readFileSync(`${process.cwd()}/../../zammad-package/app/frontend/shared/wasalx/accessibility.css`, 'utf8')

afterEach(() => {
  disposers.splice(0).forEach(dispose => dispose())
  document.body.innerHTML = ''
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

  test('uses readable CLOSED colors in both themes and leaves unrelated badges alone', () => {
    const style = document.createElement('style')
    style.textContent = css
    document.body.append(style)
    document.body.insertAdjacentHTML('beforeend', `<header class="ticket-detail-grid-full"><span id="closed" role="group" class="cursor-default bg-green-300 text-green-500">CLOSED</span><span id="inside-unrelated" role="group" class="bg-green-300 text-green-500">Not a badge</span></header>
      <span id="unrelated" role="group" class="cursor-default bg-green-300 text-green-500">Other content</span>`)
    const luminance = (rgb: string) => rgb.match(/\d+/g)!.map(Number).map(value => {
      const v = value / 255
      return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
    }).reduce((sum, value, i) => sum + value * [0.2126, 0.7152, 0.0722][i], 0)
    for (const theme of ['light', 'dark']) {
      document.documentElement.setAttribute('data-theme', theme)
      const styles = getComputedStyle(document.getElementById('closed')!)
      const values = [luminance(styles.color), luminance(styles.backgroundColor)].sort((a, b) => b - a)
      expect((values[0] + 0.05) / (values[1] + 0.05)).toBeGreaterThanOrEqual(4.5)
    }
    expect(document.querySelector('[data-test-id]')).toBeNull() // Production transform strips test IDs.
    for (const id of ['unrelated', 'inside-unrelated']) {
      expect(getComputedStyle(document.getElementById(id)!).backgroundColor).not.toBe('rgb(187, 224, 203)')
      expect(getComputedStyle(document.getElementById(id)!).backgroundColor).not.toBe('rgb(23, 53, 38)')
    }
    expect(css).toContain('@media (forced-colors: active)')
    expect(css).toContain('color: CanvasText')
  })

  test('keeps anonymous OpenID login text readable without changing other providers or native interaction styles', () => {
    const native = document.createElement('style')
    native.textContent = '.bg-blue-800 { background-color: rgb(35, 162, 205) } .text-white { color: white } .bg-gray-600 { background-color: rgb(82, 82, 91) } button { outline: 1px solid rgb(35, 162, 205); outline-offset: 1px }'
    const overlay = document.createElement('style')
    overlay.textContent = css
    document.body.innerHTML = `<section class="mt-2.5 w-full"><div class="mb-2.5 flex justify-center"></div><div class="flex flex-wrap gap-2">
      <form method="post" action="/auth/openid_connect?fingerprint=synthetic"><input type="hidden" name="authenticity_token" value="synthetic"><button id="sso-query" type="submit" class="bg-blue-800 text-white hover:bg-blue-800"><span>WasalX SSO</span></button></form>
      <form method="post" action="/auth/openid_connect"><button id="sso-plain" class="bg-blue-800 text-white"><span>WasalX SSO</span></button></form>
      <form action="/auth/google_oauth2?fingerprint=synthetic"><button id="other-provider" class="bg-blue-800 text-white">Other provider</button></form>
      <form action="/auth/openid_connect_extra?fingerprint=synthetic"><button id="prefix-collision" class="bg-blue-800 text-white">Other path</button></form>
      <form action="/auth/openid_connect?fingerprint=synthetic"><button id="mobile" class="bg-gray-600 text-white">Mobile SSO</button></form>
      </div></section><section class="mt-2.5 w-full"><div class="flex"><form action="/auth/openid_connect"><button id="outside-layout" class="bg-blue-800 text-white">Outside provider row</button></form></div></section><form action="/auth/openid_connect"><button id="outside-login" class="bg-blue-800 text-white">Linked account</button></form>`
    const luminance = (rgb: string) => rgb.match(/\d+/g)!.map(Number).map(value => {
      const v = value / 255
      return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
    }).reduce((sum, value, i) => sum + value * [0.2126, 0.7152, 0.0722][i], 0)
    for (const theme of ['light', 'dark']) {
      document.documentElement.setAttribute('data-theme', theme)
      for (const order of [[native, overlay], [overlay, native]]) {
        document.body.prepend(...order)
        for (const id of ['sso-query', 'sso-plain']) {
          const button = document.getElementById(id)!
          const style = getComputedStyle(button)
          const text = getComputedStyle(button.querySelector('span')!)
          const values = [luminance(text.color), luminance(style.backgroundColor)].sort((a, b) => b - a)
          expect((values[0] + 0.05) / (values[1] + 0.05)).toBeGreaterThanOrEqual(4.5)
          expect(style.backgroundColor).toBe('rgb(35, 162, 205)')
          expect(style.outlineOffset).toBe('1px')
        }
        for (const id of ['other-provider', 'prefix-collision', 'mobile', 'outside-login', 'outside-layout']) {
          expect(getComputedStyle(document.getElementById(id)!).color).toBe('rgb(255, 255, 255)')
        }
      }
    }
    expect(document.querySelector('[data-test-id]')).toBeNull() // Production transform strips test IDs.
    const form = document.getElementById('sso-query')!.closest('form')!
    expect(form.getAttribute('method')).toBe('post')
    expect(form.querySelector('[name="authenticity_token"]')?.getAttribute('value')).toBe('synthetic')
    expect(css).not.toContain('forced-color-adjust: none')
    expect(css).toContain('color: ButtonText')
  })

})
