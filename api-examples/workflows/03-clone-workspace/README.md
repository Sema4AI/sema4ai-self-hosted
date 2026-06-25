# 03 · Clone a workspace

Replicate a "golden" workspace's configuration into another, empty one — a "poor man's Terraform"
driven by a YAML config.

There is no single clone endpoint; the workspace *is* the tenant. This workflow reads the source
workspace's resources and recreates them in the target, in dependency order:

1. LLMs (`/llms`) and defaults (`/llms/defaults`)
2. Data connections (`/data-connections`)
3. MCP servers (`/mcp-servers`)
4. Semantic data models (`/semantic-data-models`)
5. Settings (`/settings`) and branding (`/branding`)
6. Agents (`/agents` + import), wiring up the references created above

Secrets are redacted on read, so the config declares where each secret comes from (env / CI) and the
clone injects them on create.

_Status: planned — scaffolding only._
