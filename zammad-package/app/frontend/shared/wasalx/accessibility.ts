// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX
import { i18n } from '#shared/i18n/index.ts'

import './accessibility.css'

// Native shell components have no package extension points for these semantics.
export function installNativeAccessibility(root = document, translate = (text: string) => i18n.t(text)) {
  const names = new WeakMap<Element, string>()
  const selector = 'button, a[href="/mobile/notifications"], [role="textbox"][contenteditable][name="body"], label[for], header.ticket-detail-grid-compact'

  const repair = (element: Element) => {
    if (element.matches('header.ticket-detail-grid-compact')) {
      element.toggleAttribute('inert', element.getAttribute('aria-hidden') === 'true')
      return
    }

    if (element.matches('label[for]')) {
      const editor = root.getElementById(element.getAttribute('for') || '')
      if (editor?.matches('[role="textbox"][contenteditable][name="body"]')) repair(editor)
      return
    }

    if (element.matches('[role="textbox"][contenteditable][name="body"]')) {
      if (element.getAttribute('aria-label')?.trim() || element.getAttribute('aria-labelledby')?.trim() || !element.id) return
      const label = Array.from(root.querySelectorAll('label[for]')).find(label => label.getAttribute('for') === element.id)
      if (!label) return
      label.id ||= `${element.id}-wasalx-label`
      element.setAttribute('aria-labelledby', label.id)
      return
    }

    const source = element.matches('footer a[href="/mobile/notifications"]')
      ? 'Notifications'
      : element.matches('nav button')
        ? element.querySelector('svg.icon-all-tickets') ? 'Overviews'
          : element.querySelector('svg.icon-whatsapp') ? 'WhatsApp Groups' : undefined
        : undefined
    if (!source || element.getAttribute('aria-labelledby')?.trim()) return
    const previous = names.get(element)
    const existing = element.getAttribute('aria-label')?.trim()
    if ((existing && existing !== previous) || (!previous && element.textContent?.trim())) return
    const name = translate(source)
    if (existing !== name) element.setAttribute('aria-label', name)
    names.set(element, name)
  }

  const scan = (scope: Element | Document) => {
    if (scope instanceof Element) {
      const owner = scope.closest(selector)
      if (owner) repair(owner)
    }
    scope.querySelectorAll(selector).forEach(repair)
  }

  scan(root)
  const observer = new MutationObserver(records => {
    for (const record of records) {
      if (record.type === 'attributes' && record.attributeName === 'lang') {
        scan(root)
      } else if (record.type === 'attributes') {
        scan(record.target as Element)
      } else {
        // Scan only the changed subtree; typing never rescans the whole ticket.
        for (const node of Array.from(record.addedNodes)) {
          if (node instanceof Element) scan(node)
        }
      }
    }
  })
  observer.observe(root.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ['aria-hidden', 'class', 'for', 'id', 'lang'],
  })
  return () => observer.disconnect()
}
