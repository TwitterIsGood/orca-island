'use strict'

// Launched with Orca's bundled Electron in Node mode, never a separately installed Node.
const path = require('node:path')
const fs = require('node:fs')
const { projectHost, exactRevealTarget } = require('./orca-projection.cjs')

// Orca 1.4.258 moved listEnvironments out of cli/runtime/environments.js into the shared
// host store. Probe known locations so the companion survives Orca updates in either direction.
function resolveListEnvironments(cli) {
  const candidates = [
    path.join(cli, 'runtime/environments.js'),
    path.join(cli, '../shared/remote-runtime/host-store/runtime-environment-store.js')
  ]
  for (const file of candidates) {
    try {
      const fn = require(file).listEnvironments
      if (typeof fn === 'function') return fn
    } catch {}
  }
  // No environment catalog means local-only; never fail the whole snapshot for it.
  return () => []
}

// Orca 1.4.259 split cli/runtime-client.js into cli/runtime/{client,metadata}.js and moved
// profile-state-location.js under cli/profiles/. Probe old and new locations per export.
function resolveExport(cli, name, files) {
  let lastError
  for (const file of files) {
    try {
      const value = require(path.join(cli, file))[name]
      if (typeof value === 'function') return value
    } catch (error) { lastError = error }
  }
  const error = new Error(`${name} is not a function`)
  error.code = lastError?.code ?? 'MODULE_NOT_FOUND'
  throw error
}

async function main() {
  const contents = path.dirname(path.dirname(process.execPath))
  const cli = path.join(contents, 'Resources/app.asar.unpacked/out/cli')
  const RuntimeClient = resolveExport(cli, 'RuntimeClient', ['runtime-client.js', 'runtime/client.js'])
  const getDefaultUserDataPath = resolveExport(cli, 'getDefaultUserDataPath',
    ['runtime-client.js', 'runtime/metadata.js'])
  const listEnvironments = resolveListEnvironments(cli)
  const getActiveProfileStateLocation = resolveExport(cli, 'getActiveProfileStateLocation',
    ['profile-state-location.js', 'profiles/profile-state-location.js'])
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

// Classify without leaking tokens, paths, RPC payloads or conversation text.
function failureCode(error) {
  const text = String(error?.message ?? error)
  if (error?.code === 'MODULE_NOT_FOUND' || /is not a (function|constructor)|Cannot read propert/i.test(text)) {
    // Orca moved or renamed a private module this companion depends on.
    return 'orca_api_incompatible'
  }
  if (/ECONNREFUSED|ENOENT|EPIPE|ECONNRESET|socket|timed? ?out|runtime/i.test(text)) return 'orca_runtime_unreachable'
  return 'orca_snapshot_failed'
}

main().then(value => process.stdout.write(JSON.stringify(value))).catch(error => {
  // Exit 0 so the companion can read the reason; `ok: false` still marks the failure.
  process.stdout.write(JSON.stringify({ ok: false, error: failureCode(error) }))
})
