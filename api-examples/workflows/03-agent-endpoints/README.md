# 03 · Agent endpoints

Resolve the URLs you need to **reach a deployed agent** — so that after deploying an agent (01/02) you
can wire it into other systems and hand people a link, without clicking around the UI.

An agent is reachable three ways:

| Endpoint | URL | Use it to |
|----------|-----|-----------|
| **MCP** | `{base_url}/agent-mcp/{agent_id}/mcp/` | Use the agent *itself* over MCP — an external MCP client calls the agent as a server (POST JSON-RPC; GET opens an SSE stream) |
| **Work items** | `{base_url}/work-items` | Hand the agent work asynchronously (`POST` to create a work item) |
| **Chat UI** | _(deployment UI URL — to be verified)_ | Give a person a browser link to chat with the agent |

There is no single "give me this agent's endpoints" API call: the MCP and work-item URLs are composed
from `base_url` + the agent id, and the chat URL is a frontend link off the deployment root (not under
`/api/v2`). This workflow takes an agent id (or lists agents) and returns the full set — handy as a
GitHub Action output so a deploy job can pass endpoints downstream.

_Status: planned — scaffolding only. The MCP/work-item URLs are derived from the API; the chat UI URL
pattern still needs to be confirmed against the deployment._
