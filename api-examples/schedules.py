#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml>=6"]
# ///
"""Manage a Worker agent's schedules (cron -> Work Items) over the API.

    uv run schedules.py list   --agent <id|name>
    uv run schedules.py create --agent <id|name> --cron "0 9 * * 1-5" [options]
    uv run schedules.py update --agent <id|name> --schedule <sid> --cron "..." [options]
    uv run schedules.py delete --agent <id|name> --schedule <sid>

Schedules exist only for **worker** agents (the API returns 400 for conversational
ones); this tool checks the agent's `mode` first and refuses with a clear message.
Find worker agents with `list-agents.py --mode worker`.
Target a workspace with --profile, or SEMA4_BASE_URL / SEMA4_API_KEY.

Note: `enabled` is read-only (pause/resume in the app), and `update` is a FULL
replace — omitted optional fields reset to their defaults, so send the whole
definition each time.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lib.client import ApiError, SemaClient  # noqa: E402
from lib.config import load  # noqa: E402

_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


def _resolve_agent(client: SemaClient, ref: str) -> dict:
    """Resolve an agent by id or exact name."""
    if _UUID.match(ref):
        return client.get_agent(ref)
    matches = [a for a in client.list_agents(name=ref) if a.get("name") == ref]
    if not matches:
        raise SystemExit(f"no agent named '{ref}' (try an id, or check list-agents.py)")
    if len(matches) > 1:
        raise SystemExit(f"'{ref}' matches {len(matches)} agents — use the id instead")
    return matches[0]


def _require_worker(agent: dict) -> None:
    if agent.get("mode") != "worker":
        raise SystemExit(f"'{agent.get('name')}' is a {agent.get('mode')} agent — "
                         "schedules exist only for worker agents.")


def _body(args) -> dict:
    """Build the upsert body from CLI options (only cron is required)."""
    body: dict = {"cron_expression": args.cron}
    if args.timezone:
        body["timezone"] = args.timezone
    if args.work_item_name:
        body["work_item_name"] = args.work_item_name
    if args.message:
        body["message"] = args.message
    if args.payload:
        try:
            body["payload"] = json.loads(args.payload)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"--payload is not valid JSON: {exc}")
    return body


def _print_schedule(s: dict) -> None:
    flag = "enabled" if s.get("enabled") else "paused"
    print(f"  {s['id']}  {s['cron_expression']!r} {s.get('timezone', 'UTC')}  [{flag}]")
    if s.get("work_item_name"):
        print(f"      work item: {s['work_item_name']}")
    if s.get("next_run_at"):
        print(f"      next run:  {s['next_run_at']}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p):
        p.add_argument("--agent", required=True, help="Agent id or exact name.")
        p.add_argument("--profile", help="Workspace profile name (else SEMA4_* env).")

    def upsert_opts(p):
        p.add_argument("--cron", required=True, help="5-field cron, e.g. '0 9 * * 1-5'.")
        p.add_argument("--timezone", help="IANA timezone (default UTC).")
        p.add_argument("--work-item-name", help="Name for created Work Items.")
        p.add_argument("--message", help="Message included in each Work Item.")
        p.add_argument("--payload", help="JSON payload included in each Work Item.")

    p_list = sub.add_parser("list", help="List an agent's schedules."); common(p_list)
    p_create = sub.add_parser("create", help="Create a schedule."); common(p_create); upsert_opts(p_create)
    p_update = sub.add_parser("update", help="Replace a schedule (full definition).")
    common(p_update); p_update.add_argument("--schedule", required=True, help="Schedule id."); upsert_opts(p_update)
    p_delete = sub.add_parser("delete", help="Delete a schedule.")
    common(p_delete); p_delete.add_argument("--schedule", required=True, help="Schedule id.")

    args = parser.parse_args()
    client = SemaClient(load(args.profile))
    agent = _resolve_agent(client, args.agent)

    try:
        if args.command == "list":
            _require_worker(agent)
            schedules = list(client.list_schedules(agent["id"]))
            print(f"Schedules for '{agent['name']}':")
            for s in schedules:
                _print_schedule(s)
            print(f"\n{len(schedules)} schedule(s).")
        elif args.command == "create":
            _require_worker(agent)
            created = client.create_schedule(agent["id"], **_body(args))
            print("Created schedule:")
            _print_schedule(created)
        elif args.command == "update":
            _require_worker(agent)
            updated = client.update_schedule(agent["id"], args.schedule, **_body(args))
            print("Updated schedule:")
            _print_schedule(updated)
        elif args.command == "delete":
            client.delete_schedule(agent["id"], args.schedule)
            print(f"Deleted schedule {args.schedule}.")
    except ApiError as exc:
        raise SystemExit(str(exc))


if __name__ == "__main__":
    main()
