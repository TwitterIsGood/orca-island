const DEFAULT_ENDPOINT = 'http://127.0.0.1:17777/events'
const MAX_PENDING = 20
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
  maxPending = MAX_PENDING
} = {}) {
  const lastStates = new Map()
  const pending = []
  let draining = null

  async function drain() {
    while (pending.length > 0) {
      const payload = pending.shift()
      try {
        await post(payload)
      } catch (error) {
        log(`relay failed: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
    draining = null
  }

  return {
    handle(payload) {
      const key = eventKey(payload)
      const state = eventState(payload)
      const mainState = payload?.mainAgent?.state ?? null
      const fingerprint = `${state}:${mainState}`
      if (lastStates.get(key) === fingerprint) {
        return 'duplicate'
      }
      lastStates.set(key, fingerprint)
      pending.push({
        type: 'orca.agent.status',
        workspaceId: payload?.workspaceId ?? null,
        paneKey: payload?.paneKey ?? null,
        state,
        combinedState: payload?.state ?? state,
        mainAgent: payload?.mainAgent ?? null,
        receivedAt: payload?.receivedAt ?? Date.now()
      })
      if (pending.length > maxPending) {
        pending.shift()
        log(`relay queue dropped the oldest event (limit ${maxPending})`)
      }
      draining ??= drain()
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
    idle() {
      return draining ?? Promise.resolve()
    }
  }
}

export default function activate(orca) {
  const relay = createRelay({ log: (line) => orca.log(line) })

  // Orca kills workers that keep too many events unacknowledged. Queue delivery
  // and return immediately from the event handler.
  orca.events.on('agent.status.changed', (payload) => {
    relay.handle(payload)
  })

  orca.commands.register('orca-island.send-test', () => relay.sendTest())
}
