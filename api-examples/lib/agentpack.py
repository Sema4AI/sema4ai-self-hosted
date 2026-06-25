"""Convert an agent export zip to/from a flat, git-friendly directory tree.

An export zip looks like:

    agent-spec.yaml                  # declarative manifest (refs runbook/SDMs/files; MCP inline)
    runbook.md                       # agent instructions
    semantic-data-models/*.yaml      # SDMs as YAML
    agent-files/<uuid>               # shared files, stored under opaque UUIDs

For version control we want a tree that diffs cleanly. Two transforms matter:

  1. Shared files: the export stores blobs under an opaque UUID and the import
     requires that UUID as the `file-ref`. On UNPACK we keep `file-ref` as the
     UUID (so PACK can restore the exact import layout) but rename the blob on
     disk to its human name and point the manifest's `name` at it — so git diffs
     are legible. PACK writes each blob back under its `file-ref` UUID.

  2. Secrets: exports redact secret values (e.g. MCP headers -> '**********').
     On PACK, real values are injected from the environment so the package is
     deployable. Never commit real secrets to git.

Depends on PyYAML (preinstalled on GitHub runners).
"""

from __future__ import annotations

import io
import shutil
import zipfile
from pathlib import Path

import yaml

SPEC_NAME = "agent-spec.yaml"
KEEP = {".git", ".sema4"}  # never wiped when refreshing a tree in place


def _agents(spec: dict) -> list:
    return spec.get("agent-package", {}).get("agents", []) or []


def _load_spec(root: Path) -> dict:
    return yaml.safe_load((root / SPEC_NAME).read_text())


def _dump_spec(root: Path, spec: dict) -> None:
    (root / SPEC_NAME).write_text(yaml.safe_dump(spec, sort_keys=False, allow_unicode=True))


def _safe_name(name: str) -> str:
    """Filesystem-safe basename, preserving the human name where possible."""
    return "".join(c if c not in '/\\\0' else "_" for c in name).strip() or "file"


def unpack(zip_bytes: bytes, dest: Path) -> None:
    """Write a git-friendly tree of the agent into `dest`.

    Cleans `dest` (except .git/.sema4) so deletions show up as diffs, extracts the
    zip, then renames shared-file blobs from UUIDs to human names and rewrites the
    manifest to match.
    """
    dest.mkdir(parents=True, exist_ok=True)
    for child in dest.iterdir():
        if child.name in KEEP:
            continue
        shutil.rmtree(child) if child.is_dir() else child.unlink()

    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
        zf.extractall(dest)

    spec = _load_spec(dest)
    files_dir = dest / "agent-files"
    for agent in _agents(spec):
        used: set[str] = set()
        for entry in agent.get("shared-files", []) or []:
            ref = entry.get("file-ref")
            human = _safe_name(entry.get("name") or ref or "")
            # disambiguate collisions
            candidate, i = human, 1
            while candidate in used:
                stem, dot, ext = human.partition(".")
                candidate = f"{stem}-{i}{dot}{ext}"
                i += 1
            used.add(candidate)
            if ref and ref != candidate and (files_dir / ref).exists():
                (files_dir / ref).rename(files_dir / candidate)
            # keep file-ref as the UUID (import needs it); name = on-disk filename
            entry["name"] = candidate
    _dump_spec(dest, spec)


def pack(tree: Path) -> bytes:
    """Re-zip a tree back into the import package format and return the bytes.

    The tree must already be in the on-disk layout the import endpoint expects
    (shared files keyed by the manifest's file-ref) with any secrets resolved —
    callers that need per-environment values/secrets render them into the tree
    first (see workflows/05-distribute-agent).
    """
    spec = _load_spec(tree)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(tree.rglob("*")):
            if path.is_dir():
                continue
            rel = path.relative_to(tree)
            if rel.parts[0] in KEEP or rel.parts[0] == "agent-files":
                continue  # shared files are written below, under their UUID file-ref
            zf.write(path, rel.as_posix())
        # shared files: human name on disk -> UUID file-ref in the package
        for agent in _agents(spec):
            for entry in agent.get("shared-files") or []:
                src = tree / "agent-files" / (entry.get("name") or "")
                if entry.get("file-ref") and src.is_file():
                    zf.write(src, f"agent-files/{entry['file-ref']}")
    return buf.getvalue()
