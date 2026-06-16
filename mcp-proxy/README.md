# MCP proxy — receipts in the tool data path

Receipts for **MCP** tool calls via [obsigna-mcp](https://github.com/agent-receipts/obsigna/tree/main/mcp-proxy).
Unlike the plugin (which hooks opencode's native tools in-process), obsigna-mcp
sits *in* the data path: opencode launches it as an MCP server, and it
transparently wraps a downstream MCP server, signing a receipt for every
`tools/call` that passes through. The agent can't route around it.

```
opencode ──stdio──▶ obsigna-mcp ──stdio──▶ @modelcontextprotocol/server-filesystem
                         │
                         └─▶ AGENTRECEIPTS_SOCKET ─▶ tunnel ─▶ host daemon
```

```sh
./demo.sh
```

Prerequisites: see the [top-level README](../README.md#prerequisites-sbx-examples).
The Linux `obsigna-mcp` binary is downloaded from the obsigna release on first
run (it runs inside the sandbox), and `npx` fetches the filesystem MCP server.

## What you'll see

`obsigna receipt list` — one receipt per MCP tool call, namespaced by server:

```
SEQ  TIMESTAMP   CHAIN   TOOL / ACTION TYPE
1    ...         ...     write_file        (mcp.files.write_file)
2    ...         ...     read_text_file    (mcp.files.read_text_file)
3    ...         ...     list_directory    (mcp.files.list_directory)
```

`obsigna verify` → `Chain ...: VALID (N receipts)`.

## Notes

- The filesystem server's `write_file` takes `path` + `content`; small local
  models sometimes guess `filePath` first, producing a failure receipt followed
  by a corrected success receipt — an honest trail of what the agent attempted.
- obsigna-mcp ships its own default policy (pause-high-risk, block-destructive)
  with the approver off; this demo leaves it at defaults and focuses on receipts.
