#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml>=6"]
# ///
"""Reconcile a git-tracked agent repo onto its live agent and publish.

    uv run push.py --repo ./my-agent                 # --mode dryrun (default): preview only
    uv run push.py --repo ./my-agent --mode draft    # import into the agent's draft
    uv run push.py --repo ./my-agent --mode live     # import + publish a new live version

Applies the whole package via `PUT /agents/{id}/import`, so any change is carried —
runbook, name/description, model, settings, welcome message, SDMs, and shared files.
The import creates/updates the agent's DRAFT; the live version stays until you publish.
MCP servers are matched to existing workspace servers by name+URL and attached; any
unresolved ones are reported so you can create + attach them.

Steps:
  1. Read .sema4/target.yaml -> agent_id (+ home profile).
  2. dryrun: export the live agent, compare to the repo, and print what would change.
  3. draft/live: pack the repo and PUT it into the agent's draft; live also publishes.
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


def _validate(repo: Path) -> list[str]:
    """Cheap local pre-flight: catch obvious breakage before talking to the API."""
    spec_path = repo / "agent-spec.yaml"
    if not spec_path.is_file():
        return [f"missing {spec_path.name}"]
    try:
        spec = yaml.safe_load(spec_path.read_text())
    except yaml.YAMLError as exc:
        return [f"agent-spec.yaml is not valid YAML: {exc}"]
    try:
        agent = _agent(spec)
    except (TypeError, KeyError, IndexError):
        return ["agent-spec.yaml: expected agent-package.agents[0]"]

    errors: list[str] = []
    if not agent.get("name"):
        errors.append("agent-spec.yaml: agent 'name' is required")
    runbook = agent.get("runbook", "runbook.md")
    if not (repo / runbook).is_file():
        errors.append(f"runbook file '{runbook}' (agent-spec.yaml) is missing")
    for entry in agent.get("shared-files") or []:
        nm = entry.get("name")
        if nm and not (repo / "agent-files" / nm).is_file():
            errors.append(f"shared file 'agent-files/{nm}' is referenced but missing")
    for entry in agent.get("semantic-data-models") or []:
        nm = entry.get("name")
        if nm and not (repo / "semantic-data-models" / nm).is_file():
            errors.append(f"semantic data model 'semantic-data-models/{nm}' is referenced but missing")

    target = repo / ".sema4" / "target.yaml"
    if not target.is_file():
        errors.append("missing .sema4/target.yaml (run pull.py to create it)")
    else:
        try:
            if not (yaml.safe_load(target.read_text()) or {}).get("agent_id"):
                errors.append(".sema4/target.yaml: 'agent_id' is required")
        except yaml.YAMLError as exc:
            errors.append(f".sema4/target.yaml is not valid YAML: {exc}")
    return errors


def _read_tree(root: Path) -> tuple[dict, str, dict[str, bytes]]:
    """Return (agent dict, runbook text, {relative path: bytes}) for an agent tree.

    Fingerprints both agent-files and semantic-data-models so file-content edits are
    detected even when the manifest entry (name) is unchanged.
    """
    spec = yaml.safe_load((root / "agent-spec.yaml").read_text())
    agent = _agent(spec)
    runbook = (root / agent.get("runbook", "runbook.md")).read_text()
    files: dict[str, bytes] = {}
    for sub in ("agent-files", "semantic-data-models"):
        directory = root / sub
        if directory.is_dir():
            for path in directory.iterdir():
                if path.is_file():
                    files[f"{sub}/{path.name}"] = path.read_bytes()
    return agent, runbook, files


def _changes(repo: Path, client: SemaClient, agent_id: str) -> tuple[list, str]:
    """Compare the repo to the live agent. Returns (changes, live_name).

    Each change is (label, detail_lines). Everything is applicable via PUT import,
    so there is no "blocked" category.
    """
    want_agent, want_runbook, want_files = _read_tree(repo)
    with tempfile.TemporaryDirectory() as tmp:
        agentpack.unpack(client.export_agent(agent_id), Path(tmp))
        have_agent, have_runbook, have_files = _read_tree(Path(tmp))

    changes: list = []
    for key in sorted(set(want_agent) | set(have_agent)):
        if key == "runbook":
            continue  # compared as a file below
        if want_agent.get(key) != have_agent.get(key):
            changes.append((f"agent-spec: {key}", None))
    if want_runbook != have_runbook:
        diff = [ln for ln in difflib.unified_diff(
            str(have_runbook).splitlines(), str(want_runbook).splitlines(),
            lineterm="") if not ln.startswith(("---", "+++"))]
        changes.append(("runbook.md", diff))
    for rel in sorted(set(want_files) | set(have_files)):
        if want_files.get(rel) != have_files.get(rel):
            verb = "add" if rel not in have_files else "update"
            changes.append((f"{rel} ({verb})", None))
    return changes, have_agent.get("name", "")


def _report(name: str, changes: list) -> None:
    print()
    print(bold("  DRY RUN  ") + dim(f"agent '{name}' · no changes made"))
    print(RULE)
    if not changes:
        print(dim("  In sync — the agent already matches the repo."))
    else:
        print(green(bold(f"  ✓ WILL APPLY  ({len(changes)})")))
        for label, detail in changes:
            print(f"      • {label}")
            for line in (detail or []):
                print("          " + _diff_line(line))
    print(RULE)
    if changes:
        print(dim("  Preview · ") + "re-run with " + bold("--mode draft") +
              " to stage or " + bold("--mode live") + " to publish.")
    else:
        print(dim("  Preview · nothing to apply."))
    print(dim("  MCP servers are matched to existing workspace servers on import; "
              "unresolved ones are reported on apply."))
    print()


def _apply(client: SemaClient, agent_id: str, repo: Path, mode: str) -> None:
    result = client.update_import(agent_id, agentpack.pack(repo))
    print(green(bold("  ✓ IMPORTED  ")) + f"updated the draft of '{result.get('name', '')}'")

    for mcp in result.get("unresolved_mcp_servers") or []:
        print(yellow(f"      ⚠ unresolved MCP server: {mcp.get('name')} "
                     f"({mcp.get('url') or 'no url'}) — create + attach it in the workspace"))

    if mode == "live":
        client.publish_agent(agent_id)
        print(green(bold("  ✓ PUBLISHED  ")) + "a new live version.")
    else:
        print(yellow(bold("  ✓ STAGED  ")) + "as a draft — review and publish in the UI.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True, help="Path to the git-tracked agent repo.")
    parser.add_argument("--mode", choices=["dryrun", "draft", "live"], default="dryrun",
                        help="dryrun: preview only, no writes (default). "
                             "draft: import into the draft. live: import + publish.")
    parser.add_argument("--profile", help="Workspace profile name (else target.yaml's, else env).")
    args = parser.parse_args()

    repo = Path(args.repo)
    invalid = _validate(repo)
    if invalid:
        print(red(bold("  ✗ INVALID  ")) + dim("the agent repo has problems:"))
        for item in invalid:
            print(red(f"      • {item}"))
        sys.exit(1)

    target = yaml.safe_load((repo / ".sema4" / "target.yaml").read_text())
    agent_id = target["agent_id"]
    client = SemaClient(load(args.profile or target.get("profile")))

    if args.mode == "dryrun":
        changes, name = _changes(repo, client, agent_id)
        _report(name, changes)
        return

    _apply(client, agent_id, repo, args.mode)


if __name__ == "__main__":
    main()
