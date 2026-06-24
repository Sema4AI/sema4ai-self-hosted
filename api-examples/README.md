# Sema4.ai API — Use-Case Workflows

Practical, runnable examples for operating the Sema4.ai platform **at scale via its v2 API** — the
kind of automation customers reach for once they have many agents across one or more workspaces.

Each workflow is self-contained, optimized to be read and copied, and built on the platform's public
v2 API (the same surface the product UI uses). The API publishes its own OpenAPI spec at the base URL,
which is the authoritative reference.

## Workflows

| # | Workflow | What it does | Status |
|---|----------|--------------|--------|
| 01 | [`agent-gitops`](workflows/01-agent-gitops/) | Export an agent → version-control it in git → publish changes back to the workspace on push (GitHub Actions) | Flagship |
| 02 | [`deploy-to-new-workspace`](workflows/02-deploy-to-new-workspace/) | Seed an agent package into a new/empty workspace (first-time deploy) | Planned |
| 03 | [`agent-endpoints`](workflows/03-agent-endpoints/) | Resolve an agent's external endpoints (MCP, work items) programmatically | Planned |
| 04 | [`clone-workspace`](workflows/04-clone-workspace/) | Replicate a "golden" workspace's configuration into another ("poor man's Terraform") | Planned |

## Setup

Every workflow reads the same two values from the environment:

```sh
cp .env.example .env
# then edit .env
```

| Variable | Example | Notes |
|----------|---------|-------|
| `SEMA4_BASE_URL` | `https://<deployment>.app.sema4.ai/tenants/spar/api/v2` | Tenant path is always `tenants/spar`; only the deployment subdomain changes |
| `SEMA4_API_KEY` | `s4w_...` | Sent as `Authorization: Bearer <key>` |

Get an API key from your deployment's **Configuration → API keys** page.

To find an agent's id (e.g. to pass to a workflow's `pull.py`):

```sh
uv run list-agents.py --name "All"     # filter by name prefix; also --state, --json
```

## Layout

```
api-examples/
  list-agents.py   helper: list agents and their ids
  lib/             shared helpers (HTTP client, agent zip<->tree packing)
  workflows/       one directory per use case (scripts, READMEs, GitHub Actions)
```

The shared `lib/` keeps the cross-cutting logic — pagination, the agent zip ↔ flat-tree round-trip —
in one place so each workflow stays small.

Scripts use [uv](https://docs.astral.sh/uv/) and declare their dependencies inline (PEP 723), so there
is nothing to install or activate — just `uv run <script>` and uv builds a cached environment on the
fly. The only third-party dependency is **PyYAML** (to read and rewrite `agent-spec.yaml`).
