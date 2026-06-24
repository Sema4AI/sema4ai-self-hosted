#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml>=6"]
# ///
"""Reconcile a git-tracked agent repo onto its live agent and publish.

    uv run push.py --repo ./my-agent --mode draft|live [--base <git-ref>]
    uv run push.py --repo ./my-agent --simulate [--base <git-ref>]

Steps:
  1. Read .sema4/target.yaml -> agent_id.
  2. Compute supported edits by comparing the repo's desired state (runbook.md,
     name/description in agent-spec.yaml) against the published agent.
  3. If --base is given, guard against UNSUPPORTED edits: any changed file other
     than runbook.md / name+description in agent-spec.yaml (model, agent-settings,
     welcome-message, document-intelligence, shared files, SDM/MCP content) cannot
     yet be applied in place (EPD-7051) -> fail loudly instead of publishing a
     partial version.
  4. POST /agents/{id}/edit -> DRAFT (skipped if the lifecycle flag is off).
  5. PATCH the supported fields.
  6. --mode live: POST /agents/{id}/publish.  --mode draft: stop, leaving the
     change staged for UI review.

With --simulate, stops after step 3: prints what would change vs the published
version (and what is blocked) without calling edit/patch/publish.
"""

from __future__ import annotations

import argparse
import difflib
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


def _report(current: dict, patch: dict, blocking: list[str], mode: str,
            pending_draft: bool) -> None:
    """Print a comparison of the repo vs the published agent and the action a real run would take."""
    print(f"SIMULATION — no changes made. Comparing repo against published agent "
          f"'{current['name']}':\n")
    if not patch and not blocking:
        print("  (no differences — agent already matches the repo)")
    for field, new in patch.items():
        old = current.get(field) or ""
        if field == "runbook_text":
            diff = difflib.unified_diff(
                str(old).splitlines(), str(new).splitlines(),
                fromfile="published", tofile="repo", lineterm="")
            print(f"  ~ {field}:")
            for line in diff:
                print(f"      {line}")
        else:
            print(f"  ~ {field}:  {old!r} -> {new!r}")
    for item in blocking:
        print(f"  ✗ blocked: {item}")
    summary = f"\n{len(patch)} field(s) would be applied"
    if blocking:
        summary += f", {len(blocking)} change(s) blocked"
    print(summary + ".")

    # Spell out what running WITHOUT --simulate (at this --mode) would do.
    print()
    if blocking:
        print(f"==> Without --simulate (--mode {mode}): this would be REFUSED and exit 1 "
              "because of the blocked change(s) above.")
    elif mode == "live" and (patch or pending_draft):
        what = "your edits" if patch else "the already-staged draft"
        print(f"==> Without --simulate (--mode live): this WILL PUBLISH {what} as a new live version.")
    elif mode == "draft" and patch:
        print("==> Without --simulate (--mode draft): this WILL STAGE a draft "
              "(the live version stays untouched).")
    else:
        print(f"==> Without --simulate (--mode {mode}): nothing would change.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True, help="Path to the git-tracked agent repo.")
    parser.add_argument("--mode", choices=["draft", "live"], default="draft",
                        help="draft: stage for review (default). live: publish a new live version.")
    parser.add_argument("--base", help="git ref to diff against for unsupported-change detection")
    parser.add_argument("--simulate", action="store_true",
                        help="compare to the published version and report; apply nothing")
    args = parser.parse_args()

    repo = Path(args.repo)
    target = yaml.safe_load((repo / ".sema4" / "target.yaml").read_text())
    agent_id = target["agent_id"]
    client = SemaClient(load())

    blocking = _blocking_changes(repo, args.base) if args.base else []
    desired = _desired(repo)
    current = client.get_agent(agent_id)
    patch = {k: v for k, v in desired.items() if v is not None and v != current.get(k)}

    # Lifecycle support + whether a draft is already staged (mirrors what a real run sees).
    try:
        lifecycle = True
        pending_draft = bool(client.get_agent_state(agent_id).get("has_draft"))
    except ApiError:
        lifecycle, pending_draft = False, False  # flag off — PATCH affects live directly

    if args.simulate:
        _report(current, patch, blocking, args.mode, pending_draft)
        return

    if blocking:
        print("Refusing to publish — these changes cannot be applied to a live agent yet:")
        for item in blocking:
            print(f"  - {item}")
        sys.exit(1)

    # In live mode an existing draft is publishable even when the repo adds no new diff.
    if not patch and not (args.mode == "live" and pending_draft):
        print("Nothing to apply — agent already matches the published version.")
        return

    if patch:
        print(f"Applying to '{current['name']}': {', '.join(patch)}")
        if lifecycle:
            client.edit_agent(agent_id)  # enter DRAFT
        client.patch_agent(agent_id, **patch)

    if args.mode == "live":
        if lifecycle:
            client.publish_agent(agent_id)
            print("Published a new live version.")
        else:
            print("Applied directly (lifecycle flag off).")
    else:
        print("Staged as a draft — review and publish in the UI.")


if __name__ == "__main__":
    main()
