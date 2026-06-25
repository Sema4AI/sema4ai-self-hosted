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
        print(json.dumps([{"name": a["name"], "id": a["id"], "state": a.get("state"),
                           "updated_at": a.get("updated_at")}
                          for a in agents], indent=2))
        return

    # NOTE: the live agent's version and a true publish timestamp are not exposed by the API
    # (see EPD-7096); `updated_at` shown here is last-modified, not publish time.
    print(f"{'NAME':40}  {'ID':36}  {'STATE':5}  LAST UPDATE")
    for a in agents:
        name = a.get("name", "")
        if len(name) > 40:
            name = name[:39] + "…"
        updated = (a.get("updated_at") or "")[:16].replace("T", " ")
        print(f"{name:40}  {a['id']:36}  {a.get('state', ''):5}  {updated}")
    print(f"\n{len(agents)} agent(s).")


if __name__ == "__main__":
    main()
