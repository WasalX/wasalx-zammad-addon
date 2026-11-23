# WasalX Zammad add-on agent instructions

## Project facts

- Repository [WasalX/wasalx-zammad-addon](https://github.com/WasalX/wasalx-zammad-addon). The main branch is `main`.
- Other repos: [WasalX/wasalx-platform](https://github.com/WasalX/wasalx-platform) (primary)
- The private [WasalX project board](https://github.com/orgs/WasalX/projects/1) holds the project brief.
- [Add-on milestones](https://github.com/WasalX/wasalx-zammad-addon/milestones) are v0.1.0 due 2026-11-30 and v0.2.0 due 2026-12-14. Each ships with its matching platform tag.
- Lead threads are WasalX Master, WasalX Delivery, and WasalX Design.
- UI project: yes. The sidebar and package UI follow the [WasalX design tokens](https://github.com/WasalX/wasalx-platform/blob/main/app/design-system/tokens.css).
- The owner decides only money (any paid service), access only the owner can grant, production deployments, destructive operations on real data, making private things public, and closing a project. Project leads decide everything else within their scopes.
- Follow the [platform agent instructions](https://github.com/WasalX/wasalx-platform/blob/main/AGENTS.md) and [platform delivery rules](https://github.com/WasalX/wasalx-platform/blob/main/DELIVERY.md) for shared rules.

## Build and checks

- Use the Node.js version set in [CI](.github/workflows/ci.yml) and the pnpm version pinned in [package.json](package.json). Run `corepack enable` and `pnpm install --frozen-lockfile`.
- Run `pnpm run zammad:package` to build the [package definition](zammad-package/package-source.json) and its sources into a `.zpm` and manifest under [build/zammad](build/zammad/). Older source snapshots are organized by package version under [historical-source](historical-source/).
- The add-on release is the package build pinned by the platform in [zammad-addon.json](https://github.com/WasalX/wasalx-platform/blob/main/zammad-addon.json).
- Run `pnpm run test:package` for package tests and `pnpm run test:components` for sidebar component tests. CI supplies Ruby and the pinned platform contract files.
- CI runs the package build, checks committed artifacts with `git diff --exit-code -- build/zammad`, and runs the package tests, standalone Ruby contracts, sidebar component tests, and sidebar TypeScript typecheck.
