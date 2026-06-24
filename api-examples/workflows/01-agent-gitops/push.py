#!/usr/bin/env python3
"""Reconcile a git-tracked agent repo onto its live agent and publish.

    python push.py --repo ./my-agent --mode draft|live

Steps:
  1. Read .sema4/target.yaml -> agent_id, base_url.
  2. Determine what changed (git diff against the previous commit, or full repo
     on first run).
  3. POST /agents/{id}/edit  -> ensure DRAFT.
  4. Apply the change through the supported path:
       - runbook.md / name / description -> PATCH
       - MCP servers (inline in agent-spec.yaml) -> attach/detach + secret inject
       - SDM attach/detach
     FAIL LOUDLY if a changed file is not yet applicable in place (model,
     agent-settings, welcome-message, document-intelligence, shared files) —
     see EPD-7051 — instead of publishing a partial version.
  5. If --mode live: POST /agents/{id}/publish (with any connection / mcp mappings).
     If --mode draft: stop, leaving the change staged for UI review.
"""

from __future__ import annotations

import argparse


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--mode", choices=["draft", "live"], default="draft")
    parser.parse_args()

    # TODO: load target, diff, edit -> reconcile -> publish|stop
    raise NotImplementedError


if __name__ == "__main__":
    main()
