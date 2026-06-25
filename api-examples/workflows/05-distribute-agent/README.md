# 05 · Distribute an agent to multiple workspaces

Take one version-controlled agent project and deploy it to many workspaces, each with its own
configuration and secrets — a fleet roll-out driven by per-environment overlay files.

## Model

```
agent-repo/
  agent-spec.yaml          # the base template (secrets stay masked)
  runbook.md
  agent-files/...
  environments/
    prod-eu.yaml           # one overlay per target workspace
    prod-us.yaml
```

Each overlay names a target workspace and how the agent differs there:

```yaml
base_url: https://eu.app.sema4.ai/tenants/spar/api/v2
api_key_env: SEMA4_API_KEY            # env var holding that workspace's API key
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
uv run distribute.py --repo ~/agents/my-agent                 # dryrun: plan all targets
uv run distribute.py --repo ~/agents/my-agent --env prod-eu   # one target
uv run distribute.py --repo ~/agents/my-agent --mode live     # create + publish everywhere
```

- **First deploy** (no `agent_id` in the overlay): creates the agent, writes its id back into the
  overlay, and publishes if `--mode live`.
- **Already deployed** (`agent_id` present): skipped — updating an existing agent in place needs the
  replace-import route (not available yet). Until then, re-distribution is first-deploy only.

Targets are independent: one workspace failing doesn't stop the others, and the run exits non-zero if
any failed.

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
  - run: uv run workflows/05-distribute-agent/distribute.py --repo . --env ${{ matrix.env }} --mode live
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
