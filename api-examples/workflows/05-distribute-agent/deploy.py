#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""One-shot deploy of an agent into a workspace — from a zip or another workspace.

No git repo, no overlays — just move a package into a target instance. Use this for
cross-instance copies / promotion / disaster recovery. (For a git-tracked agent use
01-agent-gitops; for a templated fleet roll-out use distribute.py.)

    # from a zip on disk:
    uv run deploy.py --zip ./agent.zip \
        --to-url https://b.app.sema4.ai/tenants/spar/api/v2 --to-key-env SEMA4_API_KEY_B

    # straight from another workspace (export source -> import target), no zip in between:
    uv run deploy.py --from-agent <id> \
        --from-url https://a.app.sema4.ai/tenants/spar/api/v2 --from-key-env SEMA4_API_KEY_A \
        --to-url   https://b.app.sema4.ai/tenants/spar/api/v2 --to-key-env   SEMA4_API_KEY_B

Like all imports today this CREATES a new agent in the target and does not carry
inline MCP servers (see README). Add --mode live to publish; default stages a draft.
For cross-workspace reference remapping (data-connection / MCP ids) use the publish
endpoint's connection_mappings / mcp_server_mappings.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from lib.client import ApiError, SemaClient  # noqa: E402
from lib.config import Config  # noqa: E402


def _client(url: str | None, key: str | None, key_env: str | None, side: str) -> SemaClient:
    if not url:
        raise SystemExit(f"--{side}-url is required")
    resolved = key or (os.environ.get(key_env) if key_env else None)
    if not resolved:
        raise SystemExit(f"{side} API key required (--{side}-key or --{side}-key-env)")
    return SemaClient(Config(base_url=url.rstrip("/"), api_key=resolved))


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--zip", help="Path to an exported agent zip to deploy.")
    parser.add_argument("--from-agent", help="Agent id to copy from a source workspace.")
    parser.add_argument("--from-url", help="Source workspace base URL (with --from-agent).")
    parser.add_argument("--from-key", help="Source API key (literal).")
    parser.add_argument("--from-key-env", default="SEMA4_API_KEY",
                        help="Env var holding the source API key (default: SEMA4_API_KEY).")
    parser.add_argument("--to-url", required=True, help="Target workspace base URL.")
    parser.add_argument("--to-key", help="Target API key (literal).")
    parser.add_argument("--to-key-env", default="SEMA4_API_KEY",
                        help="Env var holding the target API key (default: SEMA4_API_KEY).")
    parser.add_argument("--mode", choices=["draft", "live"], default="draft",
                        help="draft: create only (default). live: create and publish.")
    args = parser.parse_args()

    if bool(args.zip) == bool(args.from_agent):
        raise SystemExit("provide exactly one of --zip or --from-agent")

    if args.zip:
        zip_bytes = Path(args.zip).read_bytes()
    else:
        source = _client(args.from_url, args.from_key, args.from_key_env, "from")
        zip_bytes = source.export_agent(args.from_agent)

    target = _client(args.to_url, args.to_key, args.to_key_env, "to")
    try:
        created = target.import_agent(zip_bytes, filename="deploy.zip")
        print(f"Created {created['id']} ('{created['name']}') in {args.to_url}")
        if args.mode == "live":
            state = target.get_agent_state(created["id"])
            if state["state"] != "live" or state["has_draft"]:
                target.publish_agent(created["id"])
            print("Published live.")
        else:
            print("Left as a draft.")
    except ApiError as exc:
        # e.g. 409 when an agent with the same name already exists in the target
        raise SystemExit(f"deploy failed: {exc}")


if __name__ == "__main__":
    main()
