# 02 · Promote an agent from dev to prod (and other workspaces)

**The scenario this is for:** agent development happens in a **dev** workspace. Once an agent is ready,
you promote it to a **prod** workspace — or to several prod/regional workspaces — **programmatically**,
not by hand. 02 is that promotion path: take a finished agent and share it *outward* to other
workspaces.

```
   dev workspace  ──promote──►  prod workspace(s)
   (build & iterate here, 01)   (02 creates the agent here)
```

> **Why this exists (vs [01-agent-gitops](../01-agent-gitops/)):** 01 keeps **one** agent in sync with
> **its own** workspace — that's the dev loop where you build and iterate. 02 takes that agent and
> **creates** it in **other** workspaces (dev → prod). Rule of thumb: *iterating* an agent → 01;
> *promoting/replicating* it elsewhere → 02.

Two ways to promote, depending on whether you keep the agent in git:

- **`distribute.py`** — promote a *version-controlled* agent project to one or many target workspaces
  (**1 → N**), each with its own per-environment config and secrets (e.g. a different model or
  credentials in prod than dev), driven by overlay files.
- **`deploy.py`** — a one-shot, no-git promotion of a single package into a target: from an exported
  zip, or copied **straight from the dev workspace to prod** (cross-instance promotion / disaster
  recovery).

## Model

```
agent-repo/
  agent-spec.yaml          # the base template (secrets stay masked)
  runbook.md
  agent-files/...
  .sema4/
    environments/
      prod-eu.yaml         # one overlay per target workspace
      prod-us.yaml
```

Each overlay names a target workspace and how the agent differs there:

```yaml
# connection — either reference a profile (recommended)…
profile: prod-eu
# …or set base_url + api_key_env inline:
#   base_url: https://eu.app.sema4.ai/api/v2
#   api_key_env: SEMA4_API_KEY
agent_id:                              # filled in on first deploy (written back)

overrides:                            # deep-merged onto agent-spec.yaml
  model: { name: gpt-5-3-codex-high }

secrets:                              # dotted path into the agent -> ${ENV_VAR}
  mcp-servers.0.headers.X-SMTP-Password.value: ${EU_SMTP_PASSWORD}
```

For each target: **base spec + overrides + injected secrets → packed → deployed.** Overrides deep-merge
(lists of `{name: ...}` items merge by name); secrets are resolved from the environment at deploy time
and never read from git.

## Run

```sh
uv run distribute.py --repo ~/agents/my-agent                 # dryrun: plan all overlay targets
uv run distribute.py --repo ~/agents/my-agent --env prod-eu   # one overlay target
uv run distribute.py --repo ~/agents/my-agent --mode live     # create + publish everywhere

# override-free fan-out: same agent to several workspaces, by profile, no overlays needed
uv run distribute.py --repo ~/agents/my-agent --profiles prod-eu,prod-us --mode live
```

Use **overlays** (`.sema4/environments/*.yaml`) when targets need per-workspace overrides/secrets, or
**`--profiles`** when you just want the same agent in several workspaces. The overlays and `target.yaml`
both live under the repo's `.sema4/` — `target.yaml` is the agent's **home** (01's dev loop) and
`environments/` are its **promotion targets** (02).

- **First deploy** (no `agent_id` in the overlay): creates the agent, writes its id back into the
  overlay, and publishes if `--mode live`. (`--profiles` mode doesn't track ids — it's first-deploy only.)
- **Already deployed** (`agent_id` present): skipped — updating an existing agent in place needs the
  replace-import route (not available yet). Until then, re-distribution is first-deploy only.

Targets are independent: one workspace failing doesn't stop the others, and the run exits non-zero if
any failed.

## One-shot deploy (deploy.py)

No repo or overlays — just move a package into a target workspace, naming workspaces by profile:

```sh
# from a zip on disk, into a named target workspace
uv run deploy.py --zip ./agent.zip --to-profile prod-eu --mode live

# straight from one workspace to another (export source -> import target)
uv run deploy.py --from-agent <id> --from-profile dev --to-profile prod-eu --mode live
```

(Or give connections inline instead of profiles: `--to-url … --to-key-env …`, same for `--from-*`.)

Creates a new agent in the target; `--mode live` publishes it (default stages a draft). For
cross-workspace reference remapping (data-connection / MCP ids), use the publish endpoint's
`connection_mappings` / `mcp_server_mappings`.

## GitHub Actions

Use a matrix over GitHub Environments, so each target gets its own secrets:

```yaml
strategy:
  matrix:
    env: [prod-eu, prod-us]
environment: ${{ matrix.env }}
steps:
  - uses: actions/checkout@v4
  - uses: astral-sh/setup-uv@v6
  - run: uv run workflows/02-distribute-agent/distribute.py --repo . --env ${{ matrix.env }} --mode live
    env:
      SEMA4_API_KEY: ${{ secrets.SEMA4_API_KEY }}
      EU_SMTP_PASSWORD: ${{ secrets.EU_SMTP_PASSWORD }}
```

## Known limitation

Inline **MCP servers are not yet carried by import** — the platform drops them on create (the deployed
agent comes back with `mcp-servers: []`). The overlay `secrets:` mechanism is in place and ready, but
MCP configuration won't land on the deployed agents until the import route materializes inline MCP
servers. Everything else (model, settings, welcome message, document intelligence, SDMs, shared files)
carries through. `distribute.py` prints a note when the project has inline MCP servers.

_Status: first-deploy works today; in-place updates land with the replace-import route._
