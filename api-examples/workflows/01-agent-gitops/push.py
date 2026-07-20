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

  - dryrun uses the server dry-run (`POST /agents/{id}/diff`) to show field-level changes,
    MCP servers to attach, unresolved MCP servers, and files to add.
  - MCP servers are matched to existing workspace servers by name+URL and attached;
    unresolved ones are reported. `--mode live` refuses to publish while any remain
    (pass --allow-unresolved-mcp to override) so a live version never ships missing tools.
  - Import is add-only for shared files; files removed from the repo are reported but
    NOT deleted (remove them in the UI if needed).
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

# Lifecycle artifacts the server diff always reports for a live agent (package is a draft);
# not user edits, so hide them.
NOISE_FIELDS = {"state", "live_version_id"}

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


def _tree_files(root: Path) -> set[str]:
    names: set[str] = set()
    for sub in ("agent-files", "semantic-data-models"):
        directory = root / sub
        if directory.is_dir():
            names |= {f"{sub}/{p.name}" for p in directory.iterdir() if p.is_file()}
    return names


def _removed_files(repo: Path, client: SemaClient, agent_id: str) -> list[str]:
    """Files present on the live agent but absent from the repo. Import never deletes these."""
    with tempfile.TemporaryDirectory() as tmp:
        agentpack.unpack(client.export_agent(agent_id), Path(tmp))
        live = _tree_files(Path(tmp))
    return sorted(live - _tree_files(repo))


def _fmt(value) -> str:
    text = "" if value is None else str(value)
    text = text.replace("\n", "⏎")
    return text if len(text) <= 60 else text[:59] + "…"


def _report(name: str, diff: dict, removals: list[str]) -> None:
    changes = [c for c in (diff.get("changes") or []) if c.get("field_path") not in NOISE_FIELDS]
    files_to_add = diff.get("files_to_add") or []
    to_attach = diff.get("mcp_servers_to_attach") or []
    unresolved = diff.get("unresolved_mcp_servers") or []

    print()
    print(bold("  DRY RUN  ") + dim(f"agent '{name}' · no changes made"))
    print(RULE)
    if not (changes or files_to_add or to_attach or unresolved or removals):
        print(dim("  In sync — importing the repo would change nothing."))
    if changes:
        print(green(bold(f"  ✓ WILL APPLY  ({len(changes)})")))
        for c in changes:
            fp = c.get("field_path")
            if fp in ("runbook", "runbook_text"):
                print(f"      • {fp}")
                for ln in difflib.unified_diff(
                        str(c.get("deployed_value") or "").splitlines(),
                        str(c.get("package_value") or "").splitlines(), lineterm=""):
                    if not ln.startswith(("---", "+++")):
                        print("          " + _diff_line(ln))
            else:
                print(f"      • {c.get('change')} {fp}: "
                      f"{_fmt(c.get('deployed_value'))} → {_fmt(c.get('package_value'))}")
    if files_to_add:
        print(green(bold(f"  ✓ FILES TO ADD  ({len(files_to_add)})")))
        for f in files_to_add:
            print(f"      • {f}")
    if to_attach:
        print(green(bold(f"  ✓ MCP TO ATTACH  ({len(to_attach)})")))
        for m in to_attach:
            print(f"      • {m.get('name')} ({m.get('url') or 'no url'})")
    if unresolved:
        print(yellow(bold(f"  ⚠ UNRESOLVED MCP  ({len(unresolved)})")) +
              dim("  create + attach these in the workspace"))
        for m in unresolved:
            print(yellow(f"      • {m.get('name')} ({m.get('url') or 'no url'})"))
    if removals:
        print(yellow(bold(f"  ⚠ NOT REMOVED  ({len(removals)})")) +
              dim("  import is add-only; delete these in the UI if needed"))
        for f in removals:
            print(yellow(f"      • {f}"))

    print(RULE)
    print(dim("  Preview · ") + "re-run with " + bold("--mode draft") +
          " to stage or " + bold("--mode live") + " to publish.")
    print()


def _apply(client: SemaClient, agent_id: str, repo: Path, mode: str, allow_unresolved: bool) -> None:
    result = client.update_import(agent_id, agentpack.pack(repo))
    print(green(bold("  ✓ IMPORTED  ")) + f"updated the draft of '{result.get('name', '')}'")

    unresolved = result.get("unresolved_mcp_servers") or []
    for mcp in unresolved:
        print(yellow(f"      ⚠ unresolved MCP server: {mcp.get('name')} "
                     f"({mcp.get('url') or 'no url'}) — create + attach it in the workspace"))
    for f in _removed_files(repo, client, agent_id):
        print(yellow(f"      ⚠ not removed (import is add-only): {f}"))

    if mode == "live":
        if unresolved and not allow_unresolved:
            print(red(bold("  ✗ NOT PUBLISHED  ")) +
                  f"{len(unresolved)} unresolved MCP server(s) — the draft is staged but not live. "
                  "Create + attach them and re-run, or pass --allow-unresolved-mcp.")
            sys.exit(1)
        client.publish_agent(agent_id)
        print(green(bold("  ✓ PUBLISHED  ")) + "a new live version.")
    else:
        print(yellow(bold("  ✓ STAGED  ")) + "as a draft — review and publish in the UI.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True, help="Path to the git-tracked agent repo.")
    parser.add_argument("--mode", choices=["dryrun", "draft", "live"], default="dryrun",
                        help="dryrun: preview only (default). draft: import into the draft. "
                             "live: import + publish.")
    parser.add_argument("--profile", help="Workspace profile name (else target.yaml's, else env).")
    parser.add_argument("--allow-unresolved-mcp", action="store_true",
                        help="Publish (--mode live) even if some MCP servers are unresolved.")
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
        diff = client.diff_agent(agent_id, agentpack.pack(repo))
        removals = _removed_files(repo, client, agent_id)
        name = client.get_agent(agent_id).get("name", "")
        _report(name, diff, removals)
        return

    _apply(client, agent_id, repo, args.mode, args.allow_unresolved_mcp)


if __name__ == "__main__":
    main()
