import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'

const scenarioPath = 'compose/scripts/k6/scalecart-api-hpa.js'
const runnerPath = 'compose/scripts/k6/run-scalecart-api-hpa.sh'
const dashboardPath = 'compose/stacks/observability/grafana/dashboards/Monitoring/scalecart_api_hpa_load_demo.json'
const recordingRulesPath = 'compose/stacks/observability/prometheus/config/alerts/scalecart-slo.yml'

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

assert.equal(existsSync(dashboardPath), true, `Missing ${dashboardPath}`)

const dashboard = JSON.parse(readFileSync(dashboardPath, 'utf8'))
const dashboardJson = JSON.stringify(dashboard)
const recordingRules = readFileSync(recordingRulesPath, 'utf8')

assert.equal(dashboard.uid, 'scalecart-api-hpa-load-demo')
assert.equal(dashboard.title, 'ScaleCart API HPA Load Demo')
assert.match(dashboardJson, /scalecart:api_requests:rate1m/)
assert.match(dashboardJson, /scalecart:api_latency:p95_1m/)
assert.match(dashboardJson, /kube_horizontalpodautoscaler_status_desired_replicas/)
assert.match(recordingRules, /record: scalecart:api_requests:rate1m/)
assert.match(recordingRules, /record: scalecart:api_latency:p95_1m/)
