#!/usr/bin/env sh
set -eu

require_value() {
  variable_name="$1"
  eval "variable_value=\${$variable_name:-}"
  if [ -z "$variable_value" ]; then
    echo "${variable_name} must be set" >&2
    exit 2
  fi
}

require_value K6_BASE_URL
require_value K6_DEMO_API_KEY

echo "Starting ScaleCart API HPA load test"
echo "  target: ${K6_BASE_URL}"
echo "  rate: ${SCALECART_K6_RATE:-150} requests/second"
echo "  hold: ${SCALECART_K6_HOLD_DURATION:-4m}"

exec k6 run compose/scripts/k6/scalecart-api-hpa.js
