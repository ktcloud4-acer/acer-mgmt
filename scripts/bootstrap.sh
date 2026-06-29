#!/usr/bin/env bash
# acer-mgmt 부트스트랩 — Rocky Linux 9 호스트에서 Docker 설치 후 1회 실행
set -euo pipefail

PROXY_NET="${PROXY_NET:-mgmt-proxy}"
DATA_ROOT="${DATA_ROOT:-/home/mgmt-data}"

echo "[1/4] 공용 외부 네트워크: ${PROXY_NET}"
docker network inspect "${PROXY_NET}" >/dev/null 2>&1 \
  || docker network create "${PROXY_NET}"

echo "[2/4] 커널 파라미터 (Elasticsearch / SonarQube 요구치)"
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-mgmt.conf >/dev/null

echo "[3/4] 데이터 루트 준비: ${DATA_ROOT}"
sudo mkdir -p "${DATA_ROOT}"
sudo chown "$(id -u):$(id -g)" "${DATA_ROOT}"

echo "[4/4] SELinux 컨텍스트 부여 (Enforcing)"
if command -v semanage >/dev/null 2>&1; then
  sudo semanage fcontext -a -t container_file_t "${DATA_ROOT}(/.*)?" 2>/dev/null || true
  sudo restorecon -R "${DATA_ROOT}" || true
else
  echo "  semanage 없음 → 'sudo dnf install -y policycoreutils-python-utils' 후 재실행 권장"
fi

echo "완료. 다음 단계:  make up s=edge/traefik"
