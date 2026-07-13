# Dashy Chaos Health Probe Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Dashy report the real Chaos Dashboard health through the current team ingress endpoints.

**Architecture:** Keep the Dashy-to-platform-monitor interface unchanged. Align platform-monitor's upstream URL and Host header with the existing management-to-spoke Traefik route.

**Tech Stack:** Python 3 standard library, `unittest`, Bash static tests, Docker Compose, Traefik

## Global Constraints

- Preserve the management-cluster probe and all Dashy card/status URLs.
- Use `<team>-ingress.tailc0244b.ts.net` for TLS and `<team>-chaos.imcherry5778.xyz` for HTTP routing.
- Rebuild only `platform-monitor` during runtime deployment.
- Do not commit, push, create an MR, merge, synchronize, or clean branches without the repository-required explicit approval for each step.

---

### Task 1: Add the upstream mapping regression test

**Files:**
- Modify: `compose/stacks/edge/platform-monitor/tests/test_summary.py`
- Test: `compose/stacks/edge/platform-monitor/tests/test_summary.py`

**Interfaces:**
- Consumes: module-level `CHAOS_UPSTREAMS: dict[str, tuple[str, dict[str, str]]]`
- Produces: a regression assertion covering all five team ingress mappings

- [ ] **Step 1: Add a test that expects each team ingress URL and public Host header**
- [ ] **Step 2: Run the unit test and verify it fails against the retired `-chaos` names**
- [ ] **Step 3: Replace the five retired upstream mappings in `server.py`**
- [ ] **Step 4: Run the unit test and verify all tests pass**

### Task 2: Correct the stale Traefik static test

**Files:**
- Modify: `compose/tests/test-chaos-mesh-cluster-dashboards.sh`
- Verify: `compose/stacks/edge/traefik/config/dynamic/k3d.yaml`

**Interfaces:**
- Consumes: one `*-chaos-dashboard` service per team in the Traefik dynamic configuration
- Produces: static validation of `<team>-ingress` and `passHostHeader: true`

- [ ] **Step 1: Change the expected backend from `<team>-chaos` to `<team>-ingress`**
- [ ] **Step 2: Require `passHostHeader: true` inside every team service block**
- [ ] **Step 3: Run the static route test and verify it passes**

### Task 3: Verify and hand off the fix

**Files:**
- Verify: `compose/stacks/edge/platform-monitor/app/server.py`
- Verify: `compose/stacks/edge/platform-monitor/compose.yaml`
- Verify: `compose/stacks/edge/dashy/config/conf.yml`

**Interfaces:**
- Consumes: Docker network `mgmt-proxy` and team ingress MagicDNS endpoints
- Produces: a locally verified branch ready for the repository-required Git approval sequence

- [ ] **Step 1: Run platform-monitor unit, Dashy index, and Traefik route tests**
- [ ] **Step 2: Review the complete branch diff and whitespace checks**
- [ ] **Step 3: Reconfirm the desired team ingress probes return HTTP 200 without changing the running container**
- [ ] **Step 4: Report changes and evidence, then request explicit commit approval**

Runtime rebuild and status verification occur only after explicit approval for
commit, push, MR creation, `main` merge, and runtime synchronization in that
order. Runtime success requires ggg and nmg to return HTTP 200; teams without an
active ingress remain unhealthy rather than being forced green.
