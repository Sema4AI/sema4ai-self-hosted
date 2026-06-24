#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""List the agents in the workspace and their ids.

    uv run list-agents.py [--name <prefix>] [--state draft|live] [--json]

Handy for finding the --agent-id to pass to a workflow's pull.py.
Reads SEMA4_BASE_URL and SEMA4_API_KEY from the environment (or ../.env).
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", help="Filter by name prefix (case-insensitive).")
    parser.add_argument("--state", choices=["draft", "live"], help="Filter by lifecycle state.")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of a table.")
    args = parser.parse_args()

    agents = [a for a in SemaClient(load()).list_agents(name=args.name)
              if not args.state or a.get("state") == args.state]
    agents.sort(key=lambda a: a.get("name", "").lower())

    if args.json:
        print(json.dumps([{"id": a["id"], "name": a["name"], "state": a.get("state")}
                          for a in agents], indent=2))
        return

    print(f"{'ID':36}  {'STATE':5}  NAME")
    for a in agents:
        print(f"{a['id']:36}  {a.get('state', ''):5}  {a.get('name', '')}")
    print(f"\n{len(agents)} agent(s).")


if __name__ == "__main__":
    main()
