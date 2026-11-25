import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repository = fileURLToPath(new URL("../", import.meta.url));
const read = (file: string) => readFileSync(join(repository, file), "utf8");
const git = (cwd: string, ...args: string[]) =>
  execFileSync("git", args, { cwd, encoding: "utf8", windowsHide: true });
const tracked = (cwd: string, ...patterns: string[]) =>
  git(cwd, "ls-files", "-z", "--", ...patterns.map(pattern => `:(glob)${pattern}`)).split("\0").filter(Boolean);
const trackedTests = (cwd: string) => tracked(cwd, "**/*.test.*", "**/*.spec.*",
  "tests/**/*.rb", "**/*-test.rb", "**/*_test.rb", "**/test_*.rb", "**/*_spec.rb", "**/*-contract.rb", "**/*-native.rb");
const quoted = (source: string) =>
  Array.from(source.matchAll(/["']([^"']+)["']/gu), ([, file]) => file);

const platformNativeTests = new Map([
  "tests/portal-service-identity-native.rb",
  "tests/portal-service-identity-race-native.rb",
  "tests/portal-service-initialize-native.rb",
].map(file => [file, "run by the WasalX platform's image compatibility test against the built Zammad image"]));

function ciOwnedTests() {
  const workflows = tracked(repository, ".github/workflows/*.yml", ".github/workflows/*.yaml");
  const workflowRuns: string[] = JSON.parse(execFileSync("ruby", ["-rjson", "-ryaml", "-e",
    "puts JSON.generate(ARGV.flat_map { |file| YAML.safe_load_file(file, aliases: true).fetch('jobs').values.flat_map { |job| job.fetch('steps', []).filter_map { |step| step['run'] } } })",
    ...workflows,
  ], { cwd: repository, encoding: "utf8", windowsHide: true }));
  const ciCommands = workflowRuns.flatMap(run => run.split(/\r?\n/u).map(line => line.trim()));
  const { scripts } = JSON.parse(read("package.json"));
  const commands = [...ciCommands, ...ciCommands.flatMap(command => {
    const script = /^pnpm (?:run )?([\w:-]+)(?:\s|$)/u.exec(command)?.[1];
    return script && Object.hasOwn(scripts, script) ? [scripts[script] as string] : [];
  })];

  const owned = new Set<string>();
  for (const command of commands) {
    const [runner, ...args] = command.split(/\s+/u);
    if (runner === "ruby" && args[0]) owned.add(args[0]);
    const testFlag = args.indexOf("--test");
    if (runner === "node" && testFlag !== -1) {
      for (const file of args.slice(testFlag + 1)) owned.add(file);
    }
  }

  const packageTest = "tests/zammad-package.test.ts";
  if (owned.has(packageTest)) {
    const source = read(packageTest);
    // Follow the package suite's direct and grouped Ruby subprocess calls.
    for (const [, file] of source.matchAll(/^[ \t]*const result = spawnSync\("ruby", \[path\.join\(workspace, "(tests\/[^"]+\.rb)"\)\]/gmu)) {
      owned.add(file);
    }
    for (const [, files] of source.matchAll(/^for \(const file of \[([^\]]+)\]\) \{\s+test\([^\n]+\n\s+const result = spawnSync\("ruby", \[path\.join\(workspace, "tests", file\)\]/gmu)) {
      for (const file of quoted(files)) owned.add("tests/" + file);
    }
  }

  const componentDir = "tests/zammad-sidebar-component";
  const component = JSON.parse(read(componentDir + "/package.json"));
  if (commands.includes("pnpm --filter " + component.name + " test")
    && component.scripts.test === "vitest run --config vitest.config.ts") {
    const include = /^\s*include: \[([^\]]+)\]/mu.exec(read(componentDir + "/vitest.config.ts"))?.[1] ?? "";
    for (const file of quoted(include)) owned.add(componentDir + "/" + file);
  }
  return owned;
}

function assertOwned(tests: string[], owned: Set<string>) {
  const missing = tests.filter(file => !owned.has(file) && !platformNativeTests.has(file));
  assert.deepEqual(missing, [], "Tests missing a CI runner or allowlist entry: " + missing.join(", "));
}

test("tracked test files have a CI runner or a platform allowlist entry", () => {
  const files = trackedTests(repository);
  const owned = ciOwnedTests();
  assertOwned(files, owned);
  for (const [file, reason] of platformNativeTests) {
    assert.ok(reason && files.includes(file) && !owned.has(file), "Stale test allowlist entry: " + file);
  }
});

test("test ownership rejects a new tracked file with no runner", t => {
  const directory = mkdtempSync(join(tmpdir(), "zammad-test-ownership-"));
  t.after(() => rmSync(directory, { recursive: true }));
  const file = "unreferenced-guard-fixture.test.ts";
  writeFileSync(join(directory, file), "");
  git(directory, "init", "--quiet");
  git(directory, "add", "--", file);
  assert.throws(() => assertOwned(trackedTests(directory), ciOwnedTests()),
    /Tests missing a CI runner or allowlist entry: unreferenced-guard-fixture\.test\.ts/u);
});

test("copyright guard rejects an unapproved source header", t => {
  const directory = mkdtempSync(join(tmpdir(), "zammad-copyright-"));
  t.after(() => rmSync(directory, { recursive: true }));
  const guard = join(repository, "scripts/check-copyright-headers.mjs");
  const file = "copyright-fixture.mjs";
  git(directory, "init", "--quiet");
  writeFileSync(join(directory, file), "// Copyright (c) 2026 WasalX\n");
  git(directory, "add", "--", file);
  const options = { cwd: directory, encoding: "utf8" as const, windowsHide: true, stdio: "pipe" as const };
  assert.equal(execFileSync(process.execPath, [guard], options), "");

  writeFileSync(join(directory, file), "/* Copyright (c) 2026 Unapproved Fixture Holder */\n");
  assert.throws(() => execFileSync(process.execPath, [guard], options), {
    status: 1,
    stderr: file + ":1: unapproved copyright header\n",
  });
});
