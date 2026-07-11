#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../versions.env
source "${ROOT}/versions.env"

grep -Fq "image: rancher/k3s:${K3S_VERSION}" "${ROOT}/config.yaml"
grep -Fq 'name: nofile' "${ROOT}/config.yaml"
grep -Fq 'soft: 65535' "${ROOT}/config.yaml"
grep -Fq 'hard: 65535' "${ROOT}/config.yaml"
grep -Fq "/${ARGOCD_VERSION}/manifests/install.yaml" \
  "${ROOT}/bootstrap/argocd/kustomization.yaml"

command -v k3d >/dev/null
k3d config migrate "${ROOT}/config.yaml" >/dev/null

echo "설정 검증 완료: k3d=${K3D_VERSION}, k3s=${K3S_VERSION}, argocd=${ARGOCD_VERSION}"
