#!/usr/bin/env bash
# 부팅 후 의존성(tailscale IP, harbor-log)이 준비되면 멈춰있는 스택을 수렴 복구한다.
#
# 배경: docker 데몬이 tailscaled / harbor-log 보다 먼저 떠서, 부팅 시 컨테이너 복구가
#   - elk·gitlab : tailnet IP 미할당 → "cannot assign requested address" (Exit 137)
#   - harbor     : harbor-log(syslog:1514) 미기동 → "connection refused"   (Exit 128)
# 으로 1회 실패한 뒤 docker 가 재시도를 포기(restartCount=1)해 계속 멈춰있게 된다.
# 이 스크립트는 의존성이 준비된 뒤 "한 번 수렴"시키는 역할이며 멱등하다.
set -uo pipefail
log(){ echo "[boot-reconcile] $*"; }

# compose root 결정: 환경변수 > repo 내 실행(스크립트 상대) > 기본값.
# systemd 는 SELinux 때문에 /usr/local/sbin(bin_t)에 설치된 사본을 실행하므로
# 스크립트 위치로 repo 를 추정할 수 없다 → ACER_MGMT_REPO 로 주입한다.
if [[ -n "${ACER_MGMT_REPO:-}" ]]; then
  REPO="${ACER_MGMT_REPO}"
elif [[ -f "$(dirname "$0")/../Makefile" ]]; then
  REPO="$(cd "$(dirname "$0")/.." && pwd)"
else
  REPO="/home/user1/acer-mgmt/compose"
fi
cd "${REPO}" || { log "FATAL: repo root 접근 불가: ${REPO}"; exit 1; }
log "repo: ${REPO}"

# 1) tailscale0 에 IPv4 가 실제로 붙을 때까지 대기 (서비스 active != IP 할당 완료)
TS_IP=""
for _ in $(seq 1 60); do
  TS_IP="$(tailscale ip -4 2>/dev/null | head -n1)"
  if [[ -n "${TS_IP}" ]] && ip -4 addr show tailscale0 2>/dev/null | grep -q "${TS_IP}"; then
    log "tailscale up: ${TS_IP}"; break
  fi
  TS_IP=""; sleep 2
done
[[ -z "${TS_IP}" ]] && log "WARN: tailscale IP 미할당(타임아웃) — tailnet bind 스택이 실패할 수 있음"

# 2) TAILSCALE_IP 에 바인딩하는 repo 스택만 자동 탐지해 멱등 기동 (현재: elk, gitlab)
mapfile -t TS_STACKS < <(grep -rlE '\$\{?TAILSCALE_IP' stacks/*/*/compose.yaml 2>/dev/null \
                          | sed -E 's#^stacks/##; s#/compose.yaml$##')
for s in "${TS_STACKS[@]}"; do
  log "compose up: ${s}"
  make up s="${s}" || log "WARN: up ${s} 실패"
done

# 3) harbor: 설치 생성본이 스텁(services:{})으로 대체돼 있어 'compose up' 으로는 복구 불가.
#    (compose 가 서비스를 삭제하려 듦) → 기존 컨테이너를 순서대로 start 한다.
#    harbor-log(syslog 1514)가 먼저 떠 있어야 나머지가 로깅 드라이버 초기화에 성공한다.
if docker inspect harbor-log >/dev/null 2>&1; then
  docker start harbor-log >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do                                   # 127.0.0.1:1514 리스닝 대기
    (exec 3<>/dev/tcp/127.0.0.1/1514) 2>/dev/null && { exec 3>&-; break; }
    sleep 1
  done
  while read -r c; do
    [[ "${c}" == "harbor-log" ]] && continue
    docker start "${c}" >/dev/null 2>&1 || log "WARN: start ${c} 실패"
  done < <(docker ps -a --filter "label=com.docker.compose.project=harbor" --format '{{.Names}}')
  log "harbor 컨테이너 복구 완료"
else
  log "harbor 프로젝트 없음 — 건너뜀"
fi

log "done"
