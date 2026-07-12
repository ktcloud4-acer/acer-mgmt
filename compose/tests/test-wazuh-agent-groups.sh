#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
k8s_conf="$ROOT_DIR/compose/stacks/security/wazuh/config/agent.conf.k8s-nodes"
default_conf="$ROOT_DIR/compose/stacks/security/wazuh/config/agent.conf"
apply="$ROOT_DIR/compose/scripts/apply-wazuh-agent-groups.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() {
  [[ -f "$1" ]] || fail "missing file: $1"
  grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

# k8s-nodes 그룹 FIM: Kubernetes 컨트롤플레인 비밀이 FIM 에서 제외돼야 한다
assert_contains "$k8s_conf" "<ignore>/etc/kubernetes/pki</ignore>"
assert_contains "$k8s_conf" "^/etc/kubernetes/.*\\.conf$"
assert_contains "$k8s_conf" "<ignore>/var/lib/etcd</ignore>"
assert_contains "$k8s_conf" "kubernetes\\.io~secret"
# 마운트된 Secret 내용 diff 도 금지
assert_contains "$k8s_conf" "<nodiff>/etc/kubernetes/pki</nodiff>"
# 일반 자격증명 경로(kubeconfig)도 제외
assert_contains "$k8s_conf" "<ignore>/home/*/.kube</ignore>"

# 적용 스크립트가 두 그룹을 모두 push 하는지
assert_contains "$apply" "agent.conf.k8s-nodes"
assert_contains "$apply" "k8s-nodes"
assert_contains "$apply" "/var/ossec/etc/shared/"
# default 그룹도 계속 적용
assert_contains "$apply" "config/agent.conf"

# k8s-nodes 설정이 유효한 XML 인지(닫힘 태그)
grep -q "</agent_config>" "$k8s_conf" || fail "k8s-nodes agent.conf not closed"

echo "wazuh agent groups tests passed"
