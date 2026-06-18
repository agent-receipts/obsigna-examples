# Multi-agent attribution — who changed the shared state

Reproduces the blog post [*Your agents are isolated. Your shared state
isn't.*](https://obsigna.dev/blog/attribution-over-undo/) with real sandboxes.

Two opencode agents, **alice** and **bob**, each run in their **own** Docker sbx
sandbox — fully isolated from each other. But they both edit **one shared file**
on the host (`work/deploy.yaml`, bind-mounted into both sandboxes). Sandboxing
keeps the agents apart; it does nothing for the state they share. The moment two
agents touch the same file, "undo" is meaningless — whose change do you revert?

Obsigna answers a different question: **attribution**. One signed, hash-linked
receipt chain records who changed the shared file, in what order, tamper-evident.

```
host: obsigna-daemon (one signing key, one chain)
        ▲ socat TCP tunnel
host dir: work/deploy.yaml  ◀── the shared state both agents contend over
    ▲ bind-mount            ▲ bind-mount
┌───┴─────────────┐    ┌────┴────────────┐
│ sbx: alice      │    │ sbx: bob        │
│ opencode +      │    │ opencode +      │
│ obsigna-mcp     │    │ obsigna-mcp     │
│ operator=alice  │    │ operator=bob    │
└─────────────────┘    └─────────────────┘
```

```sh
./demo.sh
```

Run it from an **interactive terminal** — `opencode run` needs a controlling TTY
to drive the model, so the agents do nothing under a headless/`nohup` shell.

Prerequisites: see the [top-level README](../README.md#prerequisites-sbx-examples).
The Linux `obsigna-mcp` binary is downloaded from the obsigna release on first
run (it runs inside each sandbox), and `npx` fetches the filesystem MCP server.

## How attribution survives a shared daemon

Every agent emits to the **same** host daemon, which signs **one** chain. So the
fields you might reach for to tell agents apart are identical across all of them:

- `issuer.id` is the daemon's DID — one daemon, one value.
- `principal` is derived from the kernel-attested peer of the socket. Through the
  socat tunnel every sandbox shares one peer, so the principal is identical too.

The attribution rides a different axis. Each agent's `obsigna-mcp` carries a
distinct `--operator-id` / `--operator-name` / `--issuer-name`; the daemon copies
those **verbatim** from the emit frame into `issuer.operator` and `issuer.name`.
That is the per-agent identity, and it is what the demo surfaces.

## What you'll see

The shared file ends up with bob's value (he wrote last). The receipt chain shows
how it got there — and **who** did each step:

```
SEQ  OPERATOR (who acted)   AGENT NAME       TOOL
---  ---------------------  ---------------  -----------------
  1  did:agent:alice        opencode/alice   write_file       ← alice sets the config
  2  did:agent:bob          opencode/bob     read_text_file   ← bob reads it
  3  did:agent:bob          opencode/bob     write_file       ← bob overwrites
```

`obsigna verify` → `Chain ...: VALID (3 receipts)` — intact and tamper-evident.

The default `obsigna receipt list` text view shows sequence, time, and tool but
**not** the operator, so the demo renders the attribution view with
[`attribution.py`](./attribution.py), reading `issuer.operator` from
`obsigna receipt list --json`.

## Notes

- Agents run **sequentially** (alice, then bob) so the walkthrough is
  deterministic — two local models contending live on one host would just thrash.
  The daemon assigns chain sequence regardless of timing, so the interleaving and
  attribution hold the same way under real concurrency.
- Receipts record *who* and *what* (operator, tool, ordered, signed). The signed
  body carries only a parameter *hash*, so the chain proves who touched the shared
  file without putting its contents in the signed receipt. With parameter
  disclosure on (ADR-0012, enabled for every example here), the cleartext is
  additionally HPKE-encrypted into a `parameters_disclosure` envelope that only the
  holder of the forensic private key can open — see the
  `obsigna receipt disclose` output the demo prints.
- Small local models sometimes guess a wrong parameter name (`filePath` before
  `path`), producing a failure receipt followed by a corrected success receipt —
  an honest trail of what the agent attempted.
