#!/usr/bin/env bash
set -euo pipefail

for argument in "$@"; do
  case "$argument" in
    K6_RATE=*) export K6_RATE="${argument#K6_RATE=}" ;;
    K6_DURATION=*) export K6_DURATION="${argument#K6_DURATION=}" ;;
    *) echo "only K6_RATE and K6_DURATION may be overridden" >&2; exit 2 ;;
  esac
done

: "${K6_TEAM:?K6_TEAM must be set by the team project}"
: "${K6_BASE_URL:?K6_BASE_URL must be set by the team project}"
case "$K6_TEAM" in ggg|khb|ljw|nmg|oje) ;; *) echo "unsupported K6_TEAM" >&2; exit 2 ;; esac
case "${K6_RATE:-150}" in *[!0-9]*|'') echo "K6_RATE must be a positive integer" >&2; exit 2 ;; esac
case "${K6_DURATION:-4m}" in *[!0-9smh]*|'') echo "K6_DURATION must use seconds, minutes, or hours" >&2; exit 2 ;; esac

key_file="${K6_KEY_FILE_ROOT:-/run/vault-k6}/${K6_TEAM}.env"
[[ -r "$key_file" ]] || { echo "Vault-rendered k6 key is unavailable" >&2; exit 2; }
set -a
# shellcheck disable=SC1090
. "$key_file"
set +a

: "${K6_DEMO_API_KEY:?K6_DEMO_API_KEY is missing from the Vault-rendered key file}"
exec ./compose/scripts/k6/run-scalecart-api-hpa.sh
