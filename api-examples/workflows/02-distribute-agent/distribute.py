#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml>=6"]
# ///
"""Distribute one agent project to multiple workspaces, with per-env config.

    uv run distribute.py --repo ./my-agent [--env prod-eu] [--mode dryrun|draft|live]

Each target workspace is described by an overlay in <repo>/.sema4/environments/<name>.yaml:

    base_url: https://eu.app.sema4.ai/api/v2
    api_key_env: SEMA4_API_KEY          # env var holding that workspace's API key
    agent_id:                            # filled in on first deploy (written back)
    overrides:                           # deep-merged onto the base agent-spec.yaml
      model: { name: gpt-5-3-codex-high }
      mcp-servers:
        - name: Email (agent@sema4ai.email)
          url: https://eu-mcp.internal.app.sema4.ai/email/mcp
    secrets:                             # dotted path into the agent -> ${ENV_VAR}
      mcp-servers.0.headers.X-SMTP-Password.value: ${EU_SMTP_PASSWORD}

For each target: render (base + overrides + injected secrets) -> pack -> deploy.

  - First deploy (no agent_id): create the agent (POST /agents/import) and record
    its id back into the overlay.
  - Already deployed (agent_id present): converge it in place (PUT /agents/{id}/import).
  - --mode live also publishes the resulting draft.

MCP servers are matched to existing workspace servers by name+URL and attached;
unresolved ones are reported per target. Secrets are resolved from the environment
at deploy time and never read from git.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import yaml  # noqa: E402

from lib import agentpack  # noqa: E402
from lib.client import ApiError, SemaClient  # noqa: E402
from lib.config import Config, load  # noqa: E402


# --- rendering ------------------------------------------------------------
def _deep_merge(base, over):
    """Recursively merge `over` onto `base`. Lists of dict-with-name merge by name."""
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for key, value in over.items():
            out[key] = _deep_merge(base[key], value) if key in base else value
        return out
    if (isinstance(base, list) and isinstance(over, list)
            and all(isinstance(x, dict) and "name" in x for x in base + over)):
        out = [dict(x) for x in base]
        index = {x["name"]: i for i, x in enumerate(out)}
        for item in over:
            if item["name"] in index:
                out[index[item["name"]]] = _deep_merge(out[index[item["name"]]], item)
            else:
                out.append(item)
        return out
    return over


def _expand(value: str) -> str:
    """Resolve a ${ENV_VAR} reference; pass through literals."""
    match = re.fullmatch(r"\$\{(\w+)\}", str(value).strip())
    if not match:
        return value
    var = match.group(1)
    if var not in os.environ:
        raise SystemExit(f"secret env var '{var}' is not set")
    return os.environ[var]


def _set_path(obj, dotted: str, value) -> None:
    """Set a value at a dotted path (ints index into lists)."""
    parts = dotted.split(".")
    cur = obj
    for part in parts[:-1]:
        cur = cur[int(part)] if isinstance(cur, list) else cur[part]
    last = parts[-1]
    if isinstance(cur, list):
        cur[int(last)] = value
    else:
        cur[last] = value


def _render(repo: Path, env: dict, dest: Path) -> int:
    """Copy the repo to `dest`, apply overrides + secrets to agent-spec.yaml.

    Returns the number of secrets injected.
    """
    shutil.copytree(repo, dest, ignore=shutil.ignore_patterns(".git"), dirs_exist_ok=True)
    spec_path = dest / "agent-spec.yaml"
    spec = yaml.safe_load(spec_path.read_text())
    agent = spec["agent-package"]["agents"][0]

    if env.get("overrides"):
        agent = _deep_merge(agent, env["overrides"])
        spec["agent-package"]["agents"][0] = agent
    for dotted, ref in (env.get("secrets") or {}).items():
        _set_path(agent, dotted, _expand(ref))

    spec_path.write_text(yaml.safe_dump(spec, sort_keys=False, allow_unicode=True))
    return len(env.get("secrets") or {})


# --- environments ---------------------------------------------------------
def _load_envs(repo: Path, only: str | None) -> list[tuple[str, Path, dict]]:
    env_dir = repo / ".sema4" / "environments"
    if not env_dir.is_dir():
        raise SystemExit(f"no .sema4/environments/ directory in {repo}")
    names = [only] if only else sorted(p.stem for p in env_dir.glob("*.yaml"))
    envs = []
    for name in names:
        path = env_dir / f"{name}.yaml"
        if not path.is_file():
            raise SystemExit(f"environment '{name}' not found ({path})")
        envs.append((name, path, yaml.safe_load(path.read_text()) or {}))
    return envs


def _write_back_agent_id(path: Path, agent_id: str) -> None:
    text = path.read_text()
    if re.search(r"^agent_id:.*$", text, flags=re.MULTILINE):
        text = re.sub(r"^agent_id:.*$", f"agent_id: {agent_id}", text, count=1, flags=re.MULTILINE)
    else:
        text += f"\nagent_id: {agent_id}\n"
    path.write_text(text)


# --- deploy ---------------------------------------------------------------
def _connect(name: str, env: dict) -> tuple[str, "callable"]:
    """Return (base_url, make_client) from the overlay's `profile` or `base_url`+`api_key_env`."""
    if env.get("profile"):
        cfg = load(env["profile"])
        return cfg.base_url, (lambda: SemaClient(cfg))
    base_url = env.get("base_url")
    if not base_url:
        raise SystemExit(f"[{name}] set either 'profile' or 'base_url'")
    key_var = env.get("api_key_env", "SEMA4_API_KEY")

    def make_client():
        if key_var not in os.environ:
            raise SystemExit(f"[{name}] API key env var '{key_var}' is not set")
        return SemaClient(Config(base_url=base_url.rstrip("/"), api_key=os.environ[key_var]))

    return base_url.rstrip("/"), make_client


def _deploy(repo: Path, name: str, path: Path, env: dict, mode: str,
            allow_unresolved: bool) -> str:
    base_url, make_client = _connect(name, env)
    existing_id = env.get("agent_id")

    if mode == "dryrun":
        action = "UPDATE" if existing_id else "CREATE"
        n = len(env.get("secrets") or {})
        ov = ", ".join((env.get("overrides") or {}).keys()) or "none"
        return f"would {action} at {base_url} (overrides: {ov}; secrets: {n})"

    client = make_client()
    with tempfile.TemporaryDirectory() as tmp:
        _render(repo, env, Path(tmp))
        zip_bytes = agentpack.pack(Path(tmp))
        if existing_id:                       # converge an already-deployed target (PUT)
            imported = client.update_import(existing_id, zip_bytes, filename=f"{name}.zip")
            agent_id, verb = existing_id, "updated"
        else:                                 # first deploy (create)
            imported = client.import_agent(zip_bytes, filename=f"{name}.zip")
            agent_id, verb = imported["id"], "created"

    result = f"{verb} {agent_id}"
    unresolved = imported.get("unresolved_mcp_servers") or []
    if unresolved:
        result += f" ({len(unresolved)} unresolved MCP)"

    if mode == "live":
        if unresolved and not allow_unresolved:
            result += " — NOT published (unresolved MCP; create+attach or --allow-unresolved-mcp)"
        else:
            state = client.get_agent_state(agent_id)
            if state["state"] != "live" or state["has_draft"]:
                client.publish_agent(agent_id)
            result += " and published live"

    if path is not None and not existing_id:  # record the new id on first deploy
        _write_back_agent_id(path, agent_id)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True, help="Path to the agent repo.")
    parser.add_argument("--env", help="Deploy a single environment overlay by name (default: all).")
    parser.add_argument("--profiles", help="Comma-separated profile names for override-free fan-out "
                                           "(no overlays; same agent to each).")
    parser.add_argument("--mode", choices=["dryrun", "draft", "live"], default="dryrun",
                        help="dryrun: plan only (default). draft: create. live: create and publish.")
    parser.add_argument("--allow-unresolved-mcp", action="store_true",
                        help="Publish (--mode live) even if a target has unresolved MCP servers.")
    args = parser.parse_args()

    repo = Path(args.repo)
    if args.profiles:
        names = [p.strip() for p in args.profiles.split(",") if p.strip()]
        targets = [(name, None, {"profile": name}) for name in names]
    else:
        targets = _load_envs(repo, args.env)
    print(f"Distributing '{repo}' to {len(targets)} workspace(s) [--mode {args.mode}]\n")

    base = yaml.safe_load((repo / "agent-spec.yaml").read_text())
    if base["agent-package"]["agents"][0].get("mcp-servers"):
        print("  note: MCP servers are matched to existing servers in each target workspace "
              "(by name + URL); unmatched ones are reported as unresolved per target.\n")

    failures = 0
    for name, path, env in targets:
        try:
            print(f"  • {name}: {_deploy(repo, name, path, env, args.mode, args.allow_unresolved_mcp)}")
        except (ApiError, SystemExit) as exc:
            failures += 1
            print(f"  ✗ {name}: {exc}")

    print(f"\n{len(targets) - failures}/{len(targets)} succeeded.")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
