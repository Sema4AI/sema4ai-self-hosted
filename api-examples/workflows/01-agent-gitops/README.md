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
3. **Publish** — a GitHub Action runs `push.py`, which diffs the push, reconciles the change onto the
   agent (`edit` → apply → optionally `publish`), as either a **draft** or an **immediately live**
   version.

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
**fails the run with a clear message** rather than publishing a partially-applied version. Closing this
gap is tracked in EPD-7051.

## Draft vs live

`mode: draft` leaves the change staged on the agent for review in the UI; `mode: live` publishes a new
live version. The convention in `workflow.example.yml`: PRs deploy a draft, pushes to `master` go live.

## Run locally

```sh
# bootstrap a repo from an existing agent
python pull.py --agent-id <id> --dest ./my-agent

# preview what a push would apply
python push.py --repo ./my-agent --mode draft
```
