import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'

const scenarioPath = 'compose/scripts/k6/scalecart-api-hpa.js'
const runnerPath = 'compose/scripts/k6/run-scalecart-api-hpa.sh'

assert.equal(existsSync(scenarioPath), true, `Missing ${scenarioPath}`)
assert.equal(existsSync(runnerPath), true, `Missing ${runnerPath}`)

const scenario = readFileSync(scenarioPath, 'utf8')
const runner = readFileSync(runnerPath, 'utf8')

assert.match(scenario, /ramping-arrival-rate/)
assert.match(scenario, /http_req_failed/)
assert.match(scenario, /http_req_duration\{name:demo-state\}/)
assert.match(scenario, /\/api\/demo\/state/)
assert.match(scenario, /Authorization.*Bearer/)
assert.match(runner, /K6_ACCESS_TOKEN/)
assert.match(runner, /k6 run compose\/scripts\/k6\/scalecart-api-hpa\.js/)
