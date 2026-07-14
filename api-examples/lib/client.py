"""Thin HTTP client for the Sema4.ai v2 API.

Wraps urllib so the workflows have no third-party dependencies. Handles auth,
JSON encode/decode, pagination, and the agent export/import endpoints.
"""

from __future__ import annotations

import json
import mimetypes
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Iterator, Optional

from .config import Config


class ApiError(RuntimeError):
    """Raised on a non-2xx response, carrying the server's error envelope when present."""

    def __init__(self, status: int, body: str) -> None:
        self.status = status
        self.body = body
        message = body
        try:
            envelope = json.loads(body).get("error", {})
            message = f"{envelope.get('code', status)}: {envelope.get('message', body)}"
        except (ValueError, AttributeError):
            pass
        super().__init__(f"HTTP {status} — {message}")


class SemaClient:
    def __init__(self, config: Config) -> None:
        self._config = config

    # --- low-level ---------------------------------------------------------
    def _open(self, req: urllib.request.Request) -> tuple[int, bytes, dict]:
        req.add_header("Authorization", f"Bearer {self._config.api_key}")
        try:
            with urllib.request.urlopen(req) as resp:
                return resp.status, resp.read(), dict(resp.headers)
        except urllib.error.HTTPError as err:
            raise ApiError(err.code, err.read().decode("utf-8", "replace")) from None

    def _url(self, path: str, params: Optional[dict] = None) -> str:
        url = path if path.startswith("http") else f"{self._config.base_url}/{path.lstrip('/')}"
        query = {k: v for k, v in (params or {}).items() if v is not None}
        return f"{url}?{urllib.parse.urlencode(query)}" if query else url

    def request(self, method: str, path: str, *, params: Optional[dict] = None,
                json_body: Any = None) -> Any:
        """Issue an authenticated JSON request and return the decoded body (or None)."""
        data = None
        req = urllib.request.Request(self._url(path, params), method=method)
        if json_body is not None:
            data = json.dumps(json_body).encode("utf-8")
            req.data = data
            req.add_header("Content-Type", "application/json")
        _, body, _ = self._open(req)
        return json.loads(body) if body else None

    def get_bytes(self, path: str) -> bytes:
        """GET a binary payload (e.g. an export zip)."""
        _, body, _ = self._open(urllib.request.Request(self._url(path), method="GET"))
        return body

    def send_multipart(self, method: str, path: str, *, field: str, filename: str,
                       content: bytes) -> Any:
        """Send a single-file multipart/form-data body (POST/PUT) and return decoded JSON."""
        boundary = uuid.uuid4().hex
        mime = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        body = b"".join([
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'.encode(),
            f"Content-Type: {mime}\r\n\r\n".encode(),
            content,
            f"\r\n--{boundary}--\r\n".encode(),
        ])
        req = urllib.request.Request(self._url(path), data=body, method=method)
        req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
        _, resp, _ = self._open(req)
        return json.loads(resp) if resp else None

    def paginate(self, path: str, **params: Any) -> Iterator[dict]:
        """Yield every item across a paginated list endpoint, following `next`."""
        page = self.request("GET", path, params=params)
        while page:
            yield from page.get("data", [])
            nxt = page.get("next")
            if not page.get("has_more") or not nxt:
                return
            page = self.request("GET", nxt)

    # --- agents ------------------------------------------------------------
    def list_agents(self, name: Optional[str] = None) -> Iterator[dict]:
        return self.paginate("/agents", name=name)

    def get_agent(self, agent_id: str) -> dict:
        return self.request("GET", f"/agents/{agent_id}")

    def get_agent_state(self, agent_id: str) -> dict:
        """GET /agents/{id}/state -> {state, live_version_id, has_draft}."""
        return self.request("GET", f"/agents/{agent_id}/state")

    def export_agent(self, agent_id: str) -> bytes:
        """GET /agents/{id}/export -> raw zip bytes (application/zip)."""
        return self.get_bytes(f"/agents/{agent_id}/export")

    def import_agent(self, zip_bytes: bytes, filename: str = "agent.zip") -> dict:
        """POST /agents/import (multipart, field 'file') -> PublicImportedAgent.

        CREATES a new agent. The response includes `unresolved_mcp_servers` for
        package MCP servers with no matching workspace server.
        """
        return self.send_multipart("POST", "/agents/import", field="file",
                                   filename=filename, content=zip_bytes)

    def update_import(self, agent_id: str, zip_bytes: bytes, filename: str = "agent.zip") -> dict:
        """PUT /agents/{id}/import -> update the existing agent's draft from a zip.

        Overwrites the agent in place (creates/updates its draft; the live version
        stays until you publish). Idempotent; shared files are add-only. Returns a
        PublicImportedAgent with `unresolved_mcp_servers`.
        """
        return self.send_multipart("PUT", f"/agents/{agent_id}/import", field="file",
                                   filename=filename, content=zip_bytes)

    def edit_agent(self, agent_id: str) -> dict:
        """POST /agents/{id}/edit -> flip to DRAFT (idempotent)."""
        return self.request("POST", f"/agents/{agent_id}/edit")

    def patch_agent(self, agent_id: str, **fields: Any) -> dict:
        """PATCH /agents/{id} -> update name / description / runbook_text only."""
        return self.request("PATCH", f"/agents/{agent_id}", json_body=fields)

    def publish_agent(self, agent_id: str, **body: Any) -> dict:
        """POST /agents/{id}/publish -> snapshot draft as a new live version.

        A (possibly empty) JSON body is required; pass connection_mappings /
        mcp_server_mappings to remap test references to prod on publish.
        """
        return self.request("POST", f"/agents/{agent_id}/publish", json_body=dict(body))

    def discard_draft(self, agent_id: str, **body: Any) -> dict:
        """POST /agents/{id}/discard-draft -> revert draft to the live version."""
        return self.request("POST", f"/agents/{agent_id}/discard-draft", json_body=dict(body))
