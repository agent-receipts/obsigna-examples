# Obsigna examples

Runnable examples of [Obsigna](https://github.com/agent-receipts/obsigna) — cryptographically signed audit trails for AI agents. Each example is self-contained: clone, check the prerequisites, run one script, read the output.

Two of the examples tell the same story from one angle — **two independent audit layers for an agent running in a sandbox**:

| Layer | Tool | Question it answers |
|-------|------|---------------------|
| Infrastructure | `sbx policy log` | What did the sandbox's network policy **allow or block**? |
| Agent actions | `obsigna verify` | What did the agent **actually do**, in what order, with what inputs — and is the record intact? |

Neither log alone tells the whole story. The sandbox sees network packets, not tool semantics. Obsigna sees a signed receipt for every tool call, not network verdicts. Side by side, they show the difference between *what was permitted* and *what happened*.

The third turns the lens on a problem sandboxing **can't** solve: when several isolated agents edit the same shared file, who changed what? Obsigna attributes every mutation to the agent that made it, in one signed chain.

The fourth answers the question that makes a signed log trustworthy in the first place: what if an attacker **deletes the tail** of the receipt store? A hash chain is tamper-evident, but a shorter chain still verifies clean. An out-of-band signed checkpoint anchor — on a trust domain the agent can't reach — catches the truncation that `verify` alone cannot.

## Examples

| Example | Agent | Sandbox | Captures receipts via | Status |
|---------|-------|---------|----------------------|--------|
| [`opencode-plugin/`](./opencode-plugin) | opencode | Docker sbx | the obsigna opencode **plugin** (native tool calls) | ✅ validated |
| [`mcp-proxy/`](./mcp-proxy) | opencode | Docker sbx | **obsigna-mcp** in the tool data path (MCP calls) | ✅ validated |
| [`multi-agent-attribution/`](./multi-agent-attribution) | 2× opencode | Docker sbx (one per agent) | **obsigna-mcp** with a per-agent operator identity | ✅ validated |
| [`checkpoint-anchor/`](./checkpoint-anchor) | opencode | Docker sbx | the obsigna **plugin** + an out-of-band **checkpoint anchor** | ✅ validated |

```sh
git clone https://github.com/agent-receipts/obsigna-examples
cd obsigna-examples
./opencode-plugin/demo.sh           # receipts for opencode's native tools
./mcp-proxy/demo.sh                 # receipts for MCP tool calls
./multi-agent-attribution/demo.sh   # who changed the shared file?
./checkpoint-anchor/demo.sh         # truncate the store tail → verify goes red
```

Each example has its own README with prerequisites and a walkthrough.

## How the sbx examples work

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

The signing daemon runs on the **host** — the key never enters the VM. Receipts are signed and stored on the host, so even a fully compromised agent can't forge or delete the chain. The socat tunnel exists because, on macOS, a host Unix socket is visible inside a Linux container via bind-mount but not connectable (the kernels differ); bridging through TCP keeps the daemon — and the key — on the host.

All of this host-side plumbing lives in [`lib/sbx.sh`](./lib/sbx.sh), so an sbx example's `demo.sh` is just: its config, its agent task, and the calls into that library.

## Prerequisites (sbx examples)

- [**obsigna**](https://github.com/agent-receipts/obsigna#install) — `obsigna` and `obsigna-daemon` on your `PATH`
- [**sbx**](https://github.com/docker/sandboxes) — authenticated (`sbx login`)
- [**ollama**](https://ollama.com) — running locally, `devstral-small-2` pulled (`ollama pull devstral-small-2`)
- **socat** — `brew install socat`

Each example creates a `devstral-demo` model variant (32K context) on first run, and accepts a model override: `./opencode-plugin/demo.sh openai-compatible/qwen2.5-coder:32b`.

## Adding an example

1. Create a directory: `my-example/`.
2. Add a `demo.sh`. To reuse the sbx scaffolding:
   ```sh
   #!/usr/bin/env bash
   set -euo pipefail
   DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
   # shellcheck source=../lib/sbx.sh disable=SC1091
   . "$DEMO_DIR/../lib/sbx.sh"

   ob_preflight                     # checks deps, sbx auth, ollama, devstral-demo
   ob_reset_workspace               # clean /tmp/obsigna-sbx (wipes stale config)
   cp "$DEMO_DIR/opencode.json" "$WORKSPACE/.opencode/opencode.json"
   ob_ensure_key
   ob_start_daemon                  # daemon on the host
   ob_start_tunnel                  # socat TCP bridge
   ob_allow_network                 # ollama + tunnel (add "host:port" args for more)
   ob_create_sandbox

   TUNNEL="$(ob_container_tunnel_cmd)"   # container-side socat snippet
   sbx exec "$SANDBOX_NAME" -- sh -c "$TUNNEL AGENTRECEIPTS_SOCKET='$CONTAINER_SOCKET' ... <run the agent>"

   ob_show_results                  # sbx policy log + obsigna receipt list + verify
   ```
   An example that doesn't use sbx just doesn't source `lib/sbx.sh` — it's a plain script in its own directory.
3. Add a `README.md` in the directory (prerequisites + what it shows).
4. Add a row to the table above.

See [`lib/sbx.sh`](./lib/sbx.sh) for the full list of `ob_*` helpers and what each does.

## Learn more

- [Obsigna](https://github.com/agent-receipts/obsigna) — the protocol and tooling
- [opencode plugin](https://github.com/agent-receipts/obsigna/tree/main/integrations/opencode-plugin)
- [MCP proxy](https://github.com/agent-receipts/obsigna/tree/main/mcp-proxy)
- [Docker sbx](https://github.com/docker/sandboxes)
