#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml>=6"]
# ///
"""List the agents in the workspace and their ids.

    uv run list-agents.py [--name <prefix>] [--state draft|live] [--json] [--profile NAME]

Handy for finding the --agent-id to pass to a workflow's pull.py.
Targets a workspace via --profile, or SEMA4_BASE_URL / SEMA4_API_KEY (or ../.env).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lib.client import SemaClient  # noqa: E402
from lib.config import load  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name", help="Filter by name prefix (case-insensitive).")
    parser.add_argument("--state", choices=["draft", "live"], help="Filter by lifecycle state.")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of a table.")
    parser.add_argument("--profile", help="Workspace profile name (else SEMA4_* env).")
    args = parser.parse_args()

    agents = [a for a in SemaClient(load(args.profile)).list_agents(name=args.name)
              if not args.state or a.get("state") == args.state]
    agents.sort(key=lambda a: a.get("name", "").lower())

    if args.json:
        print(json.dumps([{"id": a["id"], "name": a["name"], "state": a.get("state"),
                           "version": a.get("version"), "live_version_id": a.get("live_version_id"),
                           "updated_at": a.get("updated_at")}
                          for a in agents], indent=2))
        return

    # NOTE: `updated_at` is last-modified, the closest available proxy for "published at".
    # A true publish timestamp is not exposed by the API yet.
    print(f"{'ID':36}  {'STATE':5}  {'VERSION':8}  {'UPDATED':16}  NAME")
    for a in agents:
        updated = (a.get("updated_at") or "")[:16].replace("T", " ")
        print(f"{a['id']:36}  {a.get('state', ''):5}  {(a.get('version') or '-'):8}  "
              f"{updated:16}  {a.get('name', '')}")
    print(f"\n{len(agents)} agent(s).")


if __name__ == "__main__":
    main()
