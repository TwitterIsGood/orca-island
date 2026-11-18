// Only Orca's versioned plugin host API is used here. Workspace ids are opaque:
// never decode identities or guess an execution host from a path, title or pane.
const MAX_WORKSPACES = 500
const string = (value) => typeof value === 'string' && value.length > 0 ? value : null
const knownHost = (value) => value === 'local'
  || (typeof value === 'string' && /^(ssh|runtime):.+/.test(value))

export function createPublicWorkspaces({ orca, log = () => {}, timeoutMs = 1500 } = {}) {
  let workspaces = new Map()
  let refreshing = null
  let refreshAgain = false

  function available() {
    if (typeof orca?.host?.call !== 'function') return false
    if (typeof orca.host.has === 'function') return orca.host.has('workspace.list')
    return orca.api?.major === 1 && orca.api.minor >= 3
  }

  async function readCatalog() {
    let timer
    try {
      if (!available()) return false
      // host.has detects the method, not its newer parameters. Older hosts can
      // still supply workspace identities without the includeStatus parameter.
      const params = orca.api?.major === 1 && orca.api.minor >= 7 ? { includeStatus: true } : {}
      const result = await Promise.race([
        Promise.resolve().then(() => orca.host.call('workspace.list', params)),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('workspace catalog timed out')), timeoutMs)
        })
      ])
      if (!Array.isArray(result?.workspaces) || typeof result.truncated !== 'boolean') {
        throw new Error('invalid public workspace catalog')
      }
      // An incomplete listing cannot prove old workspaces disappeared. A failed
      // read never reaches this assignment, so it never clears a useful cache.
      const next = result.truncated ? new Map(workspaces) : new Map()
      const seen = new Set()
      for (const row of result.workspaces.slice(0, MAX_WORKSPACES)) {
        const id = string(row?.id)
        if (!id) continue
        if (seen.has(id)) {
          next.delete(id) // ambiguous ids are never safe routing evidence
          continue
        }
        seen.add(id)
        if (!knownHost(row.hostId)) {
          next.delete(id) // do not silently interpret a missing host as local
          continue
        }
        next.delete(id)
        next.set(id, { id, hostId: row.hostId, name: string(row.name), project: string(row.project) })
        while (next.size > MAX_WORKSPACES) next.delete(next.keys().next().value)
      }
      workspaces = next
      return true
    } catch (error) {
      log(`Orca Island workspace catalog: ${error instanceof Error ? error.message : String(error)}`)
      return false
    } finally {
      clearTimeout(timer)
    }
  }

  function refresh({ afterPending = false } = {}) {
    if (refreshing) {
      // A lifecycle change may occur after the in-flight catalog took its
      // snapshot. Coalesce those changes into one subsequent read.
      refreshAgain ||= afterPending
      return refreshing
    }
    refreshing = readCatalog().finally(() => {
      refreshing = null
      if (refreshAgain) {
        refreshAgain = false
        refresh()
      }
    })
    return refreshing
  }

  return {
    refresh,
    async idle() {
      while (refreshing) await refreshing
    },
    enrich(payload) {
      const workspaceListId = string(payload?.workspaceListId)
      // Older events can join only if their raw id literally is a public list
      // id (e.g. a folder key). Never fall back from an unknown qualified id.
      const row = workspaces.get(workspaceListId ?? string(payload?.workspaceId))
      const hostId = row?.hostId ?? null
      return {
        ...payload,
        workspaceListId,
        hostId,
        environmentId: hostId?.startsWith('runtime:') ? hostId.slice('runtime:'.length) : null,
        environmentName: null,
        workspaceLabel: row ? row.project ?? row.name : null
      }
    }
  }
}
