#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml>=6"]
# ///
"""Export a workspace's configuration to a portable YAML file.

    uv run export.py [--out workspace.yaml]

Captures branding, LLMs (+ default / sqlgen defaults), MCP servers, data
connections, advanced settings, and observability integrations from the source
workspace (SEMA4_BASE_URL / SEMA4_API_KEY).

Secrets are redacted to ${ENV_VAR} placeholders so workspace.yaml is safe to share.
Their real values are written to a sibling <out>.secrets.env (sensitive — keep it
out of git); apply.py reads them back from the environment.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import yaml  # noqa: E402

import wslib  # noqa: E402
from lib.client import SemaClient  # noqa: E402
from lib.config import load  # noqa: E402

BRANDING_KEYS = ["workspace_name", "logo_data_url", "logo_dark_data_url", "primary_color"]


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="workspace.yaml", help="Output YAML path.")
    parser.add_argument("--profile", help="Source workspace profile name (else SEMA4_* env).")
    args = parser.parse_args()

    client = SemaClient(load(args.profile))
    doc: dict = {}

    branding = client.request("GET", "/branding") or {}
    doc["branding"] = {k: branding[k] for k in BRANDING_KEYS if branding.get(k)}

    doc["settings"] = client.request("GET", "/settings") or {}

    llms = list(client.paginate("/llms"))
    id_to_name = {l["id"]: l["name"] for l in llms}
    doc["llms"] = [{k: l.get(k) for k in ("name", "kind", "description", "models", "configuration")}
                   for l in llms]
    defaults = client.request("GET", "/llms/defaults") or {}
    doc["llm_defaults"] = {
        "default_llm": id_to_name.get(defaults.get("default_llm_id")),
        "sqlgen_llm": id_to_name.get(defaults.get("sqlgen_llm_id")),
    }

    mcp = list(client.paginate("/mcp-servers"))
    drop = {"id", "created_at", "updated_at"}
    doc["mcp_servers"] = [{k: v for k, v in m.items() if k not in drop} for m in mcp]

    conns = list(client.paginate("/data-connections"))
    doc["data_connections"] = [{k: x.get(k) for k in ("name", "description", "engine",
                                                       "configuration", "tags")} for x in conns]

    obs = client.request("GET", "/observability/integrations") or []
    doc["observability"] = [{k: o.get(k) for k in ("settings", "version", "description",
                                                   "is_system", "debug")} for o in obs]

    # Redact secrets per section, collecting placeholder -> real value.
    secrets: dict = {}
    used: set = set()
    doc["branding"] = wslib.redact(doc["branding"], "BRANDING", "branding", secrets, used)
    doc["settings"] = wslib.redact(doc["settings"], "SETTINGS", "settings", secrets, used)
    for llm in doc["llms"]:
        llm["configuration"] = wslib.redact(llm.get("configuration"),
                                            f"LLM_{wslib.slug(llm['name'])}", "configuration",
                                            secrets, used)
    for m in doc["mcp_servers"]:
        for field in ("headers", "env"):
            if m.get(field):
                m[field] = wslib.redact(m[field], f"MCP_{wslib.slug(m['name'])}", field, secrets, used)
    for conn in doc["data_connections"]:
        conn["configuration"] = wslib.redact(conn.get("configuration"),
                                             f"DATACONN_{wslib.slug(conn['name'])}", "configuration",
                                             secrets, used)
    for o in doc["observability"]:
        prov = (o.get("settings") or {}).get("provider", "obs")
        o["settings"] = wslib.redact(o.get("settings"), f"OBS_{wslib.slug(prov)}", "settings",
                                     secrets, used)

    out = Path(args.out)
    out.write_text(yaml.safe_dump(doc, sort_keys=False, allow_unicode=True, width=1000))
    print(f"Wrote {out}  (branding, {len(doc['llms'])} llms, {len(doc['mcp_servers'])} mcp, "
          f"{len(doc['data_connections'])} data connections, {len(doc['observability'])} observability)")

    if secrets:
        sfile = out.with_suffix(".secrets.env")
        sfile.write_text("".join(f"export {k}={v!r}\n" for k, v in sorted(secrets.items())))
        sfile.chmod(0o600)
        print(f"Wrote {sfile} with {len(secrets)} secret(s) — SENSITIVE, do not commit. "
              f"`source {sfile}` before apply.py.")


if __name__ == "__main__":
    main()
