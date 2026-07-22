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
| 02 | [`distribute-agent`](workflows/02-distribute-agent/) | Promote an agent from dev to prod workspace(s) — fan out with per-env config, or one-shot copy across instances | Create + update |
| 03 | [`clone-workspace`](workflows/03-clone-workspace/) | Replicate a "golden" workspace's configuration into another, via profiles ("poor man's Terraform") | Export + apply work |

**01 vs 02:** 01 is the **dev loop** — keep **one** agent in sync with **its own** workspace
(edit-in-place). 02 is **dev → prod promotion** — push a finished agent *outward* to **other**
workspaces (always creates). Building/iterating an agent → 01; promoting it to prod → 02.

## Setup

The scripts run with [uv](https://docs.astral.sh/uv/) (it is **not** bundled with Python — install it
once):

```sh
curl -LsSf https://astral.sh/uv/install.sh | sh    # or: brew install uv
```

Then point a tool at a workspace, either via env vars:

```sh
cp .env.example .env
# then edit .env
```

| Variable | Example | Notes |
|----------|---------|-------|
| `SEMA4_BASE_URL` | `https://<deployment>.app.sema4.ai/api/v2` | Your deployment's v2 API base URL |
| `SEMA4_API_KEY` | `s4w_...` | Sent as `Authorization: Bearer <key>` |

Get an API key from your deployment's **Configuration → API keys** page.

### Profiles (operating several workspaces)

Instead of swapping the env vars per run, register the workspaces you operate once and target them by
name. **Every tool accepts `--profile <name>`** (distribute overlays use a `profile:` key). Copy
[`sema4-profiles.example.yaml`](sema4-profiles.example.yaml) to `sema4-profiles.yaml` (or
`~/.sema4/profiles.yaml`, or point `$SEMA4_PROFILES` at it):

```yaml
profiles:
  golden:  { base_url: https://darkside.app.sema4.ai/api/v2, api_key: ${GOLDEN_API_KEY} }
  prod-eu: { base_url: https://eu.app.sema4.ai/api/v2,       api_key: ${EU_API_KEY} }
```

`api_key` uses `${ENV}` refs so the file holds no literal secrets. Then, e.g.:

```sh
uv run list-agents.py --profile golden
uv run workflows/03-clone-workspace/apply.py --profile prod-eu --file workspace.yaml
```

These aren't two competing config systems — it's one resolver with the env vars as the **default**
(unnamed) workspace and profiles as **named** ones. No `--profile` → env. CI uses the env path (GitHub
Actions injects secrets as env vars); profiles are for operating several workspaces locally.

## Helpers

Small root-level agent-management utilities (each takes `--profile` too):

```sh
# list agents — id, state, mode (conversational|worker), last update
uv run list-agents.py --name "All"            # also --state, --mode, --json

# CRUD a worker agent's schedules (cron -> work items); worker agents only
uv run schedules.py list   --agent "<name|id>"
uv run schedules.py create --agent "<name|id>" --cron "0 9 * * 1-5" --message "..."
uv run schedules.py delete --agent "<name|id>" --schedule "<sid>"
```

## Layout

```
api-examples/
  list-agents.py               helper: list agents (id, state, mode)
  schedules.py                 helper: CRUD a worker agent's schedules
  sema4-profiles.example.yaml  template for the workspace profiles registry
  lib/                         shared helpers (HTTP client, agent zip<->tree packing, config/profiles)
  workflows/                   one directory per use case (scripts, READMEs, GitHub Actions)
```

The shared `lib/` keeps the cross-cutting logic — pagination, the agent zip ↔ flat-tree round-trip —
in one place so each workflow stays small.

Scripts use [uv](https://docs.astral.sh/uv/) and declare their dependencies inline (PEP 723), so there
is nothing to install or activate — just `uv run <script>` and uv builds a cached environment on the
fly. The only third-party dependency is **PyYAML** (to read and rewrite `agent-spec.yaml`).
