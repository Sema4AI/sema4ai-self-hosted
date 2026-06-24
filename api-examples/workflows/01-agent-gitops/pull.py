#!/usr/bin/env python3
"""Bootstrap (or refresh) a git-tracked agent repo from a live agent.

    python pull.py --agent-id <id> --dest ./my-agent

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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent-id", required=True)
    parser.add_argument("--dest", required=True)
    parser.parse_args()

    # TODO: load config, build SemaClient, export_agent, agentpack.unpack,
    #       write .sema4/target.yaml
    raise NotImplementedError


if __name__ == "__main__":
    main()
