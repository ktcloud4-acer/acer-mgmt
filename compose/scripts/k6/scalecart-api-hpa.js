import http from 'k6/http'
import { check } from 'k6'

const baseUrl = String(__ENV.K6_BASE_URL || '').replace(/\/+$/, '')
const demoApiKey = String(__ENV.K6_DEMO_API_KEY || '')
const targetRate = Number(__ENV.K6_RATE || 150)
const holdDuration = __ENV.K6_DURATION || '4m'

export const options = {
  scenarios: {
    api_hpa_ramp: {
      executor: 'ramping-arrival-rate',
      startRate: 20,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 300,
      stages: [
        { target: targetRate, duration: '2m' },
        { target: targetRate, duration: holdDuration },
        { target: 0, duration: '30s' },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{name:demo-state}': ['p(95)<1000'],
    checks: ['rate>0.99'],
  },
}

export default function () {
  const response = http.get(`${baseUrl}/api/demo/state`, {
    headers: { 'X-K6-Demo-Key': demoApiKey },
    tags: { name: 'demo-state' },
  })

  check(response, {
    'demo state returns 200': (result) => result.status === 200,
  })
}
