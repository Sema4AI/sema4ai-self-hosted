"""Convert an agent export zip to/from a flat, git-friendly directory tree.

An export zip looks like:

    agent-spec.yaml                  # declarative manifest (refs runbook/SDMs/files; MCP inline)
    runbook.md                       # agent instructions
    semantic-data-models/*.yaml      # SDMs as YAML
    agent-files/<uuid>               # shared files, stored under opaque UUIDs

For version control we want a tree that diffs cleanly. Two transforms matter:

  1. Shared files: on UNPACK, rename each `agent-files/<uuid>` blob to its human
     name from the manifest (e.g. agent-files/orders.xlsx) so git diffs are legible;
     on PACK, map back to the file-ref the manifest expects.

  2. Secrets: exports redact secret values (e.g. MCP headers -> '**********').
     On PACK, re-inject real values from the environment so the package is
     deployable. Never commit real secrets to git.
"""

from __future__ import annotations

from pathlib import Path


def unpack(zip_bytes: bytes, dest: Path) -> None:
    """Write a git-friendly tree of the agent into `dest`.

    TODO: extract zip; rename agent-files/<uuid> -> agent-files/<human-name>;
    leave agent-spec.yaml / runbook.md / SDMs as-is; clean dest first so
    deletions show up as diffs.
    """
    raise NotImplementedError


def pack(tree: Path) -> bytes:
    """Re-zip a tree back into the import package format and return the bytes.

    TODO: map agent-files/<human-name> back to the manifest file-ref;
    re-inject secrets from env into agent-spec.yaml; produce a zip the
    import endpoint accepts.
    """
    raise NotImplementedError
