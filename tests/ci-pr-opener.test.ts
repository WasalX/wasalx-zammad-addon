import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

test('required CI enforces the PR opener rule with redacted output', (t) => {
  const step = JSON.parse(
    execFileSync(
      'ruby',
      [
        '-rjson',
        '-ryaml',
        '-e',
        `jobs = YAML.safe_load_file('.github/workflows/ci.yml', aliases: true).fetch('jobs')
         abort unless jobs.fetch('ci-gate').fetch('needs').include?('checks')
         puts JSON.generate(jobs.fetch('checks').fetch('steps').find { |step| step['name'] == 'Require an allowed pull request opener' })`,
      ],
      { cwd: new URL('../', import.meta.url), encoding: 'utf8' },
    ),
  )
  assert.ok(step)
  assert.equal(step.if, "github.event_name == 'pull_request'")
  const defaultList = 'tree-publisher[bot],dependabot[bot]'
  assert.deepEqual(step.env, {
    PR_OPENER_ALLOWLIST: "${{ vars.PR_OPENER_ALLOWLIST || '" + defaultList + "' }}",
  })

  const directory = mkdtempSync(join(tmpdir(), 'pr-opener-event-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const eventPath = join(directory, 'event.json')
  for (const [login, status] of [
    ['tree-publisher[bot]', 0],
    ['dependabot[bot]', 0],
    ['fixture-user', 1],
    [undefined, 1],
  ]) {
    writeFileSync(eventPath, JSON.stringify({ pull_request: { user: { login } } }))
    const result = spawnSync('bash', ['-e', '-o', 'pipefail', '-c', step.run], {
      env: { ...process.env, GITHUB_EVENT_PATH: eventPath, PR_OPENER_ALLOWLIST: defaultList },
      encoding: 'utf8',
    })
    assert.ifError(result.error)
    assert.equal(result.status, status)
    assert.equal(result.stdout.trim(), status ? '::error::PR opener allowlist rule failed.' : '')
    assert.equal(result.stderr, '')
  }
})
