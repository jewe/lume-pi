// Dependency-free screen control HTTP service.
//
// Endpoints:
// - POST /screen/off
// - POST /screen/on
//
// Listens on 127.0.0.1:3333

const http = require('http')
const { spawnSync } = require('child_process')

const HOST = '127.0.0.1'
const PORT = 3333

const DISPLAY_CONTROL_BIN = '/usr/local/bin/lume-display-control'

function json(res, statusCode, payload) {
  const body = JSON.stringify(payload)
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
  })
  res.end(body)
}

function runDisplayControl(args) {
  // We intentionally call the same helper installed by setup-screen-control.sh
  // so this service does not need to know about ddcutil/underlying mechanisms/etc.
  const env = { ...process.env }

  // Ensure non-interactive, with a predictable PATH.
  env.PATH = env.PATH || '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

  const result = spawnSync(DISPLAY_CONTROL_BIN, args, { env, encoding: 'utf8' })
  if (result.error) throw result.error
  if (result.status !== 0) {
    const stderr = (result.stderr || '').trim()
    throw new Error(`lume-display-control failed (exit ${result.status}): ${stderr}`)
  }
}

const server = http.createServer((req, res) => {
  const method = req.method || ''
  const url = req.url || ''

  if (method !== 'POST') {
    return json(res, 405, { error: 'method_not_allowed' })
  }

  if (url === '/screen/off') {
    try {
      runDisplayControl(['off'])
      return json(res, 200, { status: 'off' })
    } catch (e) {
      return json(res, 500, { error: 'display_control_failed', message: String(e && e.message ? e.message : e) })
    }
  }

  if (url === '/screen/on') {
    try {
      runDisplayControl(['on'])
      return json(res, 200, { status: 'on' })
    } catch (e) {
      return json(res, 500, { error: 'display_control_failed', message: String(e && e.message ? e.message : e) })
    }
  }

  return json(res, 404, { error: 'not_found' })
})

server.listen(PORT, HOST, () => {
  // eslint-disable-next-line no-console
  console.log(`screen-control service listening on http://${HOST}:${PORT}`)
})
