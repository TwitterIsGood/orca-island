import test from 'node:test'
import assert from 'node:assert/strict'
import { createCompanionManager, expectedChecksum, validateArchiveEntries } from '../lib/companion-manager.mjs'

test('requires the pinned release checksum', () => {
  const digest = 'a'.repeat(64)
  assert.equal(expectedChecksum(`${digest}  OrcaIsland-macos-universal.zip\n`), digest)
  assert.throws(() => expectedChecksum(`${digest}  other.zip\n`), /exactly one checksum/)
})

test('rejects archive traversal and missing app metadata', () => {
  assert.throws(() => validateArchiveEntries('OrcaIsland.app/Contents/Info.plist\n../escape', ''), /Unexpected archive path/)
  assert.throws(() => validateArchiveEntries('OrcaIsland.app/Contents/README', ''), /Info.plist/)
})

function fakeAdapter(overrides = {}) {
  const calls = []
  return {
    calls,
    async isHealthy() { return false },
    async acquireLock() { calls.push('lock'); return async () => calls.push('unlock') },
    async hasAttempted() { return false },
    async recordAttempt() { calls.push('attempt') },
    async clearAttempt() { calls.push('clear') },
    async findInstalled() { calls.push('find'); return '/tmp/OrcaIsland.app' },
    async install() { calls.push('install'); return '/tmp/OrcaIsland.app' },
    async launch(app) { calls.push(`launch:${app}`) },
    async waitForHealth() { calls.push('wait'); return true },
    ...overrides
  }
}

test('automatic activation launches an installed companion without blocking', async () => {
  const adapter = fakeAdapter()
  const manager = createCompanionManager({ platform: 'darwin', adapter })
  const result = await manager.ensure()
  assert.equal(result.status, 'running')
  assert.deepEqual(adapter.calls, ['lock', 'find', 'launch:/tmp/OrcaIsland.app', 'wait', 'clear', 'unlock'])
})

test('installs when no companion is present and reports a release failure once', async () => {
  const calls = []
  let installCalls = 0
  const adapter = fakeAdapter({
    async findInstalled() { calls.push('find'); return null },
    async install() { installCalls += 1; calls.push('install'); throw new Error('release unavailable') }
  })
  const manager = createCompanionManager({ platform: 'darwin', adapter })
  assert.equal((await manager.ensure()).status, 'failed')
  assert.equal((await manager.ensure()).status, 'skipped')
  assert.equal((await manager.ensure({ retry: true })).status, 'failed')
  assert.equal(installCalls, 2)
  assert.deepEqual(calls.filter((call) => call === 'install'), ['install', 'install'])
})

test('automatic failure is not retried until the explicit command', async () => {
  let findCalls = 0
  const adapter = fakeAdapter({
    async findInstalled() { findCalls += 1; throw new Error('release unavailable') }
  })
  const manager = createCompanionManager({ platform: 'darwin', adapter })
  assert.equal((await manager.ensure()).status, 'failed')
  assert.equal((await manager.ensure()).status, 'skipped')
  assert.equal((await manager.ensure({ retry: true })).status, 'failed')
  assert.equal(findCalls, 2)
})

test('non-macOS activation is a clear no-op', async () => {
  const adapter = fakeAdapter()
  const manager = createCompanionManager({ platform: 'linux', adapter })
  const result = await manager.ensure()
  assert.equal(result.status, 'unsupported')
  assert.deepEqual(adapter.calls, [])
})

