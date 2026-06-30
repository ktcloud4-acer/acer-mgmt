#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../versions.env
source "${ROOT}/versions.env"

BIN_DIR="${HOME}/.local/bin"
mkdir -p "${BIN_DIR}"

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "지원하지 않는 아키텍처: $(uname -m)" >&2; exit 1 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

install_k3d() {
  if command -v k3d >/dev/null 2>&1 \
    && [[ "$(k3d version -o json 2>/dev/null | jq -r .k3d)" == "${K3D_VERSION}" ]]; then
    return
  fi

  local asset="k3d-linux-${ARCH}"
  local base="https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}"
  curl -fsSL "${base}/${asset}" -o "${tmp}/${asset}"
  curl -fsSL "${base}/checksums.txt" -o "${tmp}/k3d-checksums.txt"
  local expected
  expected="$(awk -v name="_dist/${asset}" '$2 == name {print $1}' "${tmp}/k3d-checksums.txt")"
  [[ -n "${expected}" ]]
  echo "${expected}  ${tmp}/${asset}" | sha256sum -c -
  install -m 0755 "${tmp}/${asset}" "${BIN_DIR}/k3d"
}

install_kubectl() {
  if command -v kubectl >/dev/null 2>&1 && [[ "$(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion)" == "${KUBECTL_VERSION}" ]]; then
    return
  fi

  local base="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}"
  curl -fsSL "${base}/kubectl" -o "${tmp}/kubectl"
  curl -fsSL "${base}/kubectl.sha256" -o "${tmp}/kubectl.sha256"
  echo "$(cat "${tmp}/kubectl.sha256")  ${tmp}/kubectl" | sha256sum -c -
  install -m 0755 "${tmp}/kubectl" "${BIN_DIR}/kubectl"
}

install_argocd() {
  if command -v argocd >/dev/null 2>&1 && [[ "$(argocd version --client --short 2>/dev/null)" == *"${ARGOCD_VERSION}"* ]]; then
    return
  fi

  local asset="argocd-linux-${ARCH}"
  local base="https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}"
  curl -fsSL "${base}/${asset}" -o "${tmp}/argocd"
  curl -fsSL "${base}/cli_checksums.txt" -o "${tmp}/argocd-checksums.txt"
  local expected
  expected="$(awk -v name="${asset}" '$2 == name {print $1}' "${tmp}/argocd-checksums.txt")"
  [[ -n "${expected}" ]]
  echo "${expected}  ${tmp}/argocd" | sha256sum -c -
  install -m 0755 "${tmp}/argocd" "${BIN_DIR}/argocd"
}

command -v curl >/dev/null
command -v jq >/dev/null
install_k3d
install_kubectl
install_argocd

echo "k3d:    $(k3d version -o json | jq -r .k3d)"
echo "kubectl: $(kubectl version --client -o json | jq -r .clientVersion.gitVersion)"
echo "argocd:  $(argocd version --client --short)"
