# Status

Validation state of each demo. Remove this file before the repo goes public.

## opencode-plugin/

- **Logic validated** end-to-end against a locally-built plugin (obsigna monorepo PR #766): plugin loads, native tool calls intercepted, receipts signed by the host daemon, chain VALID.
- **Blocked on**: `@agent-receipts/opencode-plugin` being published to npm. `opencode.json` declares the package by name; opencode installs it on first run. Until it's on npm, this demo can't run from a clean clone.
- Confirm the final published package name matches `opencode-plugin/opencode.json`.

## mcp-proxy/

- **Scaffolded, NOT yet run end-to-end.** Open items before it's known-good:
  - Confirm opencode launches a `type: local` MCP server with the exact `command` array shape in `opencode.json` (binary + flags + downstream `npx ...`).
  - Confirm `obsigna-mcp`'s flags (`--socket`, `--name`) and that it emits to `AGENTRECEIPTS_SOCKET` when the downstream is `@modelcontextprotocol/server-filesystem`.
  - Steering: the local model must call the **MCP** tools, not opencode's native write/read, or nothing reaches the proxy. May need a stronger prompt or to disable native file tools.
  - Verify the Linux `obsigna-mcp` extracted from the obsigna release tarball runs in the sbx container (glibc/arch).
  - `npx` fetches the filesystem server from npm inside the VM — `registry.npmjs.org:443` is allowed in the policy; confirm it resolves.

## Shared

- `lib/common.sh` factored out of the validated opencode-plugin run; the daemon/tunnel/sandbox/results path is the same one that worked.
- GitHub repo is currently named `demo-opencode-sbx`. With the suite layout it should be renamed (e.g. `agent-receipts/demos` or `agent-receipts/sbx-demos`). Nothing is pushed yet, so the rename is free.
