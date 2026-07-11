# Homepage n8n Link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an SSO-routed n8n card to the Homepage Observability group with a regression test.

**Architecture:** Homepage consumes `config/services.yaml` through its existing read-only bind mount. Add a declarative card using the same domain variable as every other public service. A small shell test asserts the card's operator-facing contract without starting containers.

**Tech Stack:** YAML, Bash, Docker Compose Homepage configuration.

## Global Constraints

- Use `https://n8n.{{HOMEPAGE_VAR_BASE_DOMAIN}}` as the only n8n Homepage URL.
- Keep n8n, Traefik, SSO, and port configuration unchanged.
- Keep the card within the existing `Observability` group.

---

### Task 1: Add and verify the n8n Homepage card

**Files:**
- Create: `compose/tests/test-homepage-n8n-link.sh`
- Modify: `compose/stacks/edge/homepage/config/services.yaml`

**Interfaces:**
- Consumes: Homepage's `HOMEPAGE_VAR_BASE_DOMAIN` variable supplied by `compose/stacks/edge/homepage/compose.yaml`.
- Produces: An `n8n` Observability card that links to the n8n Traefik hostname.

- [ ] **Step 1: Write the failing test**

Create `compose/tests/test-homepage-n8n-link.sh` with assertions for the `n8n:` card name, `n8n.png` icon, exact URL template, and `Platform operations-digest automation` description in `services.yaml`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash compose/tests/test-homepage-n8n-link.sh`

Expected: `FAIL` because the n8n card does not yet exist.

- [ ] **Step 3: Write minimal implementation**

Add this entry beneath the existing `Observability` services in `compose/stacks/edge/homepage/config/services.yaml`:

```yaml
    - n8n:
        icon: n8n.png
        href: https://n8n.{{HOMEPAGE_VAR_BASE_DOMAIN}}
        description: Platform operations-digest automation
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash compose/tests/test-homepage-n8n-link.sh && bash compose/tests/test-n8n-stack.sh && bash compose/tests/test-n8n-digest-workflow.sh`

Expected: all three commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add compose/stacks/edge/homepage/config/services.yaml compose/tests/test-homepage-n8n-link.sh docs/superpowers/specs/2026-07-11-homepage-n8n-link-design.md docs/superpowers/plans/2026-07-11-homepage-n8n-link.md
git commit -m "feat: add n8n to homepage"
```
