# 03 · Agent endpoints

Resolve an agent's external endpoints programmatically — what you need after deploying an agent so you
can wire it into other systems.

## Endpoints

| Endpoint | URL |
|----------|-----|
| MCP (tools) | `{base_url}/agent-mcp/{agent_id}/mcp/` |
| Work items | `{base_url}/work-items` |

The MCP URL is derived from the agent id; there is no dedicated "list endpoints" call today. This
workflow lists agents, composes their endpoint URLs, and optionally verifies they respond.

_Status: planned — scaffolding only._
