# Runtime Health Classification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Docker Runtime Viewer report verified, unchecked, completed, and failed container states while assigning all current containers to explicit operating groups.

**Architecture:** Normalize raw Docker state into lifecycle states in the viewer backend, then resolve groups from Compose projects plus exact-name/prefix rules. Add native healthchecks only to components whose installed image has a safe local probe command, leaving init and opaque worker containers visibly unchecked or completed.

**Tech Stack:** Python 3.13 standard library, static JavaScript, Docker Compose, Docker healthchecks, Traefik.

## Global Constraints

- Docker Runtime remains read-only; it never writes to the Docker API.
- Blackbox/Alertmanager remains the external-availability authority.
- `unchecked` is informational, not an attention state.
- Init jobs exiting `0` are `completed`; non-zero exited containers are `failed`.
- Healthchecks must be local, credential-free, and side-effect free.

---

### Task 1: Normalize lifecycle states and counts

**Files:**
- Modify: `compose/stacks/edge/docker-runtime/app/runtime.py`
- Modify: `compose/stacks/edge/docker-runtime/app/static/app.js`
- Modify: `compose/stacks/edge/docker-runtime/tests/test_runtime.py`

**Interfaces:**
- Produces: `normalize_status(state) -> str` in `{healthy, unchecked, starting, unhealthy, completed, failed}`.
- Produces: group fields `healthy_count`, `unchecked_count`, `completed_count`, and `attention_count`.

- [ ] **Step 1: Write failing unit assertions**

```python
self.assertEqual(normalize_status({"Running": True}), "unchecked")
self.assertEqual(normalize_status({"Running": False, "ExitCode": 2}), "failed")
self.assertEqual(group["unchecked_count"], 1)
self.assertEqual(group["completed_count"], 1)
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `python -m unittest compose/stacks/edge/docker-runtime/tests/test_runtime.py`

Expected: assertions fail because the current implementation returns `running` and `stopped` and has no independent counts.

- [ ] **Step 3: Implement the minimal state/count change**

```python
if state.get("Running"):
    return health if health in {"healthy", "starting", "unhealthy"} else "unchecked"
return "completed" if state.get("ExitCode") == 0 else "failed"
```

Count `unchecked` and `completed` independently; count only `starting`, `unhealthy`, and `failed` as attention. Render those count labels and status names in `app.js`.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run: `python -m unittest compose/stacks/edge/docker-runtime/tests/test_runtime.py`

Expected: all Runtime Viewer tests pass.

- [ ] **Step 5: Commit**

```bash
git add compose/stacks/edge/docker-runtime/app/runtime.py \
  compose/stacks/edge/docker-runtime/app/static/app.js \
  compose/stacks/edge/docker-runtime/tests/test_runtime.py
git commit -m "feat: distinguish unchecked and completed runtime states"
```

### Task 2: Add explicit project and unmanaged-container grouping

**Files:**
- Modify: `compose/stacks/edge/docker-runtime/app/stacks.json`
- Modify: `compose/stacks/edge/docker-runtime/app/runtime.py`
- Modify: `compose/stacks/edge/docker-runtime/tests/test_runtime.py`

**Interfaces:**
- Consumes: each container record's `project` and `name` fields.
- Produces: group rules with `projects`, `names`, and `prefixes` and an `Unclassified` fallback only for future unmatched containers.

- [ ] **Step 1: Write failing grouping tests**

```python
self.assertEqual(group_for({"project": "harbor", "name": "harbor-core"}), "CI/CD")
self.assertEqual(group_for({"project": "Other", "name": "k3d-mgmt-server-0"}), "Infra")
self.assertEqual(group_for({"project": "Other", "name": "pg-tailnet-proxy"}), "Data")
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `python -m unittest compose/stacks/edge/docker-runtime/tests/test_runtime.py`

Expected: rules cannot resolve exact-name and prefix mappings.

- [ ] **Step 3: Implement declarative rules**

Change `stacks.json` entries to objects. Assign Harbor to CI/CD, `docker-runtime` and `platform-monitor` projects to Operations, `pg-tailnet-proxy` to Data, and `k3d-mgmt-server-` to Infra. Resolve projects first, then exact names, then prefixes.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run: `python -m unittest compose/stacks/edge/docker-runtime/tests/test_runtime.py`

Expected: mapped containers leave `Unclassified` empty in the fixture.

- [ ] **Step 5: Commit**

```bash
git add compose/stacks/edge/docker-runtime/app/stacks.json \
  compose/stacks/edge/docker-runtime/app/runtime.py \
  compose/stacks/edge/docker-runtime/tests/test_runtime.py
git commit -m "feat: classify runtime containers by operational group"
```

### Task 3: Add safe native readiness checks

**Files:**
- Modify: `compose/stacks/observability/prometheus/compose.yaml`
- Modify: `compose/stacks/edge/docker-runtime/compose.yaml`
- Create: `compose/tests/test-runtime-healthchecks.sh`

**Interfaces:**
- Produces Docker healthchecks for `node-exporter`, `blackbox-exporter`, and `docker-socket-proxy`.
- Does not add probes for init jobs, oauth2-proxy, GitLab Runner, or opaque workers.

- [ ] **Step 1: Write failing static configuration test**

```bash
contains "$PROMETHEUS" 'wget -q -O /dev/null http://127.0.0.1:9100/metrics'
contains "$PROMETHEUS" 'wget -q -O /dev/null http://127.0.0.1:9115/metrics'
contains "$RUNTIME" 'wget -q -O /dev/null http://127.0.0.1:2375/version'
```

- [ ] **Step 2: Run the test and verify RED**

Run: `bash compose/tests/test-runtime-healthchecks.sh`

Expected: it fails because those healthchecks do not yet exist.

- [ ] **Step 3: Add healthchecks**

Add each check with `interval: 30s`, `timeout: 5s`, `retries: 3`, and a short start period. Use the image-provided BusyBox `wget`; do not introduce a shell, package, credential, or remote request.

- [ ] **Step 4: Run static and Compose validation**

Run:

```bash
bash compose/tests/test-runtime-healthchecks.sh
docker compose -f compose/stacks/observability/prometheus/compose.yaml config -q
docker compose -f compose/stacks/edge/docker-runtime/compose.yaml config -q
```

Expected: all commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add compose/stacks/observability/prometheus/compose.yaml \
  compose/stacks/edge/docker-runtime/compose.yaml \
  compose/tests/test-runtime-healthchecks.sh
git commit -m "feat: verify runtime exporter readiness"
```

### Task 4: Deploy and verify the live Runtime API

**Files:**
- No source changes.

**Interfaces:**
- Consumes: deployed Compose services and `GET /api/runtime`.
- Produces: all current containers in named groups and explicit lifecycle counts.

- [ ] **Step 1: Rebuild the Runtime Viewer and recreate changed services**

```bash
docker compose -f compose/stacks/edge/docker-runtime/compose.yaml up -d --build
docker compose -f compose/stacks/observability/prometheus/compose.yaml up -d node-exporter blackbox-exporter
```

- [ ] **Step 2: Verify native health states**

Run:

```bash
docker inspect node-exporter blackbox-exporter docker-socket-proxy \
  --format '{{.Name}} {{.State.Health.Status}}'
docker exec docker-runtime-viewer python3 -c 'import json,urllib.request; d=json.load(urllib.request.urlopen("http://127.0.0.1:8080/api/runtime")); assert not d["other"], d["other"]'
```

Expected: the three checked services become `healthy`; the Runtime API has no unmatched containers.

- [ ] **Step 3: Run the full focused test suite**

Run:

```bash
python -m unittest compose/stacks/edge/docker-runtime/tests/test_runtime.py
bash compose/tests/test-runtime-healthchecks.sh
bash compose/tests/test-docker-runtime-viewer.sh
```

Expected: all commands exit 0.

- [ ] **Step 4: Commit and publish**

```bash
git push origin main
```
