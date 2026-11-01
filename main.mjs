import { createCompanionManager } from './lib/companion-manager.mjs'

const DEFAULT_ENDPOINT = 'http://127.0.0.1:17777/events'
const MAX_PENDING = 20
const MAX_TRACKED = 1000
const REQUEST_TIMEOUT_MS = 1000
const RETRY_DELAYS_MS = [200, 600]
const SUCCESS_CACHE_TTL_MS = 30_000
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function eventState(payload) {
  // `state` includes live subagents; keep the main-agent state separately.
  return payload?.state ?? payload?.mainAgent?.state ?? 'unknown'
}

function eventKey(payload) {
  return `${payload?.workspaceId ?? 'unknown'}:${payload?.paneKey ?? 'unknown'}`
}

async function postJson(endpoint, payload, timeoutMs = REQUEST_TIMEOUT_MS) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  try {
    const response = await fetch(endpoint, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(payload),
      signal: controller.signal
    })
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`)
    }
  } finally {
    clearTimeout(timer)
  }
}

export function createRelay({
  endpoint = DEFAULT_ENDPOINT,
  post = (payload) => postJson(endpoint, payload),
  log = () => {},
  maxPending = MAX_PENDING,
  maxTracked = MAX_TRACKED,
  retryDelays = RETRY_DELAYS_MS,
  sleep = delay,
  now = Date.now,
  successCacheTtlMs = SUCCESS_CACHE_TTL_MS
} = {}) {
  if (!Number.isInteger(maxPending) || maxPending < 1
      || !Number.isInteger(maxTracked) || maxTracked < 1) {
    throw new RangeError('Relay queue and success-cache limits must be positive integers')
  }
  if (!Array.isArray(retryDelays) || retryDelays.length > 2
      || retryDelays.some((ms) => !Number.isFinite(ms) || ms < 0 || ms > 1000)) {
    throw new RangeError('Relay supports at most two retry delays between 0 and 1000 milliseconds')
  }
  const lastSuccessful = new Map()
  const pending = []
  let inFlight = null
  let draining = null

  function enqueue(event) {
    pending.push(event)
    if (pending.length > maxPending) {
      const dropped = pending.shift()
      // A dropped update must be eligible for delivery on a later hook.
      lastSuccessful.delete(dropped.key)
      log(`relay queue dropped the oldest event (limit ${maxPending})`)
    }
  }

  function rememberSuccess(key, fingerprint) {
    lastSuccessful.delete(key)
    lastSuccessful.set(key, { fingerprint, succeededAt: now() })
    if (lastSuccessful.size > maxTracked) {
      lastSuccessful.delete(lastSuccessful.keys().next().value)
    }
  }

  async function deliver(payload) {
    // Keep a single event in flight across the short retries. A later "done"
    // must not overtake its earlier "working" when the companion is starting.
    for (let attempt = 0; ; attempt++) {
      try {
        await post(payload)
        return
      } catch (error) {
        if (attempt >= retryDelays.length) throw error
        await sleep(retryDelays[attempt])
      }
    }
  }

  async function drain() {
    while (pending.length > 0) {
      const event = pending.shift()
      const sentPayload = event.payload
      inFlight = event
      try {
        await deliver(sentPayload)
        if (event.cacheable) rememberSuccess(event.key, event.fingerprint)
        // HTTP serialization has already happened. Coalesce duplicates received
        // during the request into one later update with the latest timestamp.
        // A queued transition for this pane supersedes that same-state refresh.
        if (event.cacheable && event.payload.receivedAt > sentPayload.receivedAt
            && !pending.some((queued) => queued.key === event.key)) {
          if (pending.length < maxPending) {
            enqueue(event)
          } else {
            // A timestamp refresh must not evict another pane's real transition.
            // Leave this pane eligible for its next hook instead.
            lastSuccessful.delete(event.key)
          }
        }
      } catch (error) {
        // Even an earlier success is uncertain after a failed response: the
        // companion may have accepted the request before the connection broke.
        lastSuccessful.delete(event.key)
        log(`relay failed: ${error instanceof Error ? error.message : String(error)}`)
      } finally {
        inFlight = null
      }
    }
  }

  function startDrain() {
    if (draining) return
    // Defer invocation so a synchronous post() failure cannot leave a completed
    // promise installed as the active drain and strand future events.
    draining = Promise.resolve().then(drain).finally(() => {
      draining = null
      if (pending.length > 0) startDrain()
    })
  }

  function queueControl(payload) {
    enqueue({ key: payload.type, cacheable: false, payload })
    startDrain()
    return 'queued'
  }

  return {
    handle(payload) {
      const key = eventKey(payload)
      const state = eventState(payload)
      const mainState = payload?.mainAgent?.state ?? null
      const terminalTitle = payload?.title ?? payload?.terminalTitle ?? null
      const terminalId = payload?.terminalId ?? null
      const fingerprint = JSON.stringify([state, mainState, terminalTitle, terminalId])
      const normalized = {
        type: 'orca.agent.status',
        workspaceId: payload?.workspaceId ?? null,
        paneKey: payload?.paneKey ?? null,
        terminalTitle,
        terminalId,
        state,
        combinedState: payload?.state ?? state,
        mainAgent: payload?.mainAgent ?? null,
        receivedAt: payload?.receivedAt ?? now()
      }
      // Inspect the latest queued transition, not any earlier matching state:
      // working -> done -> working must remain three ordered transitions.
      const latest = pending.findLast((event) => event.key === key)
        ?? (inFlight?.key === key ? inFlight : null)
      if (latest?.fingerprint === fingerprint) {
        if (normalized.receivedAt > latest.payload.receivedAt) latest.payload = normalized
        return 'duplicate'
      }
      const previous = lastSuccessful.get(key)
      if (!latest && previous?.fingerprint === fingerprint
          && now() - previous.succeededAt < successCacheTtlMs) {
        // Update LRU order without extending the delivery TTL. A later hook
        // can re-establish the bridge after the native companion restarts.
        lastSuccessful.delete(key)
        lastSuccessful.set(key, previous)
        return 'duplicate'
      }
      enqueue({ key, fingerprint, cacheable: true, payload: normalized })
      startDrain()
      return 'queued'
    },
    hello(pluginApi) {
      // A successful launch may be a new companion process with an empty
      // state cache. Its next real hook must remain eligible for delivery.
      lastSuccessful.clear()
      const payload = { type: 'orca.bridge.hello', protocol: 1, sentAt: now() }
      if (Number.isInteger(pluginApi?.major) && Number.isInteger(pluginApi?.minor)) {
        payload.pluginApi = { major: pluginApi.major, minor: pluginApi.minor }
      }
      return queueControl(payload)
    },
    workspaceChanged(kind, payload) {
      if (!['created', 'removed'].includes(kind) || typeof payload?.workspaceId !== 'string'
          || !payload.workspaceId) return 'ignored'
      return queueControl({
        type: `orca.workspace.${kind}`,
        workspaceId: payload.workspaceId,
        receivedAt: payload.receivedAt ?? now()
      })
    },
    async sendTest() {
      const payload = {
        type: 'orca.test',
        workspaceId: null,
        paneKey: null,
        state: 'waiting',
        combinedState: 'waiting',
        mainAgent: null,
        receivedAt: now()
      }
      await post(payload)
      return 'sent'
    },
    async idle() {
      while (draining) await draining
    }
  }
}

export default function activate(orca, {
  companionManager = createCompanionManager({ log: (line) => orca.log(line) }),
  relay = createRelay({ log: (line) => orca.log(line) })
} = {}) {

  // Orca kills workers that keep too many events unacknowledged. Queue delivery
  // and return immediately from the event handler.
  orca.events.on('agent.status.changed', (payload) => {
    relay.handle(payload)
  })
  for (const kind of ['created', 'removed']) {
    orca.events.on(`workspace.${kind}`, (payload) => {
      relay.workspaceChanged(kind, payload)
    })
  }

  orca.commands.register('orca-island.send-test', () => relay.sendTest())

  // Startup is deliberately fire-and-forget: plugin activation must remain
  // responsive while the companion is checked or installed in the background.
  let preparing = null
  function startCompanion(retry = false) {
    if (!preparing) {
      preparing = Promise.resolve().then(() => companionManager.ensure({ retry })).then((result) => {
        if (result?.status === 'running') relay.hello()
      }).catch((error) => {
        orca.log(`Orca Island: ${error instanceof Error ? error.message : String(error)}`)
      }).finally(() => { preparing = null })
    }
    // Installation may exceed the host's command timeout. The manager reports
    // its eventual outcome through the plugin log; never hold a command open.
    return { status: 'preparing', message: 'Orca Island is preparing in the background. Check the plugin log for readiness.' }
  }
  startCompanion()
  orca.commands.register('orca-island.install-start', () => startCompanion(true))
  orca.commands.register('orca-island.open', () => startCompanion(true))
}
