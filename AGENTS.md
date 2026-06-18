# AGENTS.md — working in obsigna-examples

Guidance for AI agents (and humans) contributing to this repo. For the product
story and the full walkthrough, read [`README.md`](./README.md) first; this file
covers how the examples are built and the conventions to keep.

## What this repo is

Runnable, self-contained examples of [Obsigna](https://github.com/agent-receipts/obsigna)
— signed audit trails for AI agents. Each example is: clone → check prerequisites
→ run one `demo.sh` → read the output. Examples are demonstrations, not a library.

## Layout

```
lib/sbx.sh              shared host-side scaffolding (the ob_* helpers)
<example>/demo.sh       the script a user runs
<example>/README.md     prerequisites + walkthrough for that example
<example>/opencode.json opencode config (plugin/MCP wiring, model)
```

Every sbx-based example follows the same shape: source `lib/sbx.sh`, call
`ob_preflight`, populate `$WORKSPACE/.opencode/`, start the host daemon + tunnel,
create the sandbox, run the agent via `sbx exec`, then show results. See the
"Adding an example" section of the README for the skeleton.

## Architecture you must respect

- **The daemon and signing key live on the HOST, never in the VM.** The agent
  runs in a Docker-backed `sbx` microVM and reaches the daemon only through a
  socat-tunnelled Unix socket. This is the security boundary — keep it.
- **`$WORKSPACE` (`/tmp/obsigna-sbx`) is bind-mounted into the sandbox.** Anything
  the agent must NOT be able to write (e.g. a checkpoint anchor) must live on the
  host *outside* `$WORKSPACE`. An anchor under the mount is writable by the agent
  and the boundary becomes a lie. (See `checkpoint-anchor/` for the pattern:
  `OB_ANCHOR_DIR=/tmp/obsigna-anchor`, a sibling path.)
- **The forensic private key for parameter disclosure lives outside `$WORKSPACE`
  too.** Every sbx example enables disclosure (ADR-0012): `ob_start_daemon` passes
  `--forensic-public-key` so the daemon HPKE-encrypts tool parameters into the
  receipt, and `ob_show_results` recovers them with `obsigna receipt disclose`. The
  daemon needs only the *public* key; the *private* key (`$FORENSIC_DIR`,
  `/tmp/obsigna-forensic`) must stay off the mount, or the agent could decrypt its
  own disclosed parameters and the boundary would be a lie.
- **Don't claim a boundary you haven't demonstrated.** If a demo asserts the
  agent can't do X, have the sandbox *try* X and gate the verdict on the real
  result — never on a check that cannot fail.

## Conventions

- **Bash**, `set -uo pipefail`, plus `-e` only when the demo has its own critical
  setup that must abort on failure (e.g. `mcp-proxy/` downloads a binary, so it
  uses `set -euo pipefail`). Demos whose flow continues past a flaky local-model
  step omit `-e` so that step can't abort the run (`checkpoint-anchor/`,
  `multi-agent-attribution/`). Either way, use `exit 1` explicitly where a real
  failure must stop the demo — don't rely on `-e` to catch it. Don't "fix" a
  file's choice in isolation; match its existing flow.
- **Support GNU *and* BSD tools.** Demos are authored on macOS (BSD) and run on
  Linux (GNU). Don't assume one. For `stat`, try GNU first then BSD:
  `stat -c '%a' "$d" 2>/dev/null || stat -f '%Lp' "$d" 2>/dev/null || echo '?'`
  (GNU-first because BSD's `-f` *succeeds with garbage* on GNU). Watch `sed -i`,
  `date -d`/`-r`, `readlink -f`, `grep -P`, `mktemp` templates. End fallbacks with
  an honest sentinel — never fabricate a value.
- **Reuse `lib/sbx.sh`.** Add optional behaviour as env-gated, default-off so
  other examples are unaffected (e.g. `OB_CHECKPOINT_ANCHOR`). Don't fork a second
  harness.
- **Never commit runtime artifacts.** `.gitignore` covers `*.db`, `*.sock`, and
  signing keys; demos write under `/tmp/obsigna-sbx` and clean up on exit.

## Prerequisites to run anything here

- `obsigna` + `obsigna-daemon` on `PATH` (`brew install agent-receipts/tap/obsigna-alpha`).
  The `checkpoint-anchor/` example needs **≥ 0.27.0-alpha.2** (the
  `--checkpoint-anchor` flag and `verify --against-anchor`).
- `sbx` authenticated (`sbx login`), `socat`, and `ollama` running with
  `devstral-demo` available (demos create the 32K-context variant on first run).

## Validation

Before claiming an example works, **actually run its `demo.sh`** and read the
output — "looks right" is not "verified end-to-end through the documented path".
A local model occasionally fumbles tool calls; re-run or pass a stronger model
(`./demo.sh openai-compatible/qwen2.5-coder:32b`).

## Commit / PR hygiene

Imperative, lower-case commit subjects (e.g. `add checkpoint-anchor example`).
Keep commits and PRs free of AI-assistant attribution trailers.
