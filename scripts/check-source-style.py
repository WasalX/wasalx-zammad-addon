# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 WasalX

import os
import re
import shutil
import subprocess
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from tempfile import TemporaryDirectory


HOOKS = ("prettier", "oxlint", "stylelint", "ruff-check", "ruff-format", "rubocop")


def run_hooks(*args):
    version = os.environ["PRE_COMMIT_VERSION"]
    return subprocess.run(
        [
            "pipx",
            "run",
            "--spec",
            f"pre-commit=={version}",
            "pre-commit",
            "run",
            "--color",
            "never",
            *args,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )


def prove_fixtures():
    fixtures = Path("tests/fixtures/source-style")
    cases = (("good", 0, "Passed"), ("bad", 1, "Failed"))
    # Use the unchanged hook config against copies outside its fixture exclusion.
    with TemporaryDirectory(prefix=".source-style-proof-", dir=".") as directory:
        for hook in HOOKS:
            for case, exit_code, verdict in cases:
                (source,) = (fixtures / hook).glob(f"{case}.*.fixture")
                path = shutil.copy(source, Path(directory) / source.stem)
                result = run_hooks(hook, "--files", path)
                print(f"{hook} {case} fixture (exit {result.returncode}):", flush=True)
                print(result.stdout, end="", flush=True)
                if result.returncode != exit_code or not any(
                    line.endswith(f".{verdict}") for line in result.stdout.splitlines()
                ):
                    raise SystemExit(
                        f"{hook} {case}: expected {verdict} with exit {exit_code}"
                    )


def flagged_hooks(path):
    result = run_hooks("--files", path)
    if result.returncode == 0:
        return []
    hooks = re.findall(r"^- hook id: (\S+)$", result.stdout, re.MULTILINE)
    if result.returncode != 1 or not hooks or not set(hooks).issubset(HOOKS):
        raise RuntimeError(f"Could not count source hook findings for {path}")
    return hooks


def report_existing():
    exclude = re.compile(
        subprocess.check_output(
            [
                "ruby",
                "-ryaml",
                "-e",
                "print YAML.safe_load_file('.pre-commit-config.yaml').fetch('exclude')",
            ],
            text=True,
        )
    )
    tracked = subprocess.check_output(["git", "ls-files", "-z"]).split(b"\0")
    paths = (os.fsdecode(path) for path in tracked if path)
    eligible = (path for path in paths if not exclude.search(path))
    counts = Counter()
    with ThreadPoolExecutor(max_workers=4) as workers:
        for hooks in workers.map(flagged_hooks, eligible):
            counts.update(hooks)
    for hook in HOOKS:
        print(f"{hook}: {counts[hook]} existing files flagged")


if __name__ == "__main__":
    {"fixtures": prove_fixtures, "report": report_existing}[sys.argv[1]]()
