#!/usr/bin/env bash

require_env_file() {
  local file="$1"
  local label="${2:-env}"

  if [[ ! -f "$file" ]]; then
    echo "Missing ${label} file: ${file}" >&2
    return 1
  fi
}

get_env_value() {
  local file="$1"
  local key="$2"
  local value

  require_env_file "$file" "$key env" || return 1
  value="$(grep -m1 "^${key}=" "$file" | cut -d= -f2- || true)"
  if [[ -z "$value" ]]; then
    echo "Missing ${key} in ${file}" >&2
    return 1
  fi
  printf '%s' "$value"
}
