import test from 'node:test'
import assert from 'node:assert/strict'
import { createRelay } from '../main.mjs'

function deferred() {
  let resolve
  const promise = new Promise((done) => { resolve = done })
  return { promise, resolve }
}

function event(state, receivedAt, paneKey = 'tab:leaf') {
  return { workspaceId: 'workspace', paneKey, state, receivedAt }
}

test('deduplicates repeated agent states and forwards the normalized event', async () => {
  const sent = []
  const relay = createRelay({ post: async (payload) => sent.push(payload) })
  const payload = {
    workspaceId: 'workspace-1',
    paneKey: 'tab-1:leaf-1',
    state: 'working',
    receivedAt: 123,
    mainAgent: { state: 'done', stateStartedAt: 120 }
  }

  assert.equal(relay.handle(payload), 'queued')
  assert.equal(relay.handle(payload), 'duplicate')
  await relay.idle()

  assert.deepEqual(sent, [
    {
      type: 'orca.agent.status',
      workspaceId: 'workspace-1',
      paneKey: 'tab-1:leaf-1',
      state: 'working',
      combinedState: 'working',
      mainAgent: { state: 'done', stateStartedAt: 120 },
      receivedAt: 123
    }
  ])
})

test('keeps delivery failures inside the worker and drains later events', async () => {
  const sent = []
  const logs = []
  let attempts = 0
  const relay = createRelay({
    post: async (payload) => {
      attempts += 1
      if (attempts === 1) throw new Error('companion offline')
      sent.push(payload)
    },
    log: (line) => logs.push(line)
  })

  relay.handle({ paneKey: 'pane-1', state: 'working', receivedAt: 1 })
  relay.handle({ paneKey: 'pane-1', state: 'done', receivedAt: 2 })
  await relay.idle()

  assert.equal(sent.length, 1)
  assert.equal(sent[0].state, 'done')
  assert.match(logs[0], /companion offline/)
})

test('retries the same state on a later hook after a failed delivery', async () => {
  let attempts = 0
  const sent = []
  const relay = createRelay({
    // Deliberately throw synchronously as well as testing the network-style
    // rejected promise above; neither failure may strand the drain promise.
    post(payload) {
      attempts += 1
      if (attempts === 1) throw new Error('companion offline')
      sent.push(structuredClone(payload))
    }
  })

  relay.handle(event('working', 10))
  await relay.idle()
  assert.equal(attempts, 1, 'A failure must not start automatic retries')
  assert.equal(relay.handle(event('working', 20)), 'queued')
  await relay.idle()
  assert.equal(attempts, 2)
  assert.deepEqual(sent.map(({ state, receivedAt }) => [state, receivedAt]), [['working', 20]])
})

test('does not trust an older success after an uncertain failed response', async () => {
  const sent = []
  const relay = createRelay({
    async post(payload) {
      sent.push(payload.state)
      if (payload.state === 'done') throw new Error('response lost after receipt')
    }
  })

  relay.handle(event('working', 10))
  await relay.idle()
  relay.handle(event('done', 20))
  await relay.idle()
  assert.equal(relay.handle(event('working', 30)), 'queued')
  await relay.idle()
  assert.deepEqual(sent, ['working', 'done', 'working'])
})

test('preserves working to done to working while the first delivery is in flight', async () => {
  const first = deferred()
  const sent = []
  const relay = createRelay({
    async post(payload) {
      sent.push(structuredClone(payload))
      if (sent.length === 1) await first.promise
    }
  })

  relay.handle(event('working', 10))
  await Promise.resolve()
  assert.equal(relay.handle(event('done', 20)), 'queued')
  assert.equal(relay.handle(event('working', 30)), 'queued')
  first.resolve()
  await relay.idle()
  assert.deepEqual(sent.map(({ state, receivedAt }) => [state, receivedAt]), [
    ['working', 10], ['done', 20], ['working', 30]
  ])
})

test('does not suppress a return to the last successful state behind an in-flight transition', async () => {
  const completion = deferred()
  const sent = []
  const relay = createRelay({
    async post(payload) {
      sent.push(payload.state)
      if (payload.state === 'done') await completion.promise
    }
  })

  relay.handle(event('working', 10))
  await relay.idle()
  relay.handle(event('done', 20))
  await Promise.resolve()
  assert.equal(relay.handle(event('working', 30)), 'queued')
  completion.resolve()
  await relay.idle()
  assert.deepEqual(sent, ['working', 'done', 'working'])
})

test('coalesces pending duplicates to the newest timestamp without reordering transitions', async () => {
  const first = deferred()
  const sent = []
  const relay = createRelay({
    async post(payload) {
      sent.push(structuredClone(payload))
      if (sent.length === 1) await first.promise
    }
  })

  relay.handle(event('working', 1, 'blocker'))
  await Promise.resolve()
  relay.handle(event('working', 10))
  assert.equal(relay.handle(event('working', 20)), 'duplicate')
  assert.equal(relay.handle(event('working', 15)), 'duplicate')
  relay.handle(event('done', 30))
  first.resolve()
  await relay.idle()
  assert.deepEqual(sent.filter(({ paneKey }) => paneKey === 'tab:leaf')
    .map(({ state, receivedAt }) => [state, receivedAt]), [['working', 20], ['done', 30]])
})

test('coalesces in-flight duplicates into one latest-timestamp refresh after serialization', async () => {
  const first = deferred()
  const serialized = []
  const relay = createRelay({
    async post(payload) {
      // Freeze the bytes as fetch() does; mutating the original object cannot
      // retroactively update an HTTP request that has already been sent.
      serialized.push(JSON.stringify(payload))
      if (serialized.length === 1) await first.promise
    }
  })

  relay.handle(event('working', 10))
  await Promise.resolve()
  assert.equal(relay.handle(event('working', 20)), 'duplicate')
  assert.equal(relay.handle(event('working', 30)), 'duplicate')
  assert.equal(relay.handle(event('working', 25)), 'duplicate')
  first.resolve()
  await relay.idle()
  assert.deepEqual(serialized.map((payload) => JSON.parse(payload).receivedAt), [10, 30])
  assert.equal(relay.handle(event('working', 40)), 'duplicate')
  await relay.idle()
  assert.equal(serialized.length, 2, 'A delivered unchanged state needs no extra request')
})

test('a queued transition supersedes an in-flight same-state timestamp refresh', async () => {
  const first = deferred()
  const sent = []
  const relay = createRelay({
    async post(payload) {
      sent.push(structuredClone(payload))
      if (sent.length === 1) await first.promise
    }
  })

  relay.handle(event('working', 10))
  await Promise.resolve()
  relay.handle(event('working', 20))
  relay.handle(event('done', 30))
  first.resolve()
  await relay.idle()
  assert.deepEqual(sent.map(({ state, receivedAt }) => [state, receivedAt]), [
    ['working', 10], ['done', 30]
  ])
})

test('a queue-dropped event can be delivered again on a later hook', async () => {
  const first = deferred()
  const sent = []
  const logs = []
  const relay = createRelay({
    maxPending: 1,
    log: (line) => logs.push(line),
    async post(payload) {
      sent.push(payload.paneKey)
      if (sent.length === 1) await first.promise
    }
  })

  relay.handle(event('working', 1, 'blocker'))
  await Promise.resolve()
  relay.handle(event('working', 10, 'dropped'))
  relay.handle(event('working', 20, 'retained'))
  first.resolve()
  await relay.idle()
  assert.deepEqual(sent, ['blocker', 'retained'])
  assert.equal(logs.length, 1)
  assert.match(logs[0], /queue dropped the oldest event/)
  assert.equal(relay.handle(event('working', 30, 'dropped')), 'queued')
  await relay.idle()
  assert.deepEqual(sent, ['blocker', 'retained', 'dropped'])
})

test('an in-flight timestamp refresh cannot evict a queued state transition', async () => {
  const first = deferred()
  const sent = []
  const relay = createRelay({
    maxPending: 1,
    async post(payload) {
      sent.push(structuredClone(payload))
      if (sent.length === 1) await first.promise
    }
  })

  relay.handle(event('working', 10))
  await Promise.resolve()
  relay.handle(event('working', 20))
  relay.handle(event('done', 30, 'other-pane'))
  first.resolve()
  await relay.idle()
  assert.deepEqual(sent.map(({ paneKey, receivedAt }) => [paneKey, receivedAt]), [
    ['tab:leaf', 10], ['other-pane', 30]
  ])
  assert.equal(relay.handle(event('working', 40)), 'queued', 'A skipped refresh remains eligible for a later hook')
  await relay.idle()
  assert.equal(sent.at(-1).receivedAt, 40)
})

test('tracks main-agent transitions independently of the aggregate state', async () => {
  const sent = []
  const relay = createRelay({ post: async (payload) => sent.push(payload) })
  relay.handle({ ...event('working', 10), mainAgent: { state: 'working' } })
  await relay.idle()
  assert.equal(relay.handle({ ...event('working', 20), mainAgent: { state: 'done' } }), 'queued')
  await relay.idle()
  assert.deepEqual(sent.map(({ state, mainAgent }) => [state, mainAgent.state]), [
    ['working', 'working'], ['working', 'done']
  ])
})

test('bounds successful-state memory and retains recently used panes', async () => {
  const sent = []
  const relay = createRelay({
    maxTracked: 2,
    post: async (payload) => sent.push(payload.paneKey)
  })
  for (const paneKey of ['a', 'b']) {
    relay.handle(event('working', 10, paneKey))
    await relay.idle()
  }
  assert.equal(relay.handle(event('working', 20, 'a')), 'duplicate')
  relay.handle(event('working', 30, 'c'))
  await relay.idle()
  assert.equal(relay.handle(event('working', 40, 'a')), 'duplicate')
  assert.equal(relay.handle(event('working', 50, 'b')), 'queued', 'The evicted pane may be delivered again')
  await relay.idle()
  assert.deepEqual(sent, ['a', 'b', 'c', 'b'])
})
