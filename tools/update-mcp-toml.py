# /// script
# requires-python = ">=3.11"
# dependencies = ["tomlkit==0.13.3"]
# ///
"""Plan updates to the managed MCP entries while preserving the rest of the TOML."""

import json
from pathlib import Path
import sys
import tomllib

from tomlkit import dumps, inline_table, parse, table
from tomlkit.items import InlineTable


def main() -> None:
    config, manifest = (Path(path) for path in sys.argv[1:])
    document = parse(config.read_bytes().decode("utf-8-sig") if config.exists() else "")
    desired = json.loads(manifest.read_text(encoding="utf-8"))
    servers = document.setdefault("mcp_servers", table())
    changes = {}
    for name, server in desired.items():
        entry = {"url": server["url"]}
        if servers.get(name) == entry:
            continue
        changes[name] = "更新" if name in servers else "追加"
        definition = inline_table() if isinstance(servers, InlineTable) else table()
        definition.update(entry)
        servers[name] = definition
    content = dumps(document) if changes else None
    if content is not None:
        tomllib.loads(content)
    print(json.dumps({"changes": changes, "content": content}))


if __name__ == "__main__":
    main()
