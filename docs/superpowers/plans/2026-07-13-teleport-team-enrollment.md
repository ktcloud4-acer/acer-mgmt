# Central Team Teleport Enrollment Implementation Plan

**Goal:** Replace manual node-token issuance and transfer with one root-only command on `acer-mgmt` that enrolls an entire team AIO and its Kubernetes VMs.

**Architecture:** `compose/scripts/bootstrap-teleport-team-nodes.sh <team>` owns `tctl` only on `acer-mgmt`. It creates four distinct 15-minute `node` tokens in an owner-only runtime directory, streams them to the team AIO over SSH, runs the existing AIO layer-25 bootstrap, verifies four native Teleport nodes centrally, revokes every token, and removes all staging files. It never exposes a Teleport administration credential to AIO or stores a token in Git.

**Tech Stack:** Bash, Docker `tctl`, SSH, jq, existing AIO layer-25 bootstrap, shell contract tests.

## Global Constraints

- Supported teams are exactly `ggg`, `khb`, `ljw`, `nmg`, `oje`.
- Token types are `node`, TTL is exactly `15m`, and there is one token each for `aio`, `master`, `worker1`, `worker2`.
- SSH target is `<team>-aio.tailc0244b.ts.net` as user `ubuntu`; the private key defaults to `/home/user1/.ssh/acer.pem` and may be overridden by `AIO_SSH_PRIVATE_KEY`.
- Script requires root, checks the local Docker Teleport container, accepts a first-seen Tailnet AIO host key but rejects later changes, and streams token values over stdin only.
- On any failure, delete remote AIO token inputs, revoke all generated tokens where possible, and remove central staging files. Never print token values.

### Task 1: Failing contract test and secure central runner

**Files:**
- Create: `compose/scripts/bootstrap-teleport-team-nodes.sh`
- Create: `compose/tests/test-teleport-team-enrollment.sh`
- Modify: `compose/ansible/README.md`

- [ ] Write a failing shell contract asserting root guard, allowed teams, `tctl tokens add --type=node --ttl=15m`, the four target suffixes, `ssh ... /dev/stdin`, `tctl nodes ls --format=json`, `tctl tokens rm`, strict host checking, trap cleanup, and no token literal.
- [ ] Run `bash compose/tests/test-teleport-team-enrollment.sh` and confirm it fails because the runner is absent.
- [ ] Implement the runner: create a `mktemp -d` owner-only directory; issue tokens without logging; create the AIO runtime directory; stream each token to its canonical path; run `sudo /home/ubuntu/acer-aio/25-teleport-nodes/bootstrap.sh <team>`; use jq against `tctl nodes ls --format=json` to require exactly four matching native nodes with the team/role labels; revoke tokens and remove all temporary files.
- [ ] Re-run the contract test and commit `feat(teleport): 팀 노드 중앙 등록 bootstrap 추가`.

### Task 2: Execute central bootstrap only with live authorization

**Files:** none.

- [ ] Confirm `docker exec teleport tctl status`, the SSH key, and reachability of `<team>-aio.tailc0244b.ts.net`.
- [ ] Run `sudo compose/scripts/bootstrap-teleport-team-nodes.sh ggg` from `acer-mgmt`.
- [ ] Verify `tsh ls --query 'labels["team"]=="ggg"'`, four `tsh ssh ubuntu@ggg-*` connections, `tsh kube login ggg`, and that token files are absent centrally and on AIO.
