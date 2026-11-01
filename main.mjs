import { createCompanionManager } from './lib/companion-manager.mjs'

const DEFAULT_ENDPOINT = 'http://127.0.0.1:17777/events'
const MAX_PENDING = 20
const MAX_TRACKED = 1000
const REQUEST_TIMEOUT_MS = 1000

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
  maxTracked = MAX_TRACKED
} = {}) {
  if (!Number.isInteger(maxPending) || maxPending < 1
      || !Number.isInteger(maxTracked) || maxTracked < 1) {
    throw new RangeError('Relay queue and success-cache limits must be positive integers')
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
    lastSuccessful.set(key, fingerprint)
    if (lastSuccessful.size > maxTracked) {
      lastSuccessful.delete(lastSuccessful.keys().next().value)
    }
  }

  async function drain() {
    while (pending.length > 0) {
      const event = pending.shift()
      const sentPayload = event.payload
      inFlight = event
      try {
        await post(sentPayload)
        rememberSuccess(event.key, event.fingerprint)
        // HTTP serialization has already happened. Coalesce duplicates received
        // during the request into one later update with the latest timestamp.
        // A queued transition for this pane supersedes that same-state refresh.
        if (event.payload.receivedAt > sentPayload.receivedAt
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

  return {
    handle(payload) {
      const key = eventKey(payload)
      const state = eventState(payload)
      const mainState = payload?.mainAgent?.state ?? null
      const fingerprint = `${state}:${mainState}`
      const normalized = {
        type: 'orca.agent.status',
        workspaceId: payload?.workspaceId ?? null,
        paneKey: payload?.paneKey ?? null,
        state,
        combinedState: payload?.state ?? state,
        mainAgent: payload?.mainAgent ?? null,
        receivedAt: payload?.receivedAt ?? Date.now()
      }
      // Inspect the latest queued transition, not any earlier matching state:
      // working -> done -> working must remain three ordered transitions.
      const latest = pending.findLast((event) => event.key === key)
        ?? (inFlight?.key === key ? inFlight : null)
      if (latest?.fingerprint === fingerprint) {
        if (normalized.receivedAt > latest.payload.receivedAt) latest.payload = normalized
        return 'duplicate'
      }
      if (!latest && lastSuccessful.get(key) === fingerprint) {
        rememberSuccess(key, fingerprint)
        return 'duplicate'
      }
      enqueue({ key, fingerprint, payload: normalized })
      startDrain()
      return 'queued'
    },
    async sendTest() {
      const payload = {
        type: 'orca.test',
        workspaceId: null,
        paneKey: null,
        state: 'waiting',
        combinedState: 'waiting',
        mainAgent: null,
        receivedAt: Date.now()
      }
      await post(payload)
      return 'sent'
    },
    async idle() {
      while (draining) await draining
    }
  }
}

export default function activate(orca, { companionManager = createCompanionManager({ log: (line) => orca.log(line) }) } = {}) {
  const relay = createRelay({ log: (line) => orca.log(line) })

  // Orca kills workers that keep too many events unacknowledged. Queue delivery
  // and return immediately from the event handler.
  orca.events.on('agent.status.changed', (payload) => {
    relay.handle(payload)
  })

  orca.commands.register('orca-island.send-test', () => relay.sendTest())

  // Startup is deliberately fire-and-forget: plugin activation must remain
  // responsive while the companion is checked or installed in the background.
  void companionManager.ensure()
  orca.commands.register('orca-island.install-start', () => companionManager.ensure({ retry: true }))
  orca.commands.register('orca-island.open', () => companionManager.ensure({ retry: true }))
}
