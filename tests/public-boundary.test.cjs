'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const root = path.join(__dirname, '..')
const read = file => fs.readFileSync(path.join(root, file), 'utf8')

function productionSources(directory) {
  return fs.readdirSync(path.join(root, directory), { withFileTypes: true }).flatMap(entry => {
    const relative = path.join(directory, entry.name)
    if (entry.isDirectory()) return productionSources(relative)
    return /\.(swift|mjs)$/.test(entry.name) ? [relative] : []
  })
}

test('production state collection does not import Orca internals or inspect its profile storage', () => {
  const forbidden = /app\.asar|\bRuntimeClient\b|node:sqlite|profile_state_documents|workspaceSessionsByHostId|session\.tabs\.listAll|['"]ui\.get['"]/
  for (const file of ['main.mjs', ...productionSources('lib'), ...productionSources('companion/Sources')]) {
    assert.doesNotMatch(read(file), forbidden, file)
  }
})

test('companion packages no private JavaScript snapshot helper', () => {
  assert.equal(fs.existsSync(path.join(root, 'scripts/orca-snapshot.cjs')), false)
  assert.equal(fs.existsSync(path.join(root, 'scripts/orca-projection.cjs')), false)
  assert.doesNotMatch(read('scripts/build-companion.sh'), /cp .*\.cjs/)
  assert.doesNotMatch(read('companion/Sources/OrcaIsland/OrcaCommandRunner.swift'), /runHelper|MacOS\/Orca|nodeMode/)
})

test('plugin migration does not request transcript, launch or terminal-send access', () => {
  const manifest = JSON.parse(read('orca-plugin.json'))
  assert.deepEqual(manifest.capabilities.map(c => c.kind).sort(), ['agent:read', 'workspace:read'])
  assert.equal(manifest.pluginApi, 1)
  assert.equal(manifest.engines.orca, '>=1.4.260')
  assert.ok(manifest.contributes.events.some(event => event.on === 'workspace.changed'))
})

test('native navigation never resumes an agent or uses private reveal RPCs', () => {
  const source = read('companion/Sources/OrcaIsland/TerminalSwitcher.swift')
  assert.doesNotMatch(source, /agentSession\.reveal|terminal\.reveal|['"]resume['"]|runHelper/)
  assert.match(source, /['"]switch['"]/)
})
