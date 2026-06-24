# 01 · Agent GitOps

Version-control an agent in git and publish changes back to its workspace automatically.

## The loop

```
                    pull.py (once / scheduled)
   ┌──────────────────────────────────────────────┐
   │  live agent in workspace  ──export──►  git repo │
   └──────────────────────────────────────────────┘
                                                │ edit runbook / config, commit, push
                                                ▼
                    push.py (GitHub Action, on push)
   ┌──────────────────────────────────────────────┐
   │  git repo  ──reconcile──►  draft  ──publish──►  live │
   └──────────────────────────────────────────────┘
```

1. **Bootstrap** — `pull.py` exports the agent, unpacks it into a git-friendly tree, and writes
   `.sema4/target.yaml` recording which agent/workspace this repo maps to.
2. **Edit** — change `runbook.md` (or other config) in any editor, commit, push.
3. **Publish** — a GitHub Action runs `push.py`, which compares the repo against the live agent and
   reconciles the difference (`edit` → apply → optionally `publish`), as either a **draft** or an
   **immediately live** version.

## Two repos

- **This repo** holds the reusable tooling (`pull.py`, `push.py`) and the [`action.yml`](action.yml)
  composite action.
- **The agent repo** is the customer's version-controlled agent. [`sample-agent-repo/`](sample-agent-repo/)
  shows its shape, and [`workflow.example.yml`](workflow.example.yml) is the workflow it drops into
  `.github/workflows/`.

## What can be published today

| Edit | Applied by |
|------|-----------|
| `runbook.md` | `PATCH` runbook_text |
| name / description | `PATCH` |
| MCP server attach/detach | `/agents/{id}/mcp-servers` |
| SDM attach/detach | `/agents/{id}/semantic-data-models` |

Edits to **model, agent settings, welcome message, document intelligence, or shared files** cannot yet
be applied to an existing agent (they only enter via create-import). `push.py` detects such changes and
**fails the run with a clear message** rather than publishing a partially-applied version.

## Draft vs live

`mode: draft` leaves the change staged on the agent for review in the UI; `mode: live` publishes a new
live version. The convention in `workflow.example.yml`: PRs deploy a draft, pushes to `master` go live.

## Run locally

Scripts run with [uv](https://docs.astral.sh/uv/) — dependencies are declared inline, nothing to
install. Set `SEMA4_BASE_URL` and `SEMA4_API_KEY` (or put them in `../../.env`).

The agent repo is its own persistent git repository (separate from this one) that you keep and push
to GitHub — pick a real directory for it, not a temp path.

```sh
# 1. bootstrap the agent repo from an existing agent
uv run pull.py --agent-id <id> --dest ~/agents/my-agent
( cd ~/agents/my-agent && git init -q && git add -A && git commit -qm "import agent" )

# 2. edit runbook.md (or other config)

# 3. preview a real run (non-destructive)
uv run push.py --repo ~/agents/my-agent --simulate
```

> For a quick throwaway tryout you can use a temp dir like `/tmp/my-agent` instead — just note macOS
> clears `/tmp`, so don't keep anything you care about there.

`push.py` compares the repo against the agent's actual current state (it exports the live agent to
diff), so any change is detected automatically — no flags required.

`--mode draft` stages the change for review (the live version is untouched); `--mode live` applies the
change and publishes a new live version. Running `--mode live` when a draft is already staged (e.g. from
an earlier `--mode draft` run) publishes that pending draft even if the repo adds no new diff. Changes
that can't be applied in place yet (model, settings, welcome message, MCP servers, shared files) are
reported and the run is refused, so a partial version is never published. Discard a test
draft with the agent's `discard-draft` to return it to pristine.

To preview without changing anything, add `--simulate` — it prints what would be applied (a unified
diff for the runbook), what is blocked, and the action a real run would take, calling no write
endpoints:

```sh
uv run push.py --repo ~/agents/my-agent --simulate
```
