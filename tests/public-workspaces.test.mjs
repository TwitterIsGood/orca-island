import test from 'node:test'
import assert from 'node:assert/strict'
import activate, { createRelay } from '../main.mjs'
import { createPublicWorkspaces } from '../lib/public-workspaces.mjs'

function harness(rows = [], { minor = 10, has = true, timeoutMs = 100 } = {}) {
  const calls = []
  const logs = []
  let response = { workspaces: rows, truncated: false }
  const orca = {
    api: { major: 1, minor },
    host: {
      has: () => has,
      async call(method, params) {
        calls.push({ method, params })
        if (response instanceof Error) throw response
        return typeof response === 'function' ? response() : response
      }
    }
  }
  const workspaces = createPublicWorkspaces({ orca, log: (line) => logs.push(line), timeoutMs })
  return { orca, workspaces, calls, logs, reply: (value) => { response = value } }
}
const row = (id, hostId, name = 'Workspace') => ({ id, hostId, name })
const event = (workspaceListId, other = {}) => ({
  workspaceId: 'same-raw-workspace', workspaceListId, paneKey: 'same-tab:same-leaf',
  state: 'working', receivedAt: 100, ...other
})

test('public catalog joins opaque workspace list ids to an explicitly reported host', async () => {
  const h = harness([row('identity:opaque', 'runtime:remote', 'Remote work')])
  await h.workspaces.refresh()
  assert.deepEqual(h.calls, [{ method: 'workspace.list', params: { includeStatus: true } }])
  assert.deepEqual(h.workspaces.enrich(event('identity:opaque')), {
    ...event('identity:opaque'), hostId: 'runtime:remote', environmentId: 'remote',
    environmentName: null, workspaceLabel: 'Remote work'
  })
  assert.equal(h.workspaces.enrich(event('identity:runtime:remote')).hostId, null,
    'Never decode private identities or infer the host from a workspace id')
})

test('old events without workspaceListId route only when the raw id exactly matches a public id', async () => {
  const h = harness([row('folder:exact', 'local'), row('identity:opaque', 'runtime:remote')])
  await h.workspaces.refresh()
  assert.equal(h.workspaces.enrich({ workspaceId: 'folder:exact' }).hostId, 'local')
  assert.equal(h.workspaces.enrich(event(undefined)).hostId, null)
  assert.equal(h.workspaces.enrich(event('unknown', { workspaceId: 'folder:exact' })).hostId, null,
    'An unknown qualified id must not fall back to a different raw-id route')
})

test('missing or ambiguous catalog hosts never turn an event into local traffic', async () => {
  const h = harness([row('one', null), row('two', undefined), row('duplicate', 'local'),
    row('duplicate', 'runtime:remote')])
  await h.workspaces.refresh()
  for (const id of ['one', 'two', 'duplicate', 'unknown']) {
    const routed = h.workspaces.enrich(event(id, { hostId: 'local', environmentId: 'forged' }))
    assert.equal(routed.hostId, null)
    assert.equal(routed.environmentId, null)
  }
})

test('public API version guards avoid sending includeStatus to old hosts', async () => {
  const old = harness([row('one', 'local')], { minor: 3 })
  await old.workspaces.refresh()
  assert.deepEqual(old.calls[0].params, {})
  const absent = harness([], { has: false })
  assert.equal(await absent.workspaces.refresh(), false)
  assert.deepEqual(absent.calls, [])
  const noHas = harness([row('one', 'local')], { minor: 7 })
  delete noHas.orca.host.has
  await noHas.workspaces.refresh()
  assert.deepEqual(noHas.calls[0].params, { includeStatus: true })
  const noApi = harness([row('one', 'local')])
  delete noApi.orca.api
  await noApi.workspaces.refresh()
  assert.deepEqual(noApi.calls[0].params, {})
})

test('catalog failures preserve the last confirmed routes without escaping into event handlers', async () => {
  const h = harness([row('one', 'local')])
  await h.workspaces.refresh()
  h.reply(new Error('public host unavailable'))
  assert.equal(await h.workspaces.refresh(), false)
  assert.equal(h.workspaces.enrich(event('one')).hostId, 'local')
  h.reply({ workspaces: null, truncated: false })
  assert.equal(await h.workspaces.refresh(), false)
  assert.equal(h.workspaces.enrich(event('one')).hostId, 'local')
  assert.equal(h.logs.length, 2)
})

test('truncated catalog preserves omitted routes; complete catalog removes absent routes', async () => {
  const h = harness([row('one', 'local')])
  await h.workspaces.refresh()
  h.reply({ workspaces: [row('two', 'runtime:remote')], truncated: true })
  await h.workspaces.refresh()
  assert.equal(h.workspaces.enrich(event('one')).hostId, 'local')
  assert.equal(h.workspaces.enrich(event('two')).hostId, 'runtime:remote')
  h.reply({ workspaces: [row('two', 'runtime:remote')], truncated: false })
  await h.workspaces.refresh()
  assert.equal(h.workspaces.enrich(event('one')).hostId, null)
})

test('concurrent reads are single-flight and lifecycle invalidations coalesce one trailing read', async () => {
  let resolve
  const pending = new Promise((done) => { resolve = done })
  const h = harness()
  h.reply(() => pending)
  const first = h.workspaces.refresh()
  assert.equal(h.workspaces.refresh(), first)
  h.workspaces.refresh({ afterPending: true })
  h.workspaces.refresh({ afterPending: true })
  await Promise.resolve()
  assert.equal(h.calls.length, 1)
  h.reply({ workspaces: [row('one', 'local')], truncated: false })
  resolve({ workspaces: [], truncated: false })
  await h.workspaces.idle()
  assert.equal(h.calls.length, 2)
  assert.equal(h.workspaces.enrich(event('one')).hostId, 'local')
})

test('a stuck public host call is bounded and cannot later replace the retained catalog', async () => {
  const h = harness([row('one', 'local')], { timeoutMs: 5 })
  await h.workspaces.refresh()
  let resolve
  h.reply(() => new Promise((done) => { resolve = done }))
  assert.equal(await h.workspaces.refresh(), false)
  resolve({ workspaces: [], truncated: false })
  await Promise.resolve()
  assert.equal(h.workspaces.enrich(event('one')).hostId, 'local')
  assert.match(h.logs[0], /timed out/)
})

test('relay deduplication isolates identical raw workspace and pane ids across execution hosts', async () => {
  const sent = []
  const relay = createRelay({ post: async (payload) => sent.push(payload) })
  const local = event('identity:local', { hostId: 'local' })
  const remote = event('identity:remote', { hostId: 'runtime:remote', environmentId: 'remote' })
  assert.equal(relay.handle(local), 'queued')
  assert.equal(relay.handle(remote), 'queued')
  await relay.idle()
  assert.equal(sent.length, 2)
  assert.deepEqual(sent.map(({ hostId }) => hostId), ['local', 'runtime:remote'])
  assert.equal(relay.handle(local), 'duplicate')
  assert.equal(relay.handle(remote), 'duplicate')
})

test('hostless events still retain distinct public identities and state-start evidence', async () => {
  const sent = []
  const relay = createRelay({ post: async (payload) => sent.push(payload) })
  relay.handle(event('identity:one', { mainAgent: { state: 'working', stateStartedAt: 90 } }))
  relay.handle(event('identity:two', { mainAgent: { state: 'working', stateStartedAt: 90 } }))
  await relay.idle()
  assert.equal(sent.length, 2)
  assert.ok(sent.every(({ hostId, stateStartedAt }) => hostId === null && stateStartedAt === 90))
  assert.equal(relay.handle(event('identity:one', {
    mainAgent: { state: 'working', stateStartedAt: 99 }, receivedAt: 110
  })), 'queued', 'A new turn in the same state must not be suppressed')
  await relay.idle()
  assert.equal(sent.at(-1).stateStartedAt, 99)
})

test('activation enriches events without awaiting catalog reads and refreshes on workspace changes', async () => {
  const h = harness([row('identity:local', 'local'), row('identity:remote', 'runtime:remote')])
  const events = new Map()
  const sent = []
  const relay = createRelay({ post: async (payload) => sent.push(payload) })
  h.orca.events = { on: (name, callback) => events.set(name, callback) }
  h.orca.commands = { register() {} }
  h.orca.log = () => {}
  const { workspaces, watchdog } = activate(h.orca, {
    relay,
    companionManager: { ensure: async () => ({ status: 'failed' }) },
    watchdogOptions: { fetchStatus: async () => ({ sessionCount: 0, syncUnavailable: false }),
      setIntervalImpl: () => null }
  })
  await workspaces.idle()
  assert.equal(events.get('agent.status.changed')(event('identity:local')), undefined)
  assert.equal(events.get('agent.status.changed')(event('identity:remote')), undefined)
  await relay.idle()
  assert.deepEqual(sent.filter(({ type }) => type === 'orca.agent.status').map(({ hostId }) => hostId),
    ['local', 'runtime:remote'])
  const before = h.calls.filter(({ method }) => method === 'workspace.list').length
  events.get('workspace.changed')({ context: null })
  await workspaces.idle()
  assert.equal(h.calls.filter(({ method }) => method === 'workspace.list').length, before + 1)
  events.get('workspace.removed')(event('identity:remote'))
  await relay.idle()
  assert.equal(sent.at(-1).hostId, 'runtime:remote')
  assert.equal(sent.at(-1).workspaceListId, 'identity:remote')
  await workspaces.idle()
  watchdog.stop()
})
