#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dns_script="$ROOT_DIR/compose/scripts/configure-redisinsight-dns.sh"
dns_smoke="$ROOT_DIR/compose/ansible/dns-smoke-test.yml"
dashy_config="$ROOT_DIR/compose/stacks/edge/dashy/config/conf.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }

for file in "$dns_script" "$dns_smoke" "$dashy_config"; do
  [[ -f "$file" ]] || fail "missing file: $file"
done

[[ -x "$dns_script" ]] || fail "expected executable script: $dns_script"
assert_contains "$dns_script" 'domain="redis.${BASE_DOMAIN}"'
assert_contains "$dns_script" 'docker restart adguard'
assert_contains "$dns_smoke" '      - redis'
assert_contains "$dashy_config" 'title: RedisInsight'
assert_contains "$dashy_config" 'url: https://redis.imcherry5778.xyz'

echo 'redisinsight publication tests passed'
