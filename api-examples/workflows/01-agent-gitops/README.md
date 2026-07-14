# 01 · Agent GitOps

Version-control an agent in git and publish changes back to its workspace automatically.

> **Why this exists (vs [02-distribute-agent](../02-distribute-agent/)):** 01 is the **dev loop** —
> keep **one** agent in sync with **its own** workspace: `pull` it into git, edit, and `push` the whole
> package back to the *same* agent (`PUT /import` into its draft, then publish). Once it's ready, use 02
> to **promote it from dev to prod** (and other workspaces).

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
   `.sema4/target.yaml` recording the agent id and its **home** workspace (`profile:` if you pulled
   with one). `push.py` reads that profile automatically, so you don't repeat `--profile` each run.
2. **Edit** — change `runbook.md` (or other config) in any editor, commit, push.
3. **Publish** — a GitHub Action runs `push.py`, which imports the packaged repo into the agent
   (`PUT /agents/{id}/import`) and optionally publishes it, as either a **draft** or an **immediately
   live** version.

## Two repos

- **This repo** holds the reusable tooling (`pull.py`, `push.py`) and the [`action.yml`](action.yml)
  composite action.
- **The agent repo** is the customer's version-controlled agent. [`sample-agent-repo/`](sample-agent-repo/)
  shows its shape, and [`workflow.example.yml`](workflow.example.yml) is the workflow it drops into
  `.github/workflows/`.

All tool metadata lives under the repo's `.sema4/`: `target.yaml` (this agent's **home** workspace, used
here) and optionally `environments/` (its **promotion targets**, used by
[02-distribute-agent](../02-distribute-agent/)). Both reference workspaces by profile.

## What push.py applies

`push.py` sends the whole package via `PUT /agents/{id}/import`, so **every part of the agent is
carried** — runbook, name/description, model, agent settings, welcome message, document intelligence,
SDMs, and shared files. The import creates/updates the agent's **draft**; the live version stays until
you publish (`--mode live`). Shared files are add-only (import never deletes).

**MCP servers** are matched to servers that already exist in the target workspace by case-insensitive
**name + URL** and attached; packages carry no secrets, so any server with no match is reported as
*unresolved* — create it in the workspace and attach it, then re-run.

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

# 3. preview a real run (default mode is dryrun — no writes)
uv run push.py --repo ~/agents/my-agent
```

> For a quick throwaway tryout you can use a temp dir like `/tmp/my-agent` instead — just note macOS
> clears `/tmp`, so don't keep anything you care about there.

`push.py` compares the repo against the agent's actual current state (it exports the live agent to
diff), so any change is detected automatically — no flags required.

It has three modes via `--mode`:

- **`dryrun`** (default) — preview only; exports the live agent, compares it to the repo, and prints
  every change that would apply (a unified diff for the runbook). No write endpoints are called.
- **`draft`** — imports the package into the agent's draft (`PUT /import`); the live version is untouched.
- **`live`** — imports into the draft and publishes a new live version.

Everything in the package is applied (see [What push.py applies](#what-pushpy-applies)); any unresolved
MCP servers are reported so you can create + attach them. Discard a test draft with the agent's
`discard-draft` to return it to pristine.

Before doing anything, `push.py` runs a local pre-flight on the repo (valid `agent-spec.yaml` YAML,
required fields, referenced runbook/SDM/shared files present) and exits with a clear `✗ INVALID` message
if you've hand-edited it into a broken state — so the PR's dryrun check catches mistakes early.

```sh
uv run push.py --repo ~/agents/my-agent              # dryrun (default)
uv run push.py --repo ~/agents/my-agent --mode draft
```
