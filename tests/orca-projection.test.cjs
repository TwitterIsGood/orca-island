'use strict'
const test = require('node:test')
const assert = require('node:assert/strict')
const { projectHost, exactRevealTarget, paneIdentity } = require('../scripts/orca-projection.cjs')

const now = 1_800_000_000_000
function fixture(state = 'working') {
  return {
    now, worktrees: [{ worktreeId: 'repo::/project', repo: 'Project', hostId: 'local',
      agents: [{ paneKey: 'tab:leaf', state, stateStartedAt: now - 1000, updatedAt: now, agentType: 'codex' }] }],
    terminals: [{ tabId: 'tab', leafId: 'leaf', worktreeId: 'repo::/project', connected: true,
      title: 'Conversation', handle: 'term_one' }],
    snapshots: [{ worktree: 'repo::/project', tabs: [{ type: 'terminal', id: 'tab::leaf',
      parentTabId: 'tab', leafId: 'leaf', title: 'Codex', terminal: 'term_one' }] }]
  }
}

test('same pane on different hosts has separate identity and explicit reveal destination', () => {
  const local = projectHost(fixture())[0]
  const remote = projectHost({ ...fixture(), hostId: 'runtime:server', environmentId: 'server' })[0]
  assert.notEqual(paneIdentity(local.hostId, local.paneKey), paneIdentity(remote.hostId, remote.paneKey))
  assert.equal(exactRevealTarget(remote, fixture().snapshots).executionHostId, 'runtime:server')
})

test('sleeping completion is retained by current layout, not live PTY or arbitrary historical records', () => {
  const f = fixture(); f.worktrees[0].agents = []; f.terminals = []
  f.sleeping = { one: { paneKey: 'tab:leaf', tabId: 'tab', worktreeId: 'repo::/project',
    state: 'done', agent: 'codex', mainAgent: { state: 'done', stateStartedAt: now - 1000 }, updatedAt: now } }
  const event = projectHost(f)[0]
  assert.equal(event.state, 'done'); assert.equal(event.leafId, 'leaf')
  assert.equal(exactRevealTarget(event, f.snapshots).tabId, 'tab')
  assert.equal(projectHost({ ...f, snapshots: [] }).length, 0)
  f.sleeping.one.state = 'working'
  assert.equal(projectHost(f).length, 0)
})

test('acknowledged completions produce suppression records and respect showIdle', () => {
  const f = { ...fixture('done'), acknowledgements: { 'tab:leaf': now } }
  assert.equal(projectHost(f)[0].isHidden, true)
  const idle = projectHost({ ...f, showIdle: true })[0]
  assert.equal(idle.state, 'idle'); assert.equal(idle.isHidden, false)
  assert.equal(projectHost({ ...fixture('idle') })[0].isHidden, true)
})

test('remote ack joins this viewer’s mirrored tab under the correct host workspace', () => {
  const f = { ...fixture('done'), hostId: 'runtime:remote', acknowledgements: { 'web-terminal-tab:leaf': now },
    viewerSession: { tabsByWorktree: { 'repo::/project': [{ id: 'web-terminal-tab' }] } } }
  assert.equal(projectHost(f)[0].isHidden, true)
  assert.equal(projectHost({ ...f, viewerSession: {} })[0].isHidden, false)
})

test('archived, nested SSH, and unbound rows cannot become incorrectly routed local cards', () => {
  const f = fixture(); f.worktrees[0].isArchived = true
  assert.equal(projectHost(f).length, 0)
  f.worktrees[0].isArchived = false; f.worktrees[0].hostId = 'ssh:box'
  assert.equal(projectHost(f).length, 0)
  f.worktrees[0].hostId = 'local'; f.terminals = []; f.snapshots = []
  assert.equal(projectHost(f).length, 0)
})

test('terminal-backed child workers remain visible; stale local evidence becomes idle', () => {
  const f = fixture(); f.worktrees[0].agents[0].parentPaneKey = 'other:parent'
  assert.equal(projectHost(f).length, 1)
  f.worktrees[0].agents[0].updatedAt = now - 31 * 60 * 1000
  assert.equal(projectHost(f)[0].isHidden, true)
  f.worktrees[0].agents[0].structuredHostOwned = true
  assert.equal(projectHost(f)[0].state, 'working')
})

test('reveal refuses closed, wrong-workspace, and ambiguous panes instead of using title matching', () => {
  const f = fixture(); const target = projectHost(f)[0]
  assert.equal(exactRevealTarget(target, []), null)
  assert.equal(exactRevealTarget({ ...target, workspaceId: 'other' }, f.snapshots), null)
  assert.equal(exactRevealTarget(target, [...f.snapshots, ...f.snapshots]), null)
  assert.equal(exactRevealTarget({ ...target, paneKey: 'tab:other' }, f.snapshots), null)
})
