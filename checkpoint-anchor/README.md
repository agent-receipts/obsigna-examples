# Checkpoint anchor — tail-truncation resistance

A signed hash chain is tamper-**evident**, but it has an honest blind spot: an
attacker who can write the receipt store can **delete its tail**. The remaining
receipts still hash-link cleanly, so `obsigna verify` reports `VALID` — just with
the agent's last actions silently gone.

This example closes that gap end to end, through the **real** opencode → obsigna
plugin → daemon path — and then shows the attack being caught.

```sh
./demo.sh
# stronger local model (more reliable tool calls):
./demo.sh openai-compatible/qwen2.5-coder:32b
```

Prerequisites: see the [top-level README](../README.md#prerequisites-sbx-examples)
(plus `python3`, used to render and to perform the truncation).

## The defence (ADR-0008)

After every receipt, the daemon emits an **out-of-band signed checkpoint** —
`{chain_id, sequence, receipt_hash, timestamp}`, signed with the daemon key — to
an append-only **anchor** on a different trust domain. `verify --against-anchor`
cross-checks the store head against the latest checkpoint and fails when the
store has fallen behind. Receipts themselves are unchanged: a linear VC chain,
no anchor reference, anchoring is out-of-band by design.

```
opencode (sbx VM) ──plugin──▶ daemon (host) ──▶ receipt store  (the chain)
                                      │
                                      └────────▶ git checkpoint anchor (host, out-of-band)
```

## Where the boundary really is

The daemon, the signing key, **and the anchor** run on the host. The agent runs
in a Docker-backed sbx microVM and reaches the daemon only through a socket
tunnel. The anchor dir (`/tmp/obsigna-anchor`) sits **outside** the bind-mounted
workspace, so the agent's VM has no filesystem path to it at all — it cannot
forge, rewrite, or delete a checkpoint. The demo doesn't just assert this; step 2
has the sandbox **try** to write the anchor and shows it fail, while the agent's
own workspace stays writable.

> This is why sbx, not a single container with two UIDs: VM isolation puts the
> anchor on the far side of a kernel boundary, not just a different `uid`.

## What you'll see

1. **`receipt list`** — one receipt per native tool call (`write`, `bash`).
2. **The anchor** — a git commit chain on the host; the sandbox's write probe is
   refused.
3. **Before the attack** — `verify` and `verify --against-anchor` both green.
4. **The attack** — the last receipt is deleted from the store (tail truncation).
5. **The payoff** —

   ```
   plain verify (no anchor):       Chain ...: VALID (N-1 receipts)        ← fooled
   verify --against-anchor:        Chain ...: VALID (N-1 receipts)
                                   Anchor ...: FAIL (truncation) — anchor records
                                   head at seq N ... but store head is seq N-1:
                                   receipts N..N truncated                 ← caught
   ```

   That red `FAIL` is the whole point: the off-box anchor catches a truncation
   the chain alone cannot.

## Beyond the demo: real off-box sinks

The git anchor here is the **demo tier** — it beats the agent, and the commit
chain is a real out-of-band witness, but a plain git repo's immutability is only
as strong as the filesystem around it. For production the anchor belongs on a
medium that enforces append-only retention on a *separate* trust domain. The
sink is pluggable via `--checkpoint-anchor` (and fans out to a list), so the
agent path never changes:

| Sink spec | Backing | Notes |
|-----------|---------|-------|
| `git:<dir>` | git commit chain | this demo; beats a compromised agent |
| `file:<path>` | append-only file | dev / front-end to retention storage |
| `syslog:<tag>` | local syslog | hand off to a SIEM ingest |
| *(named, not run here)* | S3 Object Lock, a transparency log, a TPM-backed log | true tamper-proof retention |

These off-box sinks are **named, not run** in this example — wiring real
retention storage is out of scope for a clone-and-run demo.

## Notes

- Pinned to `@obsigna/opencode-plugin@0.1.0` in `opencode.json`.
- Requires the checkpoint-anchor daemon (obsigna **≥ 0.27.0-alpha.2**): the
  `--checkpoint-anchor` flag and `verify --against-anchor` ship there (ADR-0008).
- The truncation in step 4 edits the store directly — that *is* the attacker's
  capability the anchor defends against; it is not a flaw in the demo.
- `verify` prints `Note: response_hash present … cannot be verified offline` —
  expected: the plugin records a hash of each tool's response, which an offline
  verifier has no body to recompute. It does not affect chain or anchor verdicts.
- The truncation goes red whatever the local model does, as long as it makes at
  least two tool calls; the demo exits early with a hint if it made fewer.
