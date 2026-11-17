// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
import { fileURLToPath } from 'node:url'

import vue from '@vitejs/plugin-vue'
import { normalizePath } from 'vite'
import { defineConfig } from 'vitest/config'

const local = (relativePath: string) => normalizePath(fileURLToPath(new URL(relativePath, import.meta.url)))
const sidebar = local('../../zammad-package/app/frontend/apps/desktop/pages/ticket/components/TicketSidebar/TicketSidebarWasalx/TicketSidebarWasalx.vue')
const sidebarTypes = local('./stubs/sidebar-types.ts')

export default defineConfig({
  plugins: [
    {
      name: 'wasalx-zammad-external-type-fixture',
      enforce: 'pre',
      transform(source, id) {
        if (id !== sidebar) return
        // compiler-sfc resolves imported defineProps types before Vite aliases.
        // Only the Zammad-owned type module is substituted; component behavior
        // and markup are compiled directly from the package source file.
        return source.replace(
          "from '#desktop/pages/ticket/types/sidebar.ts'",
          `from '${sidebarTypes}'`,
        )
      },
    },
    vue(),
  ],
  resolve: {
    // Package source lives outside this workspace; use its real pinned rule dependency.
    dedupe: ['@formkit/rules'],
    alias: [
      { find: '#shared/i18n/index.ts', replacement: local('./stubs/i18n.ts') },
      {
        find: '#desktop/pages/ticket/components/TicketSidebar/TicketSidebarContent.vue',
        replacement: local('./stubs/TicketSidebarContent.vue'),
      },
      {
        find: '#desktop/pages/ticket/components/TicketSidebar/TicketSidebarWrapper.vue',
        replacement: local('./stubs/TicketSidebarWrapper.vue'),
      },
      {
        find: '#desktop/pages/ticket/types/sidebar.ts',
        replacement: local('./stubs/sidebar-types.ts'),
      },
      { find: '#desktop/components/layout/LayoutContent.vue', replacement: local('./stubs/LayoutContent.vue') },
      { find: '#desktop/components/CommonButton/CommonButton.vue', replacement: local('./stubs/CommonButton.vue') },
      { find: '#desktop/components/CommonLoader/CommonLoader.vue', replacement: local('./stubs/CommonLoader.vue') },
      { find: '#mobile/components/CommonLoader/CommonLoader.vue', replacement: local('./stubs/CommonLoader.vue') },
      { find: '#shared/components/WasalxTicketOperations/WasalxTicketOperations.vue', replacement: local('../../zammad-package/app/frontend/shared/components/WasalxTicketOperations/WasalxTicketOperations.vue') },
      { find: '#shared/components/WasalxTicketOperations/useWasalxTicketOperations.ts', replacement: local('../../zammad-package/app/frontend/shared/components/WasalxTicketOperations/useWasalxTicketOperations.ts') },
      { find: '#shared/entities/ticket-article/action/wasalxReplyPreview.ts', replacement: local('../../zammad-package/app/frontend/shared/entities/ticket-article/action/wasalxReplyPreview.ts') },
      { find: '#mobile/pages/ticket/composable/useTicketInformation.ts', replacement: local('./stubs/useTicketInformation.ts') },
      { find: '#shared/graphql/types.ts', replacement: local('./stubs/graphql-types.ts') },
      { find: '#shared/utils/files.ts', replacement: local('./stubs/files.ts') },
      { find: 'vue-router', replacement: local('./stubs/vue-router.ts') },
    ],
  },
  test: {
    environment: 'jsdom',
    globals: true,
    include: ['TicketSidebarWasalx.test.ts', 'WasalxGroups.test.ts', 'WasalxArticlePlugin.test.ts', 'NativeAccessibility.test.ts'],
    setupFiles: [local('./setup.ts')],
  },
})
