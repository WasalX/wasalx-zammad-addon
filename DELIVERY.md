# WasalX Zammad add-on delivery

Follows engineering standard v1.20.

Follow the [shared WasalX merge rules](https://github.com/WasalX/wasalx-platform/blob/main/DELIVERY.md#branching-and-merging) for add-on pull requests.

## Source checks

The `checks` job verifies the pinned actionlint archive when workflows or local actions change. It reports base, head, and new findings counts and fails on new findings.

The `checks` job runs the [source hooks](.pre-commit-config.yaml) for added and modified source files. Prettier checks JavaScript, TypeScript, Vue, and CSS. Oxlint lints JavaScript, TypeScript, and Vue. Stylelint lints standalone CSS and Vue style blocks. RuboCop checks Ruby layout and lint rules. The source hooks exclude the historical snapshots and committed package artifacts.

Run `pre-commit run --files <paths>` to check selected files locally. Use `pre-commit run ruby-format --hook-stage manual --files <paths>` to format Ruby. If package sources change, rebuild the package using the [build commands](AGENTS.md#build-and-checks).
