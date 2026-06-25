# 03 · Clone a workspace

Capture a "golden" workspace's configuration as portable YAML, then recreate it in another, empty
workspace — a "poor man's Terraform" for the workspace control plane.

The workspace is the tenant, so this clones the configuration *resources*, not agents (use 01/02 for
agents):

- **branding** — workspace name, light/dark logos, primary colour
- **LLMs** — configurations + the default and SQL-gen defaults (referenced by name)
- **MCP servers**
- **data connections** (per engine)
- **advanced settings**
- **observability integrations**

## Two steps

```sh
# 1. export the golden workspace
uv run export.py --profile golden --out workspace.yaml

# 2. apply it to a new, empty workspace
uv run apply.py --profile new-eu --file workspace.yaml
```

Step 1 needs read access to the golden workspace; step 2 needs the **target workspace's API key** — that
is the only thing you set up by hand. Everything else is created programmatically.

## Profiles — operating several workspaces

Rather than swapping `SEMA4_BASE_URL` / `SEMA4_API_KEY` per run, define the workspaces you operate once
in a profiles file (`./sema4-profiles.yaml`, `~/.sema4/profiles.yaml`, or `$SEMA4_PROFILES`):

```yaml
profiles:
  golden:  { base_url: https://darkside.app.sema4.ai/tenants/spar/api/v2, api_key: ${GOLDEN_KEY} }
  new-eu:  { base_url: https://eu.app.sema4.ai/tenants/spar/api/v2,       api_key: ${EU_KEY},
             secrets: new-eu.secrets.env }
```

`api_key` uses `${ENV}` refs so the file holds no literal secrets. A profile may name a `secrets:` env
file that `apply.py` auto-loads. Every tool in this repo accepts `--profile`; without it they fall back
to the `SEMA4_*` env vars.

## Secrets

Workspace config comes back from the API with secrets in **plaintext** (DB passwords, AWS keys,
MCP/observability API keys). `export.py` redacts them to `${ENV_VAR}` placeholders so `workspace.yaml`
is safe to share, and writes the real values to a sibling `workspace.secrets.env` (mode 600, **never
commit it**). `apply.py` resolves the placeholders from the environment — auto-loading the sibling
`*.secrets.env` and the profile's `secrets:` file — and errors if any are missing.

## Safety

- LLM defaults and references are carried **by name** and re-resolved to the new ids in the target.
- If the target workspace already has configuration (LLMs, MCP servers, data connections, observability),
  `apply.py` lists it and refuses to proceed without you typing `yes, really` (pass `--yes` in CI).
- `--dry-run` prints the plan and creates nothing.

_Status: export + apply work today against the live API._
