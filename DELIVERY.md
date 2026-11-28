# WasalX Zammad add-on delivery

Follows engineering standard v1.20.

Follow the [shared WasalX merge rules](https://github.com/WasalX/wasalx-platform/blob/main/DELIVERY.md#branching-and-merging) for add-on pull requests.

## Source checks

The `checks` job runs the [source hooks](.pre-commit-config.yaml) for added and modified source files. Prettier checks JavaScript, TypeScript, Vue, and CSS. Oxlint lints JavaScript, TypeScript, and Vue. Stylelint lints standalone CSS and Vue style blocks. Ruff formats and lints Python with the same pinned hooks and default rules as the platform. RuboCop checks the Ruby Layout, Lint, and Security departments. The source hooks exclude historical snapshots, package artifacts, the upstream Zammad fixtures listed in [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES), and the source-style proof fixtures. CI proves each hook accepts a good fixture and rejects a bad one. The advisory `source-style-report` job reports how many existing files each hook flags on PRs. The required `ci-gate` depends on the checks and dependency review jobs.

Run `pre-commit run --files <paths>` to check selected files locally. Use `ruff format <paths>` to format Python. Use `pre-commit run ruby-format --hook-stage manual --files <paths>` to format Ruby. If package sources change, rebuild the package using the [build commands](AGENTS.md#build-and-checks).

The PR run requires an allowed opener in the `checks` job. The repository Actions variable `PR_OPENER_ALLOWLIST` accepts comma- or whitespace-separated logins and defaults to the publishing App and `dependabot[bot]`. The merge-queue run skips the opener check because the PR run covers it.

## CI caching and concurrency

The [CI workflow](.github/workflows/ci.yml) restores the pnpm store before installing PR dependencies. A main push saves the store when the exact key is missing. A newer run cancels an older run for the same PR. Main and merge-queue runs have independent concurrency groups.

The [job timing sample](.github/ci-timings.json) uses successful first-attempt PR, main-push, and merge-queue runs on the current CI layout. Each job uses the highest p95 of its applicable events.

## Deviations

| Rule | Reason | Review date |
|---|---|---|
| Engineering standard §4 PR feedback p95 | Run creation to gate result was 259 s at p95 across 77 first-attempt PR runs and 614 s on the current layout (17 runs). In the slowest run, `checks` and `ci-gate` waited 256 s and 287 s for hosted runners. Both dependency caches hit. [Slowest run](https://github.com/WasalX/wasalx-zammad-addon/actions/runs/45861568621) | 2026-12-08 |
| Engineering standard §4 PR time to mergeable | The 25 November 2026 sample measures job phases. It has incomplete PR trigger coverage, lacks CodeQL completion timestamps, and cannot verify historical ruleset applicability. [Measurement and coverage](https://github.com/WasalX/wasalx-zammad-addon/issues/18#issuecomment-7154796227) | 2026-12-08 |
