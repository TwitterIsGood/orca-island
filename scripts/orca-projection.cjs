'use strict'

// Pure projection, kept separate from runtime access so fixtures never touch Orca.
const text = (v) => typeof v === 'string' && v.trim() ? v.trim() : null
const paneIdentity = (host, pane) => JSON.stringify([host || 'local', pane])
const realPane = (t) => text(t.parentTabId ?? t.tabId) && text(t.leafId)
  ? `${t.parentTabId ?? t.tabId}:${t.leafId}` : null

function projectHost({ hostId = 'local', environmentId = null, environmentName = null,
  worktrees, terminals, snapshots = [], sleeping = {}, viewerSession = {}, acknowledgements = {}, showIdle = false, now = Date.now() }) {
  const events = new Map()
  // Nested SSH hosts need their own routing contract; never relabel them as this host.
  const workspaces = new Map(worktrees.filter(w => !w.isArchived && (!w.hostId || w.hostId === 'local'))
    .map(w => [w.worktreeId, w]))
  const tabs = snapshots.flatMap(s => (s.tabs ?? []).map(t => ({ ...t, worktreeId: s.worktree })))
  const byPane = new Map(tabs.map(t => [t.agentStatus?.paneKey ?? realPane(t) ?? t.id, t]))
  const terminalByPane = new Map(terminals.filter(t => !t.orphaned && t.connected !== false)
    .map(t => [realPane(t), t]))

  function put(w, a, sleepingRecord = false) {
    const pane = text(a.paneKey)
    if (!pane || !w) return
    const tab = byPane.get(pane)
    const terminal = terminalByPane.get(pane)
    // A reused pane may belong to a different workspace; never borrow its title or route.
    if ((tab && tab.worktreeId !== w.worktreeId) || (terminal && terminal.worktreeId !== w.worktreeId)) return
    let state = a.state
    if (!['working', 'waiting', 'blocked', 'done', 'idle'].includes(state)) return
    const stateStartedAt = a.stateStartedAt ?? a.mainAgent?.stateStartedAt ?? a.updatedAt ?? 0
    const updatedAt = a.updatedAt ?? a.receivedAt ?? stateStartedAt
    const tabId = tab?.parentTabId ?? terminal?.tabId ?? a.tabId
    const leafId = tab?.leafId ?? terminal?.leafId
    const mirrorTab = (viewerSession.tabsByWorktree?.[w.worktreeId] ?? [])
      .find(t => t.id === `web-terminal-${tabId}`)
    const acknowledgementKey = hostId === 'local' ? pane
      : mirrorTab && leafId ? `${mirrorTab.id}:${leafId}` : null
    const acknowledged = acknowledgementKey !== null && (acknowledgements[acknowledgementKey] ?? 0) >= stateStartedAt
    if (a.restoredUnconfirmed || (hostId === 'local' && state !== 'done' && !a.structuredHostOwned
      && now - (a.evidenceObservedAt ?? updatedAt) > 30 * 60 * 1000)) state = 'idle'
    const hidden = !showIdle && (state === 'idle' || (state === 'done' && acknowledged))
    const displayedState = state === 'done' && acknowledged ? 'idle' : state
    const hasRoute = Boolean(tab || terminal || a.structuredHostOwned || sleepingRecord)
    if (!hasRoute) return // unbound/removed runtime rows must not become clickable ghosts
    const title = text(terminal?.paneTitle) ?? text(tab?.customTitle) ?? text(terminal?.title)
      ?? text(tab?.title) ?? text(a.terminalTitle) ?? text(a.displayName)
      ?? (a.agentType ?? a.agent ?? 'Agent')
    const event = {
      type: 'orca.snapshot', hostId, environmentId, environmentName,
      workspaceId: w.worktreeId, workspaceLabel: w.repo ?? w.displayName,
      paneKey: pane, state: displayedState, combinedState: displayedState,
      mainAgent: a.mainAgent ?? null, stateStartedAt, receivedAt: updatedAt,
      terminalTitle: title, terminalId: terminal?.handle ?? tab?.terminal ?? null,
      tabId: tabId ?? null,
      leafId: leafId ?? null,
      structuredSessionId: tab?.type === 'agent-session' ? (tab.sessionId ?? null) : null,
      isStale: false, isHidden: hidden,
    }
    // Closed PTYs still have an exact retained layout identity; derive only from its known tab prefix.
    if (!event.leafId && event.tabId && pane.startsWith(`${event.tabId}:`)) {
      event.leafId = pane.slice(event.tabId.length + 1)
    }
    const old = events.get(pane)
    if (!old || updatedAt > old.receivedAt) events.set(pane, event)
  }

  for (const w of workspaces.values()) for (const a of w.agents ?? []) put(w, a)
  for (const t of tabs) {
    if (t.agentStatus) put(workspaces.get(t.worktreeId), t.agentStatus)
  }
  // Durable completion evidence only; a sleeping working record is not live work.
  for (const a of Object.values(sleeping)) {
    if (a.state !== 'done' || events.has(a.paneKey)) continue
    const tab = byPane.get(a.paneKey)
    // Current layout membership proves the session has not been closed/replaced.
    if (!tab || tab.worktreeId !== a.worktreeId) continue
    put(workspaces.get(a.worktreeId), a, true)
  }
  return [...events.values()]
}

function exactRevealTarget(target, snapshots) {
  if (!text(target.workspaceId) || !text(target.paneKey)) return null
  const matches = snapshots.filter(s => s.worktree === target.workspaceId).flatMap(s => s.tabs ?? [])
    .filter(t => (t.agentStatus?.paneKey ?? realPane(t) ?? t.id) === target.paneKey)
  if (matches.length !== 1) return null
  const tab = matches[0]
  if (tab.type === 'agent-session') return tab.sessionId ? { sessionId: tab.sessionId } : null
  if (tab.type !== 'terminal') return null
  const tabId = tab.parentTabId ?? tab.tabId
  return text(tabId) && text(tab.leafId)
    ? { worktreeId: target.workspaceId, tabId, leafId: tab.leafId, executionHostId: target.hostId || 'local' }
    : null
}

module.exports = { projectHost, exactRevealTarget, paneIdentity }
