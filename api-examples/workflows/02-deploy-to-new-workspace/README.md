# 02 · Deploy to a new workspace

Seed an agent package into a new or empty workspace — the first-time / cross-instance deploy.

Given an exported agent package (a zip, or an agent in another workspace), import it into a target
workspace, let it validate, and publish it live.

## Flow

1. Obtain the package — `GET /agents/{id}/export` from the source, or a zip on disk.
2. `POST /agents/import` against the target workspace -> creates the agent, returns its new id.
3. Resolve any references that differ between workspaces (data connections, MCP servers) and inject
   secrets.
4. Optionally `POST /agents/{id}/publish` to set it live.

> Unlike [01-agent-gitops](../01-agent-gitops/), import here intentionally **creates** a new agent —
> this is first-time seeding, not an update. Updating an existing agent in place is EPD-7051.

_Status: planned — scaffolding only._
