#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPT="${REPO_ROOT}/compose/scripts/mgmt-db-backup.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

home_root="${tmpdir}/home/user1"
mkdir -p \
  "${home_root}/acer-mgmt/compose" \
  "${home_root}/acer-mgmt/secrets" \
  "${home_root}/acer-mgmt/k3d"
touch "${home_root}/acer-mgmt/.env"

MGMT_DB_BACKUP_SOURCE_ONLY=1 source "${SCRIPT}"

archive_without_argocd="${tmpdir}/without-argocd.tar.gz"
create_config_backup "${archive_without_argocd}" "${home_root}"

if ! tar -tzf "${archive_without_argocd}" | grep -qx 'acer-mgmt/.env'; then
  echo "missing acer-mgmt/.env in config backup" >&2
  exit 1
fi

if tar -tzf "${archive_without_argocd}" | grep -q '^acer-argocd'; then
  echo "acer-argocd should not be included when the checkout is absent" >&2
  exit 1
fi

mkdir -p "${home_root}/acer-argocd"
touch "${home_root}/acer-argocd/application.yaml"

archive_with_argocd="${tmpdir}/with-argocd.tar.gz"
create_config_backup "${archive_with_argocd}" "${home_root}"

if ! tar -tzf "${archive_with_argocd}" | grep -qx 'acer-argocd/application.yaml'; then
  echo "missing optional acer-argocd checkout in config backup" >&2
  exit 1
fi
