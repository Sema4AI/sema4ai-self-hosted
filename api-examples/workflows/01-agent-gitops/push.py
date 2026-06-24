#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml>=6"]
# ///
"""Reconcile a git-tracked agent repo onto its live agent and publish.

    uv run push.py --repo ./my-agent --mode draft|live
    uv run push.py --repo ./my-agent --simulate

Compares the repo against the agent's actual current state (by exporting it) — no
git diffing, no flags to remember. Whatever differs is detected automatically.

Steps:
  1. Read .sema4/target.yaml -> agent_id.
  2. Export the live agent and compare it to the repo:
       - name / description / runbook_text  -> applied via PATCH
       - any other field that differs (model, agent-settings, welcome-message,
         document-intelligence, mcp-servers, semantic-data-models, shared files)
         can't be applied in place yet -> reported and the run is refused, so a
         partial version is never published.
  3. POST /agents/{id}/edit -> DRAFT (skipped if the lifecycle flag is off).
  4. PATCH the supported fields.
  5. --mode live: POST /agents/{id}/publish.  --mode draft: stop, leaving the
     change staged for UI review.

With --simulate, stops after step 2: prints what would change and the action a
real run would take, without calling any write endpoint.
"""

from __future__ import annotations

import argparse
import difflib
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import yaml  # noqa: E402

from lib import agentpack  # noqa: E402
from lib.client import ApiError, SemaClient  # noqa: E402
from lib.config import load  # noqa: E402

# Spec fields push.py can apply to an existing agent today (runbook handled via its file).
SUPPORTED_SPEC_FIELDS = {"name", "description", "runbook"}

_COLOR = ((sys.stdout.isatty() or os.environ.get("FORCE_COLOR"))
          and os.environ.get("NO_COLOR") is None)
RULE = "─" * 64


def _c(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _COLOR else text


def green(t: str) -> str: return _c("32", t)
def red(t: str) -> str: return _c("31", t)
def yellow(t: str) -> str: return _c("33", t)
def bold(t: str) -> str: return _c("1", t)
def dim(t: str) -> str: return _c("2", t)


def _diff_line(line: str) -> str:
    if line.startswith("+"):
        return green(line)
    if line.startswith("-"):
        return red(line)
    if line.startswith("@@"):
        return dim(line)
    return line


def _agent(spec: dict) -> dict:
    return spec["agent-package"]["agents"][0]


def _read_tree(root: Path) -> tuple[dict, str, dict[str, bytes]]:
    """Return (agent dict, runbook text, {shared-file name: bytes}) for an agent tree."""
    spec = yaml.safe_load((root / "agent-spec.yaml").read_text())
    agent = _agent(spec)
    runbook = (root / agent.get("runbook", "runbook.md")).read_text()
    files_dir = root / "agent-files"
    files = {p.name: p.read_bytes() for p in files_dir.iterdir()} if files_dir.is_dir() else {}
    return agent, runbook, files


def _diff(repo: Path, client: SemaClient, agent_id: str) -> tuple[dict, str, list[str]]:
    """Compare repo desired-state to the live agent's actual state.

    Returns (patch, current_name, blocking) where patch holds the applicable field
    changes and blocking lists changes that can't be applied in place yet.
    """
    want_agent, want_runbook, want_files = _read_tree(repo)
    with tempfile.TemporaryDirectory() as tmp:
        agentpack.unpack(client.export_agent(agent_id), Path(tmp))
        have_agent, have_runbook, have_files = _read_tree(Path(tmp))

    patch: dict = {}
    if want_agent.get("name") != have_agent.get("name"):
        patch["name"] = want_agent.get("name")
    if want_agent.get("description") != have_agent.get("description"):
        patch["description"] = want_agent.get("description")
    if want_runbook != have_runbook:
        patch["runbook_text"] = want_runbook

    blocking: list[str] = []
    for key in sorted(set(want_agent) | set(have_agent)):
        if key in SUPPORTED_SPEC_FIELDS:
            continue
        if want_agent.get(key) != have_agent.get(key):
            blocking.append(f"agent-spec.yaml: {key}")
    for name in sorted(set(want_files) | set(have_files)):
        if want_files.get(name) != have_files.get(name):
            blocking.append(f"agent-files/{name}")

    return patch, have_agent.get("name", ""), blocking


def _report(name: str, patch: dict, runbook_diff: list[str], blocking: list[str],
            mode: str, pending_draft: bool) -> None:
    """Print the comparison and the action a real run would take, in clear sections."""
    print()
    print(bold(f"  SIMULATION  ") + dim(f"agent '{name}' · no changes made"))
    print(RULE)

    if not patch and not blocking:
        print(dim("  No differences — the agent already matches the repo."))

    if patch:
        print(green(bold(f"  ✓ WILL APPLY  ({len(patch)})")))
        for field in patch:
            if field == "runbook_text":
                print(f"      • runbook_text")
                for line in runbook_diff:
                    if line.startswith(("---", "+++")):
                        continue
                    print("          " + _diff_line(line))
            else:
                print(f"      • {field}  →  {patch[field]!r}")
        print()

    if blocking:
        print(red(bold(f"  ✗ BLOCKED  ({len(blocking)})")) + dim("  can't be applied to a live agent yet"))
        for item in blocking:
            print(red(f"      • {item}"))
        print()

    print(RULE)
    label = dim(f"  Run without --simulate (--mode {mode}):  ")
    if blocking:
        print(label + red(bold("REFUSED")) + " — exit 1 until the blocked changes above are removed.")
    elif mode == "live" and (patch or pending_draft):
        what = "your edits" if patch else "the already-staged draft"
        print(label + green(bold("PUBLISH")) + f" — {what} become a new live version.")
    elif mode == "draft" and patch:
        print(label + yellow(bold("STAGE DRAFT")) + " — staged for review; live version untouched.")
    else:
        print(label + dim("nothing would change."))
    print()


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True, help="Path to the git-tracked agent repo.")
    parser.add_argument("--mode", choices=["draft", "live"], default="draft",
                        help="draft: stage for review (default). live: publish a new live version.")
    parser.add_argument("--simulate", action="store_true",
                        help="compare to the live agent and report; apply nothing")
    args = parser.parse_args()

    repo = Path(args.repo)
    target = yaml.safe_load((repo / ".sema4" / "target.yaml").read_text())
    agent_id = target["agent_id"]
    client = SemaClient(load())

    patch, name, blocking = _diff(repo, client, agent_id)
    runbook_diff: list[str] = []
    if "runbook_text" in patch:
        # recompute the unified diff for display
        _, want_runbook, _ = _read_tree(repo)
        current = client.get_agent(agent_id).get("runbook_text") or ""
        runbook_diff = list(difflib.unified_diff(
            str(current).splitlines(), str(want_runbook).splitlines(),
            fromfile="live", tofile="repo", lineterm=""))

    # Lifecycle support + whether a draft is already staged.
    try:
        lifecycle = True
        pending_draft = bool(client.get_agent_state(agent_id).get("has_draft"))
    except ApiError:
        lifecycle, pending_draft = False, False

    if args.simulate:
        _report(name, patch, runbook_diff, blocking, args.mode, pending_draft)
        return

    if blocking:
        print(red(bold(f"  ✗ REFUSED  ({len(blocking)})")) + dim("  these can't be applied to a live agent yet:"))
        for item in blocking:
            print(red(f"      • {item}"))
        sys.exit(1)

    if not patch and not (args.mode == "live" and pending_draft):
        print(dim("Nothing to apply — agent already matches the repo."))
        return

    if patch:
        print(green(bold("  ✓ APPLYING  ")) + f"{', '.join(patch)}")
        if lifecycle:
            client.edit_agent(agent_id)
        client.patch_agent(agent_id, **patch)

    if args.mode == "live":
        if lifecycle:
            client.publish_agent(agent_id)
            print(green(bold("  ✓ PUBLISHED  ")) + "a new live version.")
        else:
            print(green(bold("  ✓ APPLIED  ")) + "directly (lifecycle flag off).")
    else:
        print(yellow(bold("  ✓ STAGED  ")) + "as a draft — review and publish in the UI.")


if __name__ == "__main__":
    main()
