#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml>=6"]
# ///
"""Apply a workspace.yaml to a target workspace (the clone step).

    uv run apply.py [--file workspace.yaml] [--dry-run] [--yes]

Creates branding, settings, LLMs (+ defaults), MCP servers, data connections, and
observability integrations in the target workspace (SEMA4_BASE_URL / SEMA4_API_KEY).

Secrets are read from the environment (${ENV} placeholders in the YAML). If the file
has a sibling <file>.secrets.env it is auto-loaded. If the target already has
configuration (LLMs, MCP servers, data connections, observability), apply warns and
asks for confirmation first — pass --yes to skip the prompt (e.g. in CI).
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import yaml  # noqa: E402

import wslib  # noqa: E402
from lib.client import ApiError, SemaClient  # noqa: E402
from lib.config import get_profile, load  # noqa: E402


def _load_env_file(sfile: Path) -> None:
    """Load an env file (export K=V / K=V) into os.environ without overriding real env."""
    if not sfile.is_file():
        return
    for raw in sfile.read_text().splitlines():
        line = raw.strip()
        if line.startswith("export "):
            line = line[len("export "):]
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        os.environ.setdefault(key.strip(), val.strip().strip("'\""))


def _existing(client: SemaClient) -> list[str]:
    """Return human descriptions of config the target workspace already has."""
    found = []
    for label, path in [("LLMs", "/llms"), ("MCP servers", "/mcp-servers"),
                        ("data connections", "/data-connections")]:
        n = len(list(client.paginate(path)))
        if n:
            found.append(f"{n} {label}")
    obs = client.request("GET", "/observability/integrations") or []
    if obs:
        found.append(f"{len(obs)} observability integrations")
    return found


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--file", default="workspace.yaml", help="Workspace YAML to apply.")
    parser.add_argument("--profile", help="Target workspace profile name (else SEMA4_* env).")
    parser.add_argument("--dry-run", action="store_true", help="Show the plan; create nothing.")
    parser.add_argument("--yes", action="store_true", help="Skip the existing-config confirmation.")
    args = parser.parse_args()

    path = Path(args.file)
    _load_env_file(path.with_suffix(".secrets.env"))   # sibling of the YAML
    if args.profile:
        secrets_file = get_profile(args.profile).get("secrets")
        if secrets_file:
            _load_env_file(Path(secrets_file))          # per-profile secrets
    doc = yaml.safe_load(path.read_text()) or {}

    missing: set = set()
    doc = wslib.resolve(doc, missing)
    if missing:
        raise SystemExit("missing secret env var(s): " + ", ".join(sorted(missing)) +
                         f"\n(set them, or `source {path.with_suffix('.secrets.env')}`)")

    cfg = load(args.profile)
    client = SemaClient(cfg)

    llms = doc.get("llms") or []
    mcp = doc.get("mcp_servers") or []
    conns = doc.get("data_connections") or []
    obs = doc.get("observability") or []
    print(f"Plan for {cfg.base_url}:")
    print(f"  branding, {len(doc.get('settings') or {})} settings, {len(llms)} llms, "
          f"{len(mcp)} mcp, {len(conns)} data connections, {len(obs)} observability")

    if args.dry_run:
        print("\n(dry run — nothing created)")
        return

    existing = _existing(client)
    if existing and not args.yes:
        print("\n⚠️  The target workspace already has: " + ", ".join(existing))
        print("   Applying will CREATE duplicates / overwrite branding & settings.")
        if input("   Type 'yes, really' to proceed: ").strip().lower() != "yes, really":
            raise SystemExit("aborted.")

    # branding + settings (singletons, PATCH)
    if doc.get("branding"):
        client.request("PATCH", "/branding", json_body=doc["branding"])
        print("  ✓ branding")
    if doc.get("settings"):
        client.request("PATCH", "/settings", json_body=doc["settings"])
        print("  ✓ settings")

    # LLMs, then defaults by name
    name_to_id = {}
    for llm in llms:
        created = client.request("POST", "/llms", json_body=llm)
        name_to_id[llm["name"]] = created["id"]
        print(f"  ✓ llm: {llm['name']}")
    defaults = doc.get("llm_defaults") or {}
    body = {}
    if defaults.get("default_llm") in name_to_id:
        body["default_llm_id"] = name_to_id[defaults["default_llm"]]
    if defaults.get("sqlgen_llm") in name_to_id:
        body["sqlgen_llm_id"] = name_to_id[defaults["sqlgen_llm"]]
    if body:
        client.request("PUT", "/llms/defaults", json_body=body)
        print("  ✓ llm defaults")

    for m in mcp:
        client.request("POST", "/mcp-servers", json_body=m)
        print(f"  ✓ mcp: {m['name']}")
    for conn in conns:
        client.request("POST", "/data-connections", json_body=conn)
        print(f"  ✓ data connection: {conn['name']}")
    for o in obs:
        client.request("POST", "/observability/integrations", json_body=o)
        print(f"  ✓ observability: {(o.get('settings') or {}).get('provider', '?')}")

    print("\nDone.")


if __name__ == "__main__":
    main()
