"""Shared helpers for workspace export/apply: secret redaction and resolution.

Workspace config endpoints return secrets in plaintext (DB passwords, AWS keys,
MCP/observability API keys). export.py redacts them to ${ENV_VAR} placeholders so
workspace.yaml is safe to share; apply.py resolves them back from the environment.
"""

from __future__ import annotations

import os
import re

# Substrings that mark a config key as holding a secret value.
SECRET_HINTS = ("password", "secret", "api_key", "apikey", "access_key",
                "token", "private_key", "client_secret", "passwd")

_PLACEHOLDER = re.compile(r"\$\{(\w+)\}")  # ${NAME} — note: ${env:..} (platform) won't match


def is_secret_key(key: str) -> bool:
    low = key.lower()
    return any(hint in low for hint in SECRET_HINTS)


def slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "_", str(text)).strip("_").upper() or "X"


def _unique(name: str, used: set) -> str:
    candidate, i = name, 2
    while candidate in used:
        candidate = f"{name}_{i}"
        i += 1
    used.add(candidate)
    return candidate


def redact(value, prefix: str, key: str, secrets: dict, used: set):
    """Return `value` with secret leaves replaced by ${ENV} placeholders.

    Records placeholder name -> real value in `secrets`. Handles both keyword-named
    secret fields and the MCP {type: secret, value: ...} shape.
    """
    if isinstance(value, dict):
        if value.get("type") == "secret" and isinstance(value.get("value"), str):
            env = _unique(f"{prefix}_{slug(key)}", used)
            secrets[env] = value["value"]
            return {**value, "value": f"${{{env}}}"}
        return {k: redact(v, prefix, k, secrets, used) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v, prefix, key, secrets, used) for v in value]
    if isinstance(value, str) and is_secret_key(key) and value:
        env = _unique(f"{prefix}_{slug(key)}", used)
        secrets[env] = value
        return f"${{{env}}}"
    return value


def resolve(value, missing: set):
    """Return `value` with ${ENV} placeholders replaced from os.environ.

    Unknown placeholders are collected in `missing`. The platform's own ${env:..}
    syntax (contains a colon) is left untouched.
    """
    if isinstance(value, dict):
        return {k: resolve(v, missing) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v, missing) for v in value]
    if isinstance(value, str):
        def sub(match):
            name = match.group(1)
            if name in os.environ:
                return os.environ[name]
            missing.add(name)
            return match.group(0)
        return _PLACEHOLDER.sub(sub, value)
    return value
