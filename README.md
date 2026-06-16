# demo-opencode-sbx

Run an AI coding agent inside a Docker [sbx](https://github.com/docker/sandboxes) microVM and watch two independent audit layers describe the same session from different vantage points:

| Layer | Tool | Question it answers |
|-------|------|---------------------|
| Infrastructure | `sbx policy log` | What did the sandbox's network policy **allow or block**? |
| Agent actions | `obsigna verify` | What did the agent **actually do** — in what order, with what inputs — and is the record intact? |

Neither log alone tells the whole story. sbx sees network packets, not tool semantics. [Obsigna](https://github.com/agent-receipts/obsigna) sees a cryptographically signed receipt for every tool call, not network verdicts. Side by side, they show the difference between *what was permitted* and *what happened*.

## Quick start

```sh
git clone https://github.com/agent-receipts/demo-opencode-sbx
cd demo-opencode-sbx
./demo.sh
```

That's it. One script: starts a signing daemon on your host, launches an [opencode](https://opencode.ai) agent in a sandbox, has it write and run some code plus attempt one outbound network call, then prints the two audit views.

### Prerequisites

- [**obsigna**](https://github.com/agent-receipts/obsigna#install) — `obsigna` and `obsigna-daemon` on your `PATH`
- [**sbx**](https://github.com/docker/sandboxes) — authenticated (`sbx login`)
- [**ollama**](https://ollama.com) — running locally, with `devstral-small-2` pulled (`ollama pull devstral-small-2`)
- **socat** — `brew install socat`

The demo creates a `devstral-demo` model variant (32K context window) on first run. Override the model:

```sh
./demo.sh openai-compatible/qwen2.5-coder:32b
```

## What you'll see

The agent writes `fibonacci.py`, runs it, then tries to `curl` an external API. The sandbox blocks the curl. Both layers record the moment:

**`sbx policy log`** — the infrastructure view:
```
ALLOWED  localhost:11434        ollama (model inference)
ALLOWED  localhost:3923         obsigna receipt tunnel
BLOCKED  worldtimeapi.org:443   default deny — no matching allow rule
```

**`obsigna receipt list`** — the agent-action view:
```
SEQ  TIMESTAMP             CHAIN       TOOL / ACTION TYPE
1    2026-06-16T00:24:16Z  2026-06-16  write   ← fibonacci.py created
2    2026-06-16T00:24:18Z  2026-06-16  bash    ← python3 work/fibonacci.py
3    2026-06-16T00:24:21Z  2026-06-16  bash    ← curl (blocked at the network layer)
```

**`obsigna verify`** — chain integrity:
```
Chain 2026-06-16: VALID (3 receipts)
```

The blocked curl appears in **both** logs: sbx stopped it at the network layer, obsigna receipted the agent's attempt to make it. Same event, two perspectives.

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
      ├── opencode (agent)
      │     └── obsigna plugin ──→ /tmp/obsigna.sock ──→ tunnel ──→ daemon
      └── ollama via host.docker.internal:11434
```

The signing daemon runs on the **host** — the Ed25519 signing key never enters the VM. The opencode plugin inside the sandbox emits a receipt for each tool call; the daemon signs and stores it on the host. Even if the agent were fully compromised, it cannot forge or delete the receipt chain.

The socat tunnel exists because, on macOS, a host Unix socket is visible inside a Linux container via bind-mount but not connectable (the kernels differ). Bridging through TCP keeps the daemon — and the key — on the host.

## Files

```
demo-opencode-sbx/
├── demo.sh                  the whole demo
├── opencode/
│   └── opencode.json        provider + model config; declares the obsigna plugin
└── README.md
```

The opencode plugin is installed from npm by opencode itself (declared in `opencode/opencode.json`) — there's no build step.

## Learn more

- [Obsigna](https://github.com/agent-receipts/obsigna) — the signed-receipt protocol and tooling
- [opencode plugin](https://github.com/agent-receipts/obsigna/tree/main/integrations/opencode-plugin) — the integration this demo exercises
- [Docker sbx](https://github.com/docker/sandboxes) — the sandbox runtime
