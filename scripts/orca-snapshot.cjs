'use strict'

// Launched with Orca's bundled Electron in Node mode, never a separately installed Node.
const path = require('node:path')
const fs = require('node:fs')
const { projectHost, exactRevealTarget } = require('./orca-projection.cjs')

async function main() {
  const contents = path.dirname(path.dirname(process.execPath))
  const cli = path.join(contents, 'Resources/app.asar.unpacked/out/cli')
  const { RuntimeClient, getDefaultUserDataPath } = require(path.join(cli, 'runtime-client.js'))
  const { listEnvironments } = require(path.join(cli, 'runtime/environments.js'))
  const { getActiveProfileStateLocation } = require(path.join(cli, 'profile-state-location.js'))
  const userData = getDefaultUserDataPath()
  const local = new RuntimeClient(userData, 5000, null, null)
  const environments = listEnvironments(userData)
  const descriptors = [{ hostId: 'local', environmentId: null, environmentName: null },
    ...environments.map(e => ({ hostId: `runtime:${e.id}`, environmentId: e.id, environmentName: e.name }))]
  const clientFor = h => h.environmentId ? new RuntimeClient(userData, 5000, null, h.environmentId) : local
  const result = async (client, method, params = {}) => (await client.call(method, params)).result

  if (process.argv[2] === 'reveal') {
    const target = JSON.parse(process.argv[3] ?? '{}')
    const host = descriptors.find(h => h.hostId === target.hostId)
    if (!host) throw new Error('unknown_host')
    const snapshot = await result(clientFor(host), 'session.tabs.listAll')
    const exact = exactRevealTarget(target, snapshot.snapshots ?? [])
    if (!exact) throw new Error('pane_not_found_or_ambiguous')
    if (exact.sessionId) {
      // A remote structured-session reveal needs a separate supported desktop route.
      if (host.hostId !== 'local') throw new Error('remote_chat_reveal_unavailable')
      await result(local, 'agentSession.reveal', exact)
    } else {
      // Always reveal in this desktop with an explicit execution host. Never focus the remote machine.
      await result(local, 'terminal.reveal', exact)
    }
    return { ok: true }
  }

  const ui = await result(local, 'ui.get')
  const location = getActiveProfileStateLocation(userData)
  let localSession
  let viewerSessions = {}
  let profileSettings = {}
  if (fs.existsSync(location.databaseFile)) {
    const { DatabaseSync } = require('node:sqlite')
    const db = new DatabaseSync(location.databaseFile, { readOnly: true })
    try {
      const row = db.prepare("SELECT payload FROM profile_state_documents WHERE domain = 'workspaceSession'").get()
      if (!row) throw new Error('profile_session_missing')
      localSession = JSON.parse(row.payload)
      const viewers = db.prepare("SELECT payload FROM profile_state_documents WHERE domain = 'workspaceSessionsByHostId'").get()
      viewerSessions = viewers ? JSON.parse(viewers.payload) : {}
      const settings = db.prepare("SELECT payload FROM profile_state_documents WHERE domain = 'settings'").get()
      profileSettings = settings ? JSON.parse(settings.payload) : {}
    } finally { db.close() }
  } else {
    const legacy = JSON.parse(fs.readFileSync(location.dataFile, 'utf8'))
    localSession = legacy.workspaceSession
    viewerSessions = legacy.workspaceSessionsByHostId ?? {}
    profileSettings = legacy.settings ?? {}
  }
  if (!localSession || typeof localSession !== 'object') throw new Error('profile_session_invalid')
  const ack = ui.ui?.acknowledgedAgentsByPaneKey ?? {}
  const showIdle = profileSettings.experimentalAgentDashboardShowIdle === true
  const hosts = await Promise.all(descriptors.map(async host => {
    try {
      const client = clientFor(host)
      const [ps, terminals, tabs] = await Promise.all([
        result(client, 'worktree.ps'), result(client, 'terminal.list', { includeVisualLayouts: false }),
        result(client, 'session.tabs.listAll')])
      if (ps.truncated || terminals.truncated || !Array.isArray(ps.worktrees)
        || !Array.isArray(terminals.terminals) || !Array.isArray(tabs.snapshots)) throw new Error('incomplete_inventory')
      // terminal.list can report local as omitted while retaining surface metadata;
      // it is only a title/handle join. worktree.ps owns inventory coverage.
      if (!ps.hostScope?.hostIds?.includes('local') || ps.hostScope?.omittedHostIds?.includes('local')) {
        throw new Error('host_inventory_omitted')
      }
      const events = projectHost({ ...host, worktrees: ps.worktrees, terminals: terminals.terminals,
        snapshots: tabs.snapshots, sleeping: host.hostId === 'local' ? localSession.sleepingAgentSessionsByPaneKey : {},
        viewerSession: viewerSessions[host.hostId] ?? {}, acknowledgements: ack, showIdle })
      return { ...host, available: true, events }
    } catch { return { ...host, available: false, events: [] } }
  }))
  return { ok: true, hosts }
}

main().then(value => process.stdout.write(JSON.stringify(value))).catch(() => {
  // Keep tokens, runtime paths, RPC payloads and conversation text out of diagnostics.
  process.stdout.write(JSON.stringify({ ok: false, error: 'orca_snapshot_unavailable' }))
  process.exitCode = 1
})
