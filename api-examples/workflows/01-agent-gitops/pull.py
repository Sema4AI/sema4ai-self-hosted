#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml>=6"]
# ///
"""Bootstrap (or refresh) a git-tracked agent repo from a live agent.

    uv run pull.py --agent-id <id> --dest ./my-agent

Steps:
  1. Export the agent (GET /agents/{id}/export) -> zip bytes.
  2. Unpack into a git-friendly tree (lib.agentpack.unpack): renames shared-file
     blobs from UUIDs to human names; cleans dest so deletions show as diffs.
  3. Write .sema4/target.yaml with agent_id + base_url so push.py knows the target.

This is the platform -> git direction. Run once to bootstrap, or on a schedule to
mirror changes made in the UI.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import yaml  # noqa: E402

from lib import agentpack  # noqa: E402
from lib.client import SemaClient  # noqa: E402
from lib.config import load  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--agent-id", required=True, help="ID of the agent to export (see list-agents.py).")
    parser.add_argument("--dest", required=True, help="Directory to write the agent tree into.")
    parser.add_argument("--profile", help="Workspace profile name (else SEMA4_* env).")
    args = parser.parse_args()

    config = load(args.profile)
    client = SemaClient(config)
    dest = Path(args.dest)

    agent = client.get_agent(args.agent_id)
    print(f"Exporting '{agent['name']}' ({agent['state']}) ...")
    agentpack.unpack(client.export_agent(args.agent_id), dest)

    sema_dir = dest / ".sema4"
    sema_dir.mkdir(exist_ok=True)
    (sema_dir / "target.yaml").write_text(yaml.safe_dump(
        {"agent_id": args.agent_id, "base_url": config.base_url},
        sort_keys=False,
    ))
    print(f"Wrote agent tree to {dest}/ — commit it to version-control the agent.")


if __name__ == "__main__":
    main()
