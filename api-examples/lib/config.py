"""Environment / profile configuration shared by all workflows.

Two ways to point a tool at a workspace:

  1. Env vars SEMA4_BASE_URL + SEMA4_API_KEY (single workspace; also loads a local .env).
  2. A named profile, for operating several workspaces. Profiles live in a YAML file
     found via $SEMA4_PROFILES, ./sema4-profiles.yaml, or ~/.sema4/profiles.yaml:

         profiles:
           golden:  { base_url: https://a.../api/v2, api_key: ${GOLDEN_KEY} }
           prod-eu: { base_url: https://eu.../api/v2, api_key: ${EU_KEY},
                      secrets: prod-eu.secrets.env }     # optional, auto-loaded on apply

     api_key / base_url may use ${ENV} refs so the file stays free of literal secrets.

Stdlib only, except a lazy PyYAML import used only when a profile is requested.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path

_REF = re.compile(r"\$\{(\w+)\}")


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
            os.environ.setdefault(key.strip(), value.strip().strip("'\""))
        return


def _expand(value: str) -> str:
    return _REF.sub(lambda m: os.environ.get(m.group(1), m.group(0)), value or "")


def _profiles_path() -> Path | None:
    for cand in (os.environ.get("SEMA4_PROFILES"), "sema4-profiles.yaml",
                 str(Path.home() / ".sema4" / "profiles.yaml")):
        if cand and Path(cand).is_file():
            return Path(cand)
    return None


def get_profile(name: str) -> dict:
    """Return the raw profile mapping for `name` (or exit with a clear error)."""
    import yaml  # lazy — only needed when profiles are used
    path = _profiles_path()
    if not path:
        raise SystemExit("no profiles file (set SEMA4_PROFILES, or add ./sema4-profiles.yaml "
                         "or ~/.sema4/profiles.yaml)")
    profiles = (yaml.safe_load(path.read_text()) or {}).get("profiles") or {}
    if name not in profiles:
        raise SystemExit(f"profile '{name}' not found in {path} "
                         f"(have: {', '.join(profiles) or 'none'})")
    return profiles[name] or {}


def load(profile: str | None = None) -> Config:
    """Return a validated Config from a named profile, or from the environment."""
    _load_dotenv()
    if profile:
        p = get_profile(profile)
        base_url, api_key = _expand(p.get("base_url", "")), _expand(p.get("api_key", ""))
        if not base_url or not api_key:
            raise SystemExit(f"profile '{profile}' must set base_url and api_key")
        return Config(base_url=base_url.rstrip("/"), api_key=api_key)

    base_url = os.environ.get("SEMA4_BASE_URL")
    api_key = os.environ.get("SEMA4_API_KEY")
    missing = [n for n, v in (("SEMA4_BASE_URL", base_url), ("SEMA4_API_KEY", api_key)) if not v]
    if missing:
        raise SystemExit(
            f"Missing required environment variable(s): {', '.join(missing)}. "
            "Set them, use --profile, or copy .env.example to .env."
        )
    return Config(base_url=base_url.rstrip("/"), api_key=api_key)
