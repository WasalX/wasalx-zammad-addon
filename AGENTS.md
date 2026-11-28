# WasalX Zammad add-on agent instructions

## Project facts

- Repository [WasalX/wasalx-zammad-addon](https://github.com/WasalX/wasalx-zammad-addon). The main branch is `main`.
- Other repos: [WasalX/wasalx-platform](https://github.com/WasalX/wasalx-platform) (primary)
- The private [WasalX project board](https://github.com/orgs/WasalX/projects/1) holds the project brief.
- [Add-on milestones](https://github.com/WasalX/wasalx-zammad-addon/milestones) are v0.1.0 (current) and v0.2.0 (next). See that page for dates and scope. Each ships with its matching platform tag.
- Lead threads are WasalX Master, WasalX Delivery, WasalX QA, and WasalX Design.
- UI project: yes. The sidebar and package UI follow the [WasalX design tokens](https://github.com/WasalX/wasalx-platform/blob/main/app/design-system/tokens.css).
- The owner decides only money (any paid service), access only the owner can grant, production deployments, destructive operations on real data, making private things public, and closing a project. Project leads decide everything else within their scopes.
- Follow the [platform agent instructions](https://github.com/WasalX/wasalx-platform/blob/main/AGENTS.md) and [platform delivery rules](https://github.com/WasalX/wasalx-platform/blob/main/DELIVERY.md) for shared rules.
- Follow the [security policy](SECURITY.md) to report vulnerabilities privately.

## Risk paths

Only these need the independent [risk-path review](https://github.com/WasalX/wasalx-platform/blob/main/DELIVERY.md#branching-and-merging) because mistakes can be irreversible, silent, or public.

- **Migrations, deletion, and retention** include `zammad-package/db/addon/wasalx/` and privacy, upload cleanup, and expiry code.
- **Sign-in, authorization, tenant isolation, and secrets** include session, membership, service identity, delegation, and credential handling, plus routes, API controllers, and UI that change who can see personal data.
- **Outbound safety** includes message and mail routing, delivery, and TLS safeguards in `zammad-package/`.
- **Merge gates** include `.github/workflows/`, `.pre-commit-config.yaml`, `.rubocop.yml`, `scripts/check-source-style.py`, `tests/fixtures/source-style/`, the `prettier` and `stylelint` configuration blocks, and the `scripts` block of any `package.json`. This includes any Prettier, Oxlint, Ruff, Stylelint, or RuboCop config or ignore file.
- **Production configuration and deploys** include `infra/docker/full/zammad/`, `scripts/build-zammad-package.mjs`, and `zammad-package/package-source.json`.

Docs, design, UI that does not change data exposure, tests, dependency bumps, lock files, and refactors outside these areas need no independent review.

## Build and checks

- Use the Node.js version set in [CI](.github/workflows/ci.yml) and the pnpm version pinned in [package.json](package.json). Run `corepack enable` and `pnpm install --frozen-lockfile`.
- Run `pnpm run zammad:package` to build the [package definition](zammad-package/package-source.json) and its sources into a `.zpm` and manifest under [build/zammad](build/zammad/). Older source snapshots are organized by package version under [historical-source](historical-source/).
- The add-on release is the package build pinned by the platform in [zammad-addon.json](https://github.com/WasalX/wasalx-platform/blob/main/zammad-addon.json).
- Run `pnpm run test:package` for package tests and `pnpm run test:components` for sidebar component tests. CI supplies Ruby and the pinned platform contract files.
- Run `pnpm run format <paths>` to format JavaScript, TypeScript, Vue, or CSS. Run `pre-commit run --files <paths>` for the [source checks](DELIVERY.md#source-checks), including Ruby lint and layout.
- CI lints its workflows with a checksum-verified [actionlint release](https://github.com/rhysd/actionlint/releases).
- The current package and manifest are generated during CI. CI rejects changes to tracked artifacts and unexpected untracked files under `build/zammad`, then runs the package tests, standalone Ruby contracts, sidebar component tests, and sidebar TypeScript typecheck.
