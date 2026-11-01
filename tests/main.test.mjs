import test from 'node:test'
import assert from 'node:assert/strict'
import { createRelay } from '../main.mjs'

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
