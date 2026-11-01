const response = await fetch('http://127.0.0.1:17777/events', {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({
    type: 'orca.test',
    workspaceId: 'local-test',
    paneKey: 'test-tab:test-leaf',
    state: 'working',
    combinedState: 'working',
    mainAgent: null,
    receivedAt: Date.now()
  })
})

if (!response.ok) {
  throw new Error(`Companion returned HTTP ${response.status}`)
}

console.log('sent test event to Orca Island')
