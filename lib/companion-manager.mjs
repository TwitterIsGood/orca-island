import { createHash } from 'node:crypto'
import { execFile } from 'node:child_process'
import * as fs from 'node:fs/promises'
import { homedir } from 'node:os'
import path from 'node:path'
import { promisify } from 'node:util'

export const RELEASE_VERSION = '0.2.0'
export const RELEASE_ARCHIVE = 'OrcaIsland-macos-universal.zip'
const RELEASE_BASE = `https://github.com/TwitterIsGood/orca-island/releases/download/v${RELEASE_VERSION}`
const BUNDLE_ID = 'dev.orca.island'
const HEALTH_URL = 'http://127.0.0.1:17777/health'
const MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
const LOCK_STALE_MS = 10 * 60 * 1000
const execute = promisify(execFile)
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function message(error) {
  return error instanceof Error ? error.message : String(error)
}

async function exists(file) {
  try {
    await fs.lstat(file)
    return true
  } catch (error) {
    if (error.code === 'ENOENT') return false
    throw error
  }
}

export function expectedChecksum(text, filename = RELEASE_ARCHIVE) {
  const matches = text.split(/\r?\n/).flatMap((line) => {
    const match = line.match(/^([a-fA-F0-9]{64}) [ *](.+)$/)
    return match?.[2] === filename ? [match[1].toLowerCase()] : []
  })
  if (matches.length !== 1) throw new Error(`SHA256SUMS must contain exactly one checksum for ${filename}`)
  return matches[0]
}

// Stream to a private staging directory, with a bound on both bytes and time.
// Only the pinned GitHub release URLs below are passed here by the installer.
export async function downloadFile(url, destination, {
  maxBytes,
  timeoutMs,
  fetchImpl = globalThis.fetch
}) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  let output
  try {
    const response = await fetchImpl(url, { signal: controller.signal, redirect: 'follow' })
    if (!response.ok) throw new Error(`Download failed: HTTP ${response.status} (${url})`)
    const contentLength = Number(response.headers.get('content-length'))
    if (contentLength > maxBytes) throw new Error(`Download exceeds ${maxBytes} bytes`)
    if (!response.body) throw new Error('Download response has no body')
    output = await fs.open(destination, 'wx', 0o600)
    const hash = createHash('sha256')
    let size = 0
    for await (const chunk of response.body) {
      size += chunk.byteLength
      if (size > maxBytes) throw new Error(`Download exceeds ${maxBytes} bytes`)
      hash.update(chunk)
      await output.writeFile(chunk)
    }
    if (size === 0) throw new Error('Downloaded file is empty')
    return hash.digest('hex')
  } finally {
    clearTimeout(timer)
    await output?.close()
  }
}

export function validateArchiveEntries(listing, modes) {
  const entries = listing.split(/\r?\n/).filter(Boolean)
  if (entries.length === 0) throw new Error('Release archive is empty')
  for (const entry of entries) {
    const parts = entry.split('/')
    if (entry.includes('\\') || parts.includes('..') || parts.includes('.') ||
        !['OrcaIsland.app', '__MACOSX'].includes(parts[0])) {
      throw new Error(`Unexpected archive path: ${entry}`)
    }
  }
  // The standalone Swift companion has no symlinks. Reject them before ditto
  // extracts, so an archive cannot redirect a subsequent entry outside staging.
  // `unzip -Z -v` prints Unix mode 012xxxx for symbolic links. The archive
  // is extracted only after this check; `ditto` must never receive a link.
  if (/Unix file attributes \(0?12[0-7]{4} octal\)/i.test(modes)) {
    throw new Error('Release archive must not contain symbolic links')
  }
  if (!entries.includes('OrcaIsland.app/Contents/Info.plist')) {
    throw new Error('Release archive does not contain OrcaIsland.app/Contents/Info.plist')
  }
}

export function createSystemAdapter({
  homeDirectory = homedir(),
  fetchImpl = globalThis.fetch,
  run = (file, args) => execute(file, args, { timeout: 30_000, maxBuffer: 2 * 1024 * 1024 }),
  now = Date.now,
  sleep = delay
} = {}) {
  const supportDirectory = path.join(homeDirectory, 'Library', 'Application Support', 'Orca Island')
  const applicationsDirectory = path.join(homeDirectory, 'Applications')
  const userApp = path.join(applicationsDirectory, 'OrcaIsland.app')
  const attemptFile = path.join(supportDirectory, `companion-attempt-v${RELEASE_VERSION}.json`)
  const lockDirectory = path.join(supportDirectory, 'companion-install.lock')

  async function isHealthy() {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 800)
    try {
      const response = await fetchImpl(HEALTH_URL, { signal: controller.signal })
      return response.ok && (await response.text()).trim() === 'ok'
    } catch {
      return false
    } finally {
      clearTimeout(timer)
    }
  }

  async function validateBundle(app) {
    const { stdout } = await run('/usr/bin/plutil', ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', path.join(app, 'Contents', 'Info.plist')])
    if (stdout.trim() !== BUNDLE_ID) throw new Error(`Unexpected application bundle identifier at ${app}`)
    await run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app])
  }

  return {
    isHealthy,
    async acquireLock() {
      await fs.mkdir(supportDirectory, { recursive: true, mode: 0o700 })
      try {
        await fs.mkdir(lockDirectory, { mode: 0o700 })
      } catch (error) {
        if (error.code !== 'EEXIST') throw error
        const stat = await fs.stat(lockDirectory).catch(() => null)
        if (!stat || now() - stat.mtimeMs < LOCK_STALE_MS) return null
        // A timed-out/crashed worker leaves no long-lived retry loop. A later
        // manual invocation can reclaim its old lock after the operation bound.
        try {
          await fs.rmdir(lockDirectory)
          await fs.mkdir(lockDirectory, { mode: 0o700 })
        } catch (error) {
          if (['ENOENT', 'EEXIST', 'ENOTEMPTY'].includes(error.code)) return null
          throw error
        }
      }
      return async () => { await fs.rmdir(lockDirectory).catch(() => {}) }
    },
    async hasAttempted() {
      return exists(attemptFile)
    },
    async recordAttempt() {
      await fs.writeFile(attemptFile, JSON.stringify({ version: RELEASE_VERSION, attemptedAt: now() }), { mode: 0o600 })
    },
    async findInstalled() {
      for (const app of [userApp, '/Applications/OrcaIsland.app']) {
        if (await exists(app)) {
          await validateBundle(app)
          return app
        }
      }
      return null
    },
    async install() {
      await fs.mkdir(applicationsDirectory, { recursive: true })
      const staging = await fs.mkdtemp(path.join(applicationsDirectory, '.orca-island-install-'))
      try {
        const sumsPath = path.join(staging, 'SHA256SUMS')
        await downloadFile(`${RELEASE_BASE}/SHA256SUMS`, sumsPath, {
          maxBytes: 64 * 1024, timeoutMs: 15_000, fetchImpl
        })
        const expected = expectedChecksum(await fs.readFile(sumsPath, 'utf8'))
        const archive = path.join(staging, RELEASE_ARCHIVE)
        const actual = await downloadFile(`${RELEASE_BASE}/${RELEASE_ARCHIVE}`, archive, {
          maxBytes: MAX_ARCHIVE_BYTES, timeoutMs: 120_000, fetchImpl
        })
        if (actual !== expected) throw new Error('Release archive SHA-256 checksum does not match SHA256SUMS')
        const { stdout: listing } = await run('/usr/bin/unzip', ['-Z', '-1', archive])
        const { stdout: modes } = await run('/usr/bin/unzip', ['-Z', '-v', archive])
        validateArchiveEntries(listing, modes)
        const extracted = path.join(staging, 'extracted')
        await run('/usr/bin/ditto', ['-x', '-k', archive, extracted])
        const stagedApp = path.join(extracted, 'OrcaIsland.app')
        await validateBundle(stagedApp)
        if (await exists(userApp)) throw new Error(`Application already exists at ${userApp}; it was not replaced`)
        // Staging is on the destination volume, so the complete, verified app
        // appears atomically. No user configuration or quarantine is modified.
        await fs.rename(stagedApp, userApp)
        return userApp
      } finally {
        await fs.rm(staging, { recursive: true, force: true })
      }
    },
    async launch(app) {
      await run('/usr/bin/open', ['-g', app])
    },
    async waitForHealth() {
      for (let attempt = 0; attempt < 12; attempt++) {
        if (await isHealthy()) return true
        await sleep(500)
      }
      return false
    }
  }
}

export function createCompanionManager({
  platform = process.platform,
  adapter = createSystemAdapter(),
  log = () => {}
} = {}) {
  let inFlight = null
  let automaticAttempted = false

  async function start({ retry }) {
    if (platform !== 'darwin') return { status: 'unsupported', message: 'Orca Island requires macOS 13 or newer.' }
    if (await adapter.isHealthy()) return { status: 'running' }
    const release = await adapter.acquireLock()
    if (!release) return { status: 'busy', message: 'Another Orca worker is preparing Orca Island.' }
    try {
      if (await adapter.isHealthy()) return { status: 'running' }
      if (!retry && await adapter.hasAttempted()) {
        return { status: 'skipped', message: 'Already attempted this version. Run Orca Island: Install & Start to retry.' }
      }
      try {
        let app = await adapter.findInstalled()
        const installed = !app
        if (!app) {
          log(`Installing Orca Island ${RELEASE_VERSION} from the GitHub release…`)
          app = await adapter.install()
        }
        await adapter.launch(app)
        if (!await adapter.waitForHealth()) {
          throw new Error('Orca Island did not become ready. Open the app in ~/Applications, then run Orca Island: Install & Start to retry.')
        }
        return { status: 'running', installed, app }
      } catch (error) {
        // Persist only a failed operation. A healthy app that later exits may
        // be relaunched by a new worker; failed automatic attempts need a
        // deliberate command before they can retry.
        try {
          await adapter.recordAttempt()
        } catch (recordError) {
          log(`Could not persist the failed install attempt: ${message(recordError)}`)
        }
        throw error
      }
    } finally {
      await release()
    }
  }

  return {
    ensure({ retry = false } = {}) {
      if (inFlight) return inFlight
      if (!retry && automaticAttempted) return Promise.resolve({ status: 'skipped' })
      automaticAttempted = true
      inFlight = start({ retry }).catch((error) => ({ status: 'failed', message: message(error) })).then((result) => {
        log(result.status === 'running'
          ? 'Orca Island is ready.'
          : `Orca Island: ${result.message ?? result.status}`)
        return result
      }).finally(() => { inFlight = null })
      return inFlight
    }
  }
}
