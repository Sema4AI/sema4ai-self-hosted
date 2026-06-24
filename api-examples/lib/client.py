"""Thin HTTP client for the Sema4.ai v2 API.

Wraps urllib so the workflows have no third-party dependencies. Handles auth,
JSON encode/decode, pagination, and the agent export/import endpoints.
"""

from __future__ import annotations

from typing import Any, Iterator, Optional

from .config import Config


class SemaClient:
    def __init__(self, config: Config) -> None:
        self._config = config

    # --- low-level ---------------------------------------------------------
    def request(self, method: str, path: str, **kwargs: Any) -> Any:
        """Issue an authenticated request and return decoded JSON.

        TODO: set Authorization: Bearer header, join base_url + path,
        encode JSON body, raise on non-2xx with the server's error envelope.
        """
        raise NotImplementedError

    def paginate(self, path: str, **params: Any) -> Iterator[dict]:
        """Yield every item across a paginated list endpoint.

        The list endpoints return {data: [...], next, has_more}. Follow `next`
        until has_more is false.
        """
        raise NotImplementedError

    # --- agents ------------------------------------------------------------
    def list_agents(self, name: Optional[str] = None) -> Iterator[dict]:
        raise NotImplementedError

    def get_agent_state(self, agent_id: str) -> dict:
        """GET /agents/{id}/state -> {state, live_version_id, has_draft}."""
        raise NotImplementedError

    def export_agent(self, agent_id: str) -> bytes:
        """GET /agents/{id}/export -> raw zip bytes (application/zip)."""
        raise NotImplementedError

    def import_agent(self, zip_bytes: bytes) -> dict:
        """POST /agents/import (multipart, field 'file') -> created agent.

        NOTE: today this always CREATES a new agent. Updating an existing
        agent in place is tracked in EPD-7051.
        """
        raise NotImplementedError

    def edit_agent(self, agent_id: str) -> dict:
        """POST /agents/{id}/edit -> flip to DRAFT (idempotent)."""
        raise NotImplementedError

    def patch_agent(self, agent_id: str, **fields: Any) -> dict:
        """PATCH /agents/{id} -> update name / description / runbook_text only."""
        raise NotImplementedError

    def publish_agent(self, agent_id: str, **body: Any) -> dict:
        """POST /agents/{id}/publish -> snapshot draft as a new live version."""
        raise NotImplementedError
