# Status

Validation state of each demo. Remove this file before the repo goes public.

## opencode-plugin/

- **Logic validated** end-to-end against a locally-built plugin (obsigna monorepo PR #766): plugin loads, native tool calls intercepted, receipts signed by the host daemon, chain VALID.
- **Blocked on**: `@agent-receipts/opencode-plugin` being published to npm. `opencode.json` declares the package by name; opencode installs it on first run. Until it's on npm, this demo can't run from a clean clone.
- Confirm the final published package name matches `opencode-plugin/opencode.json`.

## mcp-proxy/

- **Validated end-to-end.** opencode launches obsigna-mcp as a `type: local` MCP
  server wrapping `@modelcontextprotocol/server-filesystem`; every MCP
  `tools/call` is receipted by the host daemon with action type
  `mcp.<server-name>.<tool>` (e.g. `mcp.files.write_file`), signed, chain VALID.
  Files persist to the host via the bind mount.
- Findings from the validation run:
  - The bind mount lands at `/tmp/obsigna-sbx` inside the container (same path),
    NOT `/home/agent/workspace`. The filesystem server is rooted at
    `/tmp/obsigna-sbx/work` accordingly.
  - `write_file`'s required param is `path` (+ `content`). devstral sometimes
    fumbles it to `filePath` on the first try, then self-corrects — which the
    receipt log captures faithfully (a failure receipt followed by a success
    receipt). Honest, not a bug. A larger model (qwen2.5-coder:32b) is steadier.
  - The Linux `obsigna-mcp` from the obsigna release tarball runs fine in the
    sbx container.
- **Fixed a real bug here**: `lib/common.sh:ar_reset_workspace` now wipes
  `.opencode/` between runs. A stale opencode plugin bundle left in
  `.opencode/plugins/` was being auto-loaded and double-counting every MCP call
  (one receipt from the plugin, one from the proxy).

## Shared

- `lib/common.sh` factored out of the validated opencode-plugin run; the daemon/tunnel/sandbox/results path is the same one that worked.
- GitHub repo is currently named `demo-opencode-sbx`. With the suite layout it should be renamed (e.g. `agent-receipts/demos` or `agent-receipts/sbx-demos`). Nothing is pushed yet, so the rename is free.
