"""Environment configuration shared by all workflows.

Reads SEMA4_BASE_URL and SEMA4_API_KEY from the environment (or a local .env).
Stdlib only.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    base_url: str
    api_key: str


def load() -> Config:
    """Return a validated Config from the environment.

    TODO: optionally load a sibling .env file (simple KEY=VALUE parser, no dependency).
    TODO: raise a clear error naming the missing variable.
    """
    raise NotImplementedError
