# opencode plugin — native tool receipts

Receipts for opencode's **native** tool calls (`write`, `bash`, `edit`) via the
[obsigna opencode plugin](https://github.com/agent-receipts/obsigna/tree/main/integrations/opencode-plugin).
opencode installs the plugin from npm itself (declared in `opencode.json`), so
there's no build step.

```sh
./demo.sh
```

Prerequisites: see the [top-level README](../README.md#prerequisites-sbx-examples).

## What happens

1. The host daemon starts and the socat tunnel comes up (`lib/sbx.sh`).
2. opencode runs in the sbx sandbox with a local ollama model and the obsigna
   plugin. The plugin hooks `tool.execute.before/after` and emits one receipt
   per native tool call to the daemon over the tunnel.
3. The agent writes `fibonacci.py`, runs it, then attempts an outbound `curl`
   that the sandbox blocks.
4. Output shows the two layers side by side.

## What you'll see

`obsigna receipt list` — one receipt per native tool call:

```
SEQ  TIMESTAMP             CHAIN       TOOL / ACTION TYPE
1    ...                   ...         write   ← fibonacci.py
2    ...                   ...         bash    ← python3 work/fibonacci.py
3    ...                   ...         bash    ← curl (blocked at the network layer)
```

`obsigna verify` → `Chain ...: VALID (N receipts)`. The blocked curl appears in
**both** the sbx policy log and the receipt list — same event, two vantage points.

## Notes

- Pinned to `@obsigna/opencode-plugin@0.1.0-alpha.3` in `opencode.json`. Bump when
  a newer version ships.
- A local model occasionally fumbles shell quoting and retries the curl a few
  times; each attempt is faithfully receipted.
