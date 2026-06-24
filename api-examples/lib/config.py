"""Environment configuration shared by all workflows.

Reads SEMA4_BASE_URL and SEMA4_API_KEY from the environment. As a convenience for
local runs it will also load a `.env` file (simple KEY=VALUE lines) found in the
current directory or any parent. Standard library only.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Config:
    base_url: str
    api_key: str


def _load_dotenv() -> None:
    """Populate os.environ from the nearest .env file, without overriding real env vars."""
    for directory in [Path.cwd(), *Path.cwd().parents]:
        env_file = directory / ".env"
        if not env_file.is_file():
            continue
        for raw in env_file.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key, value = key.strip(), value.strip().strip("'\"")
            os.environ.setdefault(key, value)
        return


def load() -> Config:
    """Return a validated Config from the environment (and a local .env if present)."""
    _load_dotenv()
    base_url = os.environ.get("SEMA4_BASE_URL")
    api_key = os.environ.get("SEMA4_API_KEY")
    missing = [n for n, v in (("SEMA4_BASE_URL", base_url), ("SEMA4_API_KEY", api_key)) if not v]
    if missing:
        raise SystemExit(
            f"Missing required environment variable(s): {', '.join(missing)}. "
            "Copy .env.example to .env and fill them in, or export them."
        )
    return Config(base_url=base_url.rstrip("/"), api_key=api_key)
