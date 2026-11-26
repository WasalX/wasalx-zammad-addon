# WasalX Zammad add-on delivery

Follows engineering standard v1.20.

Follow the [shared WasalX merge rules](https://github.com/WasalX/wasalx-platform/blob/main/DELIVERY.md#branching-and-merging) for add-on pull requests.

## Source checks

The `checks` job runs the [source hooks](.pre-commit-config.yaml) for added and modified source files. Prettier checks JavaScript, TypeScript, Vue, and CSS. Oxlint lints JavaScript, TypeScript, and Vue. Stylelint lints standalone CSS and Vue style blocks. RuboCop checks the Ruby Layout, Lint, and Security departments. The source hooks exclude historical snapshots, package artifacts, the upstream Zammad fixtures listed in [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES), and the source-style proof fixtures. CI proves each hook accepts a good fixture and rejects a bad one. PR CI also reports how many existing files each hook flags, as an advisory count.

Run `pre-commit run --files <paths>` to check selected files locally. Use `pre-commit run ruby-format --hook-stage manual --files <paths>` to format Ruby. If package sources change, rebuild the package using the [build commands](AGENTS.md#build-and-checks).

## Deviations

| Rule | Reason | Review date |
|---|---|---|
| Engineering standard §4 PR time to mergeable | The 25 November 2026 sample measures job phases. It has incomplete PR trigger coverage, lacks CodeQL completion timestamps, and cannot verify historical ruleset applicability. [Measurement and coverage](https://github.com/WasalX/wasalx-zammad-addon/issues/18#issuecomment-7154796227) | 2026-12-08 |
