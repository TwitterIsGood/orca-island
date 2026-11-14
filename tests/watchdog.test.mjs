import test from 'node:test'
import assert from 'node:assert/strict'
import { createWatchdog } from '../main.mjs'
import { createCompanionManager } from '../lib/companion-manager.mjs'

function harness(statuses, options = {}) {
  let clock = 0
  const updates = []
  const restarts = []
  const queue = [...statuses]
  const watchdog = createWatchdog({
    update: (patch) => updates.push(patch),
    restart: (reason) => restarts.push(reason),
    fetchStatus: async () => (queue.length > 1 ? queue.shift() : queue[0]),
    now: () => clock,
    setIntervalImpl: () => null,
    clearIntervalImpl: () => {},
    ...options
  })
  return { watchdog, updates, restarts, advance: (ms) => { clock += ms } }
}

test('healthy companion shows session count and never restarts', async () => {
  const h = harness([{ sessionCount: 4, syncUnavailable: false }])
  await h.watchdog.check()
  await h.watchdog.check()
  assert.deepEqual(h.restarts, [])
  assert.equal(h.updates.length, 1, 'identical patches are not re-sent')
  assert.equal(h.updates[0].text, 'Island 4')
})

test('offline twice in a row relaunches, rate-limited by the cooldown', async () => {
  const h = harness([null])
  await h.watchdog.check()
  assert.deepEqual(h.restarts, [])
  assert.equal(h.updates.at(-1).tone, 'danger')
  await h.watchdog.check()
  assert.deepEqual(h.restarts, ['offline'])
  h.advance(30_000)
  await h.watchdog.check()
  assert.deepEqual(h.restarts, ['offline'])
  h.advance(31_000)
  await h.watchdog.check()
  assert.deepEqual(h.restarts, ['offline', 'offline'])
})

test('sync stuck unavailable restarts only after the grace period, with its reason shown', async () => {
  const h = harness([{ sessionCount: 0, syncUnavailable: true, syncFailure: 'orca_api_incompatible',
    syncFailureDescription: 'Orca 已更新，接口不兼容，请更新 Orca Island' }])
  await h.watchdog.check()
  assert.equal(h.updates.at(-1).text, 'Island 断连')
  assert.match(h.updates.at(-1).tooltip, /接口不兼容/)
  h.advance(2 * 60_000)
  await h.watchdog.check()
  assert.deepEqual(h.restarts, [])
  h.advance(60_000)
  await h.watchdog.check()
  assert.deepEqual(h.restarts, ['sync stuck'])
  h.advance(5 * 60_000)
  await h.watchdog.check()
  assert.deepEqual(h.restarts, ['sync stuck'], 'an unfixable break must not cause a restart loop')
})

test('a partially unreachable remote fleet is reported but never restarts the companion', async () => {
  const h = harness([{ sessionCount: 3, syncUnavailable: true, syncFailure: 'remote_unreachable' }])
  await h.watchdog.check()
  h.advance(60 * 60_000)
  await h.watchdog.check()
  assert.deepEqual(h.restarts, [])
  assert.equal(h.updates.at(-1).tone, 'warning')
})

test('does nothing while a restart or install is in progress', async () => {
  const h = harness([null], { isBusy: () => true })
  await h.watchdog.check()
  await h.watchdog.check()
  assert.deepEqual(h.restarts, [])
  assert.deepEqual(h.updates, [])
})

test('manager restart quits the running companion, then relaunches it', async () => {
  const calls = []
  const manager = createCompanionManager({
    platform: 'darwin',
    adapter: {
      async isHealthy() { return false },
      async acquireLock() { return async () => {} },
      async hasAttempted() { return true },
      async recordAttempt() {},
      async clearAttempt() {},
      async findInstalled() { return '/tmp/OrcaIsland.app' },
      async install() { throw new Error('must not install') },
      async quit() { calls.push('quit'); return true },
      async launch() { calls.push('launch') },
      async waitForHealth() { return true }
    }
  })
  const result = await manager.restart()
  assert.equal(result.status, 'running')
  assert.deepEqual(calls, ['quit', 'launch'], 'restart ignores the failed-attempt marker')
})
