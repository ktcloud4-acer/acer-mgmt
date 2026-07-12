#!/usr/bin/env bash
set -euo pipefail

readonly TOKEN_TTL='15m'
readonly TOKEN_ROOT='/run/acer-mgmt/teleport-team-enrollment'
readonly AIO_RUNTIME_TOKEN_DIR='/run/acer-bootstrap/teleport'
readonly TELEPORT_CONTAINER='teleport'

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

team=${1:-}
if [[ -z "$team" ]]; then
  read -rp 'Team (ggg|khb|ljw|nmg|oje): ' team
fi
case "$team" in
  ggg|khb|ljw|nmg|oje) ;;
  *) fail "Unsupported team: $team" ;;
esac

if (( EUID != 0 )); then
  fail 'Run this central enrollment bootstrap as root on acer-mgmt.'
fi

for command in docker install jq mktemp rm ssh tr; do
  command -v "$command" >/dev/null 2>&1 || fail "Missing command: $command"
done

readonly aio_host="${team}-aio.tailc0244b.ts.net"
readonly aio_key="${AIO_SSH_PRIVATE_KEY:-/home/user1/.ssh/acer.pem}"
readonly aio_known_hosts="${AIO_SSH_KNOWN_HOSTS:-/home/user1/.ssh/known_hosts}"
readonly token_dir="$(install -d -m 0700 "$TOKEN_ROOT" && mktemp -d "$TOKEN_ROOT/${team}.XXXXXXXX")"

test -r "$aio_key" || fail "AIO SSH key is not readable: $aio_key"
test -r "$aio_known_hosts" || fail "AIO known_hosts file is not readable: $aio_known_hosts"
docker exec "$TELEPORT_CONTAINER" tctl status >/dev/null

ssh_aio() {
  ssh -i "$aio_key" \
    -o BatchMode=yes \
    -o ConnectTimeout=12 \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$aio_known_hosts" \
    "ubuntu@$aio_host" "$@"
}

revoke_tokens() {
  local role token_file token

  for role in aio master worker1 worker2; do
    token_file="$token_dir/${team}-${role}.token"
    if [[ -s "$token_file" ]]; then
      token="$(tr -d '\r\n' < "$token_file")"
      docker exec "$TELEPORT_CONTAINER" tctl tokens rm "$token" >/dev/null 2>&1 || true
      unset token
    fi
  done
}

cleanup_remote_inputs() {
  local role command='sudo rm -f'

  for role in aio master worker1 worker2; do
    command+=" $AIO_RUNTIME_TOKEN_DIR/${team}-${role}.token"
  done
  ssh_aio "$command" >/dev/null 2>&1 || true
}

cleanup() {
  local status=$?

  trap - EXIT INT TERM
  if (( status != 0 )); then
    cleanup_remote_inputs
    revoke_tokens
  fi
  rm -rf "$token_dir"
  exit "$status"
}
trap cleanup EXIT INT TERM

ssh_aio "sudo install -d -o root -g root -m 0700 $AIO_RUNTIME_TOKEN_DIR"

for role in aio master worker1 worker2; do
  token_file="$token_dir/${team}-${role}.token"
  docker exec "$TELEPORT_CONTAINER" tctl tokens add --type=node --ttl="$TOKEN_TTL" --format=text \
    > "$token_file"
  test -s "$token_file" || fail "Teleport returned an empty $role token"
  chmod 0600 "$token_file"

  ssh_aio \
    "sudo install -o root -g root -m 0600 /dev/stdin $AIO_RUNTIME_TOKEN_DIR/${team}-${role}.token" \
    < "$token_file"
done

ssh_aio "sudo /home/ubuntu/acer-aio/25-teleport-nodes/bootstrap.sh $team"

nodes_json="$(docker exec "$TELEPORT_CONTAINER" tctl nodes ls --format=json)"
for role in aio master worker1 worker2; do
  node_name="${team}-${role}"
  node_role="$role"
  [[ "$role" != master ]] || node_role='control-plane'

  jq -e \
    --arg node_name "$node_name" \
    --arg team "$team" \
    --arg role "$node_role" \
    '[.[] | select(
      .spec.hostname == $node_name and
      ((.sub_kind // "") != "openssh") and
      .metadata.labels.project == "ktcloud4-acer" and
      .metadata.labels.team == $team and
      .metadata.labels.role == $role
    )] | length == 1' <<<"$nodes_json" >/dev/null \
    || fail "Teleport did not register exactly one expected node: $node_name"
done

revoke_tokens
cleanup_remote_inputs
printf 'Teleport SSH nodes enrolled for team %s: %s-aio, %s-master, %s-worker1, %s-worker2\n' \
  "$team" "$team" "$team" "$team"
