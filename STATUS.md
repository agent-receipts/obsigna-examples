# Status

Validation state of each demo. Remove this file before the repo goes public.

## opencode-plugin/

- **Validated end-to-end against the published npm package**
  `@obsigna/opencode-plugin@0.1.0-alpha.3`. opencode installs it on first run,
  the plugin loads cleanly, native tool calls (write/bash) are receipted by the
  host daemon, chain VALID. No build step.
- Getting here required three fixes in the published package (alpha.2 was not
  loadable): a `./server` entrypoint + `main`, an entry that exports only the
  plugin, and importing `DaemonEmitter` from the new `@obsigna/sdk-ts/emitter`
  subpath (0.14.1, #867) so `node:sqlite`/`undici` stay out of the import graph.
- Pinned to `alpha.3` in opencode.json; bump when a non-alpha ships.

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
