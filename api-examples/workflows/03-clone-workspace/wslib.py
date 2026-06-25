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

# Value patterns that are secrets regardless of the key name (e.g. an AWS key stored
# as an SMTP username). Mirrors what secret scanners flag — the last line of defense.
_SECRET_VALUE = re.compile(
    r"AKIA[0-9A-Z]{16}"            # AWS access key id
    r"|ASIA[0-9A-Z]{16}"          # AWS temporary access key id
    r"|\bsk-[A-Za-z0-9]{20,}"     # OpenAI / Anthropic keys (\b avoids matching e.g. 'helpdesk-...')
    r"|s4w_[0-9a-f]{64}"          # Sema4 platform key
    r"|xox[baprs]-[0-9A-Za-z-]{10,}"   # Slack
    r"|gh[pousr]_[A-Za-z0-9]{36,}"     # GitHub tokens
    r"|github_pat_[A-Za-z0-9_]{40,}"
)

_PLACEHOLDER = re.compile(r"\$\{(\w+)\}")  # ${NAME} — note: ${env:..} (platform) won't match


def looks_secret(value: str) -> bool:
    return bool(_SECRET_VALUE.search(value))


def is_secret_key(key: str) -> bool:
    # Normalize separators so hyphenated header names (e.g. X-Api-Key, X-Aws-Access-Key-Id)
    # match the underscore hints (api_key, access_key).
    norm = re.sub(r"[^a-z0-9]", "", key.lower())
    return any(re.sub(r"[^a-z0-9]", "", hint) in norm for hint in SECRET_HINTS)


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
    if isinstance(value, str) and value and (is_secret_key(key) or looks_secret(value)):
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
