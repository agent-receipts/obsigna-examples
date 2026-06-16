# obsigna + sbx demos

Run an AI coding agent inside a Docker [sbx](https://github.com/docker/sandboxes) microVM and watch two independent audit layers describe the same session from different vantage points:

| Layer | Tool | Question it answers |
|-------|------|---------------------|
| Infrastructure | `sbx policy log` | What did the sandbox's network policy **allow or block**? |
| Agent actions | `obsigna verify` | What did the agent **actually do** — in what order, with what inputs — and is the record intact? |

Neither log alone tells the whole story. sbx sees network packets, not tool semantics. [Obsigna](https://github.com/agent-receipts/obsigna) sees a cryptographically signed receipt for every tool call, not network verdicts. Side by side, they show the difference between *what was permitted* and *what happened*.

## The demos

Each demo tells that same two-layer story for a different **receipt capture mechanism** — the three ways obsigna can observe an agent:

| Demo | Captures | How |
|------|----------|-----|
| [`opencode-plugin/`](./opencode-plugin) | opencode's **native** tool calls (write, bash, edit) | in-process plugin, installed from npm |
| [`mcp-proxy/`](./mcp-proxy) | **MCP** tool calls | `obsigna-mcp` sits in the agent→server data path (adversary-resistant) |

They share the same host-side scaffolding ([`lib/common.sh`](./lib/common.sh)): a signing daemon on the host, a socat tunnel into the sandbox, the sbx network policy, and the side-by-side result display.

```sh
git clone https://github.com/agent-receipts/demo-opencode-sbx
cd demo-opencode-sbx
./opencode-plugin/demo.sh      # native tool receipts
./mcp-proxy/demo.sh            # MCP tool receipts
```

## Prerequisites

- [**obsigna**](https://github.com/agent-receipts/obsigna#install) — `obsigna` and `obsigna-daemon` on your `PATH`
- [**sbx**](https://github.com/docker/sandboxes) — authenticated (`sbx login`)
- [**ollama**](https://ollama.com) — running locally, with `devstral-small-2` pulled (`ollama pull devstral-small-2`)
- **socat** — `brew install socat`

Each demo creates a `devstral-demo` model variant (32K context window) on first run. Override the model per demo: `./opencode-plugin/demo.sh openai-compatible/qwen2.5-coder:32b`.

## What you'll see

The agent does some work, then attempts an outbound network call the sandbox blocks. Both layers record the moment:

**`sbx policy log`** — the infrastructure view:
```
ALLOWED  localhost:11434        ollama (model inference)
ALLOWED  localhost:3923         obsigna receipt tunnel
BLOCKED  worldtimeapi.org:443   default deny — no matching allow rule
```

**`obsigna receipt list`** — the agent-action view:
```
SEQ  TIMESTAMP             CHAIN       TOOL / ACTION TYPE
1    2026-06-16T00:24:16Z  2026-06-16  write
2    2026-06-16T00:24:18Z  2026-06-16  bash
3    2026-06-16T00:24:21Z  2026-06-16  bash    ← blocked curl, still receipted
```

**`obsigna verify`** — chain integrity:
```
Chain 2026-06-16: VALID (3 receipts)
```

The blocked call appears in **both** logs: sbx stopped it at the network layer, obsigna receipted the agent's attempt. Same event, two perspectives.

## How it works

```
your laptop (host)
├── obsigna-daemon          signing key lives here (Ed25519)
│     ↑ Unix socket (/tmp/obsigna-sbx/obsigna.sock)
│     │
│     socat (host)          TCP bridge: port 3923 → Unix socket
│     ↑ TCP :3923
│     │
└── sbx microVM
      ├── socat (container) TCP → Linux Unix socket (/tmp/obsigna.sock)
      │     ↑
      ├── opencode (agent)  ──→ plugin or obsigna-mcp ──→ /tmp/obsigna.sock ──→ tunnel ──→ daemon
      └── ollama via host.docker.internal:11434
```

The signing daemon runs on the **host** — the Ed25519 signing key never enters the VM. Receipts are signed and stored on the host. Even if the agent were fully compromised, it cannot forge or delete the receipt chain.

The socat tunnel exists because, on macOS, a host Unix socket is visible inside a Linux container via bind-mount but not connectable (the kernels differ). Bridging through TCP keeps the daemon — and the key — on the host.

## Layout

```
demo-opencode-sbx/
├── lib/common.sh           shared host-side scaffolding
├── opencode-plugin/
│   ├── demo.sh
│   └── opencode.json       declares the obsigna plugin (installed from npm)
├── mcp-proxy/
│   ├── demo.sh
│   └── opencode.json       declares obsigna-mcp wrapping a filesystem MCP server
└── README.md
```

## Learn more

- [Obsigna](https://github.com/agent-receipts/obsigna) — the signed-receipt protocol and tooling
- [opencode plugin](https://github.com/agent-receipts/obsigna/tree/main/integrations/opencode-plugin)
- [MCP proxy](https://github.com/agent-receipts/obsigna/tree/main/mcp-proxy)
- [Docker sbx](https://github.com/docker/sandboxes)
