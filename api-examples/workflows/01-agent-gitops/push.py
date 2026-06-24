#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml>=6"]
# ///
"""Reconcile a git-tracked agent repo onto its live agent and publish.

    uv run push.py --repo ./my-agent --mode draft|live [--base <git-ref>]

Steps:
  1. Read .sema4/target.yaml -> agent_id.
  2. Compute supported edits by comparing the repo's desired state (runbook.md,
     name/description in agent-spec.yaml) against the live agent.
  3. If --base is given, guard against UNSUPPORTED edits: any changed file other
     than runbook.md / name+description in agent-spec.yaml (model, agent-settings,
     welcome-message, document-intelligence, shared files, SDM/MCP content) cannot
     yet be applied in place (EPD-7051) -> fail loudly instead of publishing a
     partial version.
  4. POST /agents/{id}/edit -> DRAFT (skipped if the lifecycle flag is off).
  5. PATCH the supported fields.
  6. --mode live: POST /agents/{id}/publish.  --mode draft: stop, leaving the
     change staged for UI review.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import yaml  # noqa: E402

from lib.client import ApiError, SemaClient  # noqa: E402
from lib.config import load  # noqa: E402

# Fields the API can apply to an existing agent today.
SUPPORTED_SPEC_FIELDS = {"name", "description"}
# Paths whose changes we can apply (anything else is blocking when --base is set).
SUPPORTED_PATHS = {"runbook.md", "agent-spec.yaml"}


def _agent(spec: dict) -> dict:
    return spec["agent-package"]["agents"][0]


def _desired(repo: Path) -> dict:
    spec = yaml.safe_load((repo / "agent-spec.yaml").read_text())
    agent = _agent(spec)
    return {
        "name": agent.get("name"),
        "description": agent.get("description"),
        "runbook_text": (repo / agent.get("runbook", "runbook.md")).read_text(),
    }


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args],
                          capture_output=True, text=True, check=True).stdout


def _blocking_changes(repo: Path, base: str) -> list[str]:
    """Return human-readable descriptions of changes we cannot apply in place."""
    changed = [p for p in _git(repo, "diff", "--name-only", f"{base}..HEAD").splitlines() if p]
    blocking: list[str] = []
    for path in changed:
        if path.startswith(".sema4/"):
            continue
        if path not in SUPPORTED_PATHS:
            blocking.append(f"{path} (no in-place update path yet — EPD-7051)")
            continue
        if path == "agent-spec.yaml":
            old = yaml.safe_load(_git(repo, "show", f"{base}:agent-spec.yaml")) or {}
            new = yaml.safe_load((repo / "agent-spec.yaml").read_text()) or {}
            old_a, new_a = _agent(old), _agent(new)
            for key in set(old_a) | set(new_a):
                if key in SUPPORTED_SPEC_FIELDS or key == "runbook":
                    continue
                if old_a.get(key) != new_a.get(key):
                    blocking.append(f"agent-spec.yaml: '{key}' changed (not patchable yet — EPD-7051)")
    return blocking


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--mode", choices=["draft", "live"], default="draft")
    parser.add_argument("--base", help="git ref to diff against for unsupported-change detection")
    args = parser.parse_args()

    repo = Path(args.repo)
    target = yaml.safe_load((repo / ".sema4" / "target.yaml").read_text())
    agent_id = target["agent_id"]
    client = SemaClient(load())

    if args.base:
        blocking = _blocking_changes(repo, args.base)
        if blocking:
            print("Refusing to publish — these changes cannot be applied to a live agent yet:")
            for item in blocking:
                print(f"  - {item}")
            sys.exit(1)

    desired = _desired(repo)
    current = client.get_agent(agent_id)
    patch = {k: v for k, v in desired.items() if v is not None and v != current.get(k)}
    if not patch:
        print("Nothing to apply — agent already matches the repo.")
        return
    print(f"Applying to '{current['name']}': {', '.join(patch)}")

    try:
        client.edit_agent(agent_id)  # enter DRAFT if the lifecycle flag is on
        lifecycle = True
    except ApiError:
        lifecycle = False  # flag off — PATCH affects the live agent directly

    client.patch_agent(agent_id, **patch)

    if args.mode == "live" and lifecycle:
        client.publish_agent(agent_id)
        print("Published a new live version.")
    elif args.mode == "live":
        print("Applied directly (lifecycle flag off).")
    else:
        print("Staged as a draft — review and publish in the UI.")


if __name__ == "__main__":
    main()
