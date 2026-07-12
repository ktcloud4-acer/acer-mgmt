#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Wazuh 에이전트 그룹 공유 FIM(agent.conf)을 매니저에 idempotent 하게 push 한다.
# 그룹별로 비밀 경로를 FIM 밖으로 두어 감사 저장소에 비밀이 유입되지 않게 한다.
#
#   default   ← config/agent.conf            (acer-mgmt / acer-aio 호스트)
#   k8s-nodes ← config/agent.conf.k8s-nodes  (kubeadm master/worker 노드)
#
# acer-mgmt 에서 매니저가 healthy 한 뒤 실행. 매니저 remoted 가 shared config 를
# 병합해 각 그룹 에이전트에 자동 배포한다(재시작 불필요).
# 재실행 안전: 그룹 생성은 || true, agent.conf 배치는 덮어쓰기.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

WAZUH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../stacks/security/wazuh" && pwd)"
MGR="${WAZUH_MANAGER_CONTAINER:-wazuh-manager}"

docker ps --format '{{.Names}}' | grep -qx "$MGR" || { echo "FAIL: $MGR 컨테이너 없음/미기동" >&2; exit 1; }

apply_group() {
  local group="$1" file="$2"
  [[ -f "$file" ]] || { echo "FAIL: 설정 파일 없음: $file" >&2; exit 1; }
  # 그룹 생성(이미 있으면 무시). shared 디렉토리 자체로도 그룹이 인식되나, 명시 생성.
  docker exec "$MGR" /var/ossec/bin/agent_groups -a -g "$group" -q >/dev/null 2>&1 || true
  docker exec "$MGR" mkdir -p "/var/ossec/etc/shared/$group"
  docker exec -i "$MGR" tee "/var/ossec/etc/shared/$group/agent.conf" >/dev/null < "$file"
  docker exec "$MGR" chown -R wazuh:wazuh "/var/ossec/etc/shared/$group" 2>/dev/null || true
  echo "  applied: $group <- $(basename "$file")"
}

echo "== Wazuh 그룹 FIM 적용 =="
apply_group default   "$WAZUH_DIR/config/agent.conf"
apply_group k8s-nodes "$WAZUH_DIR/config/agent.conf.k8s-nodes"

echo "완료. 각 그룹 에이전트는 다음 동기화 때 병합된 config 를 받는다."
echo "확인:  docker exec $MGR /var/ossec/bin/agent_groups -l"
