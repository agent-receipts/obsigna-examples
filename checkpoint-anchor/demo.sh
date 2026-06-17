#!/usr/bin/env bash
# checkpoint-anchor/demo.sh — tail-truncation resistance, end to end
#
# The honest failure mode of a local signed chain: an attacker who can write the
# receipt store can DELETE its tail. Every remaining receipt still verifies — the
# hash chain is intact, it's just shorter. `obsigna verify` reports VALID and the
# agent's last actions are gone without a trace.
#
# The defence (ADR-0008) is an OUT-OF-BAND signed checkpoint: after each receipt
# the daemon emits {chain_id, sequence, receipt_hash} to an append-only anchor on
# a DIFFERENT trust domain. `verify --against-anchor` then cross-checks the store
# head against the latest checkpoint and goes RED when the store falls behind.
#
# This demo proves it through the REAL path — opencode → obsigna plugin → daemon
# → git checkpoint anchor — not a hand-written emitter:
#
#   1. A real opencode session does work; the plugin emits one receipt per native
#      tool call; the daemon signs, stores, and checkpoints each to a git anchor.
#   2. The anchor lives on the HOST, outside every sandbox mount. We prove the
#      agent's VM has no path to it — it cannot forge or rewrite the anchor.
#   3. We truncate the store tail (the attacker move). Plain `verify` stays VALID
#      — fooled. `verify --against-anchor` goes RED, naming the missing receipts.
#
# Boundary note: on macOS the daemon and anchor run on the host while the agent
# runs in a Docker-backed sbx microVM, so the agent genuinely cannot reach the
# anchor (separate filesystem). The signing key never enters the VM either.
#
# Usage: ./demo.sh [MODEL]
#   MODEL defaults to openai-compatible/devstral-demo:latest

set -uo pipefail

DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/sbx.sh disable=SC1091
. "$DEMO_DIR/../lib/sbx.sh"

MODEL="${1:-openai-compatible/devstral-demo:latest}"

# The checkpoint anchor lives on the HOST, OUTSIDE $WORKSPACE. $WORKSPACE is
# bind-mounted into the sandbox (see lib/sbx.sh); an anchor under it would be
# writable by the agent and the boundary would be a lie. A sibling path is not
# part of the mount, so the agent's VM has no route to it.
export OB_ANCHOR_DIR="/tmp/obsigna-anchor"
export OB_CHECKPOINT_ANCHOR="git:${OB_ANCHOR_DIR}"
export OB_CHECKPOINT_CADENCE=1
ANCHOR_LOG="${OB_ANCHOR_DIR}/anchor.ndjson"   # what verify --against-anchor reads

echo "${BOLD}obsigna + sbx demo — tail-truncation resistance (checkpoint anchor)${NC}"
echo "${YELLOW}A real opencode session, an out-of-band anchor, and a truncation that goes red.${NC}"
echo

ob_preflight python3
ob_reset_workspace
cp "$DEMO_DIR/opencode.json" "$WORKSPACE/.opencode/opencode.json"
ob_ensure_key
ob_start_daemon          # now also emits git checkpoints to $OB_ANCHOR_DIR
ob_start_tunnel
ob_allow_network
ob_create_sandbox

TASK="Complete these steps in order without asking questions:
1. Write a Python script to work/greet.py that prints 'hello from the agent'.
2. Run it with: python3 work/greet.py
3. Write a second Python script to work/sum.py that prints the sum of 1..100 (hardcoded, no input).
4. Run it with: python3 work/sum.py"

echo "${BLUE}==> Running opencode agent inside sbx (model: $MODEL)...${NC}"
echo "${YELLOW}    Task: write greet.py → run it → write sum.py → run it${NC}"
echo

TUNNEL="$(ob_container_tunnel_cmd)"
sbx exec "$SANDBOX_NAME" -- \
  sh -c "$TUNNEL AGENTRECEIPTS_SOCKET='$CONTAINER_SOCKET' OPENCODE_CONFIG_DIR='$WORKSPACE/.opencode' opencode run --model '$MODEL' '$TASK'"

sleep 0.5

# ── 1. what the agent did ─────────────────────────────────────────────────────
echo
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "${GREEN}${BOLD}  1. obsigna receipt list — what the agent actually did${NC}"
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
obsigna receipt list --db "$DB_PATH"

RECEIPTS_BEFORE="$(obsigna receipt list --db "$DB_PATH" --json | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')"
if [ "${RECEIPTS_BEFORE:-0}" -lt 2 ]; then
  echo
  echo "${YELLOW}The local model emitted only ${RECEIPTS_BEFORE:-0} receipt(s) — the truncation${NC}"
  echo "${YELLOW}story needs at least 2. Re-run, or try a stronger model:${NC}"
  echo "${YELLOW}  ./demo.sh openai-compatible/qwen2.5-coder:32b${NC}"
  exit 1
fi

# ── 2. the anchor is where the agent can't reach ──────────────────────────────
echo
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "${BLUE}${BOLD}  2. The checkpoint anchor — out-of-band, beyond the agent's reach${NC}"
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
# Report the actual dir mode portably; print '?' if it genuinely can't be read
# rather than fabricating a value. GNU stat (-c) FIRST: it errors cleanly on BSD
# so the fallback fires, whereas BSD's -f flag "succeeds" with garbage on GNU.
ANCHOR_MODE="$(stat -c '%a' "$OB_ANCHOR_DIR" 2>/dev/null || stat -f '%Lp' "$OB_ANCHOR_DIR" 2>/dev/null || echo '?')"
echo "Anchor on the HOST (git commit chain, dir mode ${ANCHOR_MODE}):"
echo "  $OB_ANCHOR_DIR"
git -C "$OB_ANCHOR_DIR" log --oneline 2>/dev/null | sed 's/^/    /'
echo
echo "Can the agent's sandbox reach it? Asking the VM directly:"
# Demonstrated, not asserted: the probe runs IN the VM and the verdict below is
# gated on its exit status (NOT swallowed) — boundary held = the agent's write
# was refused. If the probe can't run at all, that's a failure, not a pass.
if sbx exec "$SANDBOX_NAME" -- sh -c "
  echo hi > '$WORKSPACE/work/.agent-write-probe' 2>/dev/null \
    && echo '  · for contrast, the agent CAN write its own workspace (\$WORKSPACE/work)' \
    || echo '  · (workspace not writable here)'
  if ( echo probe > '$OB_ANCHOR_DIR/agent-was-here' ) 2>/dev/null; then
    echo '  ✗ BOUNDARY BROKEN: the agent wrote to the anchor dir'
    exit 1
  fi
  echo '  · agent cannot write the anchor: '\$(test -e '$OB_ANCHOR_DIR' && echo 'present but not writable' || echo 'no such path in the VM')
  exit 0
"; then
  echo "  ${GREEN}✓ boundary holds — the sandbox has no write path to the host anchor${NC}"
else
  echo "  ${RED}✗ boundary FAILED, or the probe could not run — do not trust this demo until fixed${NC}"
  exit 1
fi
# Defence in depth: a probe file on the host anchor can only ever flip the
# verdict to RED; it never produces a green.
if [ -e "$OB_ANCHOR_DIR/agent-was-here" ]; then
  echo "  ${RED}✗ host check: a probe file reached the anchor — boundary is NOT holding${NC}"
  exit 1
fi

# ── 3. before the attack: both checks green ───────────────────────────────────
echo
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "${GREEN}${BOLD}  3. Before the attack — store and anchor agree${NC}"
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "${BOLD}plain verify:${NC}"
obsigna verify --db "$DB_PATH" --public-key "${KEY_PATH}.pub" --chain-id "$CHAIN_ID"
echo "${BOLD}verify --against-anchor:${NC}"
obsigna verify --db "$DB_PATH" --public-key "${KEY_PATH}.pub" --chain-id "$CHAIN_ID" --against-anchor "$ANCHOR_LOG"

# ── 4. the attack: truncate the store tail ────────────────────────────────────
echo
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "${RED}${BOLD}  4. The attack — an attacker truncates the receipt store${NC}"
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "Deleting the last receipt from the store (simulating tail truncation)..."
python3 - "$DB_PATH" << 'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
top = db.execute("SELECT MAX(sequence) FROM receipts").fetchone()[0]
db.execute("DELETE FROM receipts WHERE sequence = ?", (top,))
db.commit()
print(f"  removed receipt seq {top}; store now ends at seq {top - 1}")
PY

# ── 5. the payoff: plain verify is fooled, the anchor catches it ──────────────
echo
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "${GREEN}${BOLD}  5. After the attack — the anchor catches what plain verify can't${NC}"
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "${BOLD}plain verify (no anchor) — still VALID, the chain is just shorter:${NC}"
obsigna verify --db "$DB_PATH" --public-key "${KEY_PATH}.pub" --chain-id "$CHAIN_ID" \
  && echo "${YELLOW}  ↑ fooled: the truncated chain verifies clean.${NC}"
echo
echo "${BOLD}verify --against-anchor — RED, the truncation is caught:${NC}"
if obsigna verify --db "$DB_PATH" --public-key "${KEY_PATH}.pub" --chain-id "$CHAIN_ID" --against-anchor "$ANCHOR_LOG"; then
  echo "${RED}  unexpected: anchor verify passed on a truncated store${NC}"
  exit 1
else
  echo "${GREEN}${BOLD}  ↑ caught. That red FAIL is the whole point.${NC}"
fi

echo
echo "${GREEN}${BOLD}Done.${NC}"
echo "Receipts: $DB_PATH    Anchor: $OB_ANCHOR_DIR (git log = the checkpoint chain)"
echo "Off-box sinks (S3 Object Lock, a SIEM, a transparency log) swap in via"
echo "--checkpoint-anchor without touching the agent path — see README."
