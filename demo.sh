#!/usr/bin/env bash
# demo.sh — obsigna + sbx side-by-side audit demo
#
# Runs an opencode agent inside a Docker sbx microVM and shows two
# non-overlapping audit layers:
#   sbx policy log  → what the infrastructure allowed / blocked
#   obsigna verify  → what the agent actually did (signed receipts, outside the VM)
#
# Architecture:
#   obsigna-daemon runs on the HOST (signing key never enters the VM).
#   On macOS, host Unix sockets can't be connected to from inside a Linux
#   container, so a socat TCP tunnel bridges the two:
#
#     plugin (container) → /tmp/obsigna.sock (Linux)
#       → socat (container) → host.docker.internal:3923 (TCP)
#         → socat (host) → /tmp/obsigna-sbx/obsigna.sock (macOS)
#           → obsigna-daemon (host)
#
# The opencode plugin is installed from npm by opencode itself (declared in
# opencode/opencode.json), so there is no build step here.
#
# Prerequisites: obsigna-daemon, obsigna, sbx (authenticated), socat, ollama
#   Install obsigna:  https://github.com/agent-receipts/obsigna#install
#   Install sbx:      https://github.com/docker/sandboxes
#
# Usage: ./demo.sh [MODEL]
#   MODEL defaults to openai-compatible/devstral-demo:latest
#   (devstral-demo is a devstral-small-2 variant with a 32K context window)

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE=/tmp/obsigna-sbx
SOCKET_PATH="$WORKSPACE/obsigna.sock"
TCP_PORT=3923
CONTAINER_SOCKET=/tmp/obsigna.sock
DB_PATH="$WORKSPACE/receipts.db"
KEY_PATH="$WORKSPACE/signing.key"
SANDBOX_NAME="obsigna-sbx-demo"
MODEL="${1:-openai-compatible/devstral-demo:latest}"

BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
NC=$'\033[0m'

DAEMON_PID=""
SOCAT_PID=""

cleanup() {
  [ -n "$SOCAT_PID" ] && kill "$SOCAT_PID" 2>/dev/null || true
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null || true
  sbx rm -f "$SANDBOX_NAME" 2>/dev/null || true
  rm -f "$SOCKET_PATH"
}
trap cleanup EXIT

# ── preflight ──────────────────────────────────────────────────────────────────

echo "${BOLD}obsigna + sbx demo${NC}"
echo

missing=0
for cmd in obsigna-daemon obsigna sbx socat; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "${RED}missing: $cmd${NC}"; missing=1; }
done
if ! sbx ls >/dev/null 2>&1; then
  echo "${RED}sbx not authenticated — run: sbx login${NC}"; missing=1
fi
if ! curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
  echo "${RED}ollama not reachable at localhost:11434${NC}"; missing=1
fi
# Create devstral-demo (devstral-small-2 with a larger context window) on first run.
# opencode's system prompt + tool schemas overflow ollama's default 4096-token
# context, which leaves the model no room to emit tool calls.
if ! curl -sf http://localhost:11434/api/show -d '{"name":"devstral-demo:latest"}' >/dev/null 2>&1; then
  echo "${YELLOW}devstral-demo not found in ollama — creating it (32K context window)...${NC}"
  cat > /tmp/devstral-demo.modelfile << 'EOF'
FROM devstral-small-2:latest
PARAMETER num_ctx 32768
EOF
  ollama create devstral-demo -f /tmp/devstral-demo.modelfile || { echo "${RED}failed to create devstral-demo${NC}"; missing=1; }
fi
[ "$missing" -eq 0 ] || { echo "Fix the above and re-run."; exit 1; }

# ── workspace setup ────────────────────────────────────────────────────────────

mkdir -p "$WORKSPACE/.opencode" "$WORKSPACE/work"
cp "$DEMO_DIR/opencode/opencode.json" "$WORKSPACE/.opencode/opencode.json"

# ── signing key ────────────────────────────────────────────────────────────────

if [ ! -f "$KEY_PATH" ]; then
  echo "${BLUE}==> Generating signing key...${NC}"
  obsigna keys generate --key "$KEY_PATH"
fi

# ── daemon (host side, outside the VM) ────────────────────────────────────────

CHAIN_ID="$(date -u +%Y-%m-%d)"
rm -f "$SOCKET_PATH" "$DB_PATH"
echo "${BLUE}==> Starting obsigna-daemon on host (outside the VM)...${NC}"
obsigna-daemon \
  --socket "$SOCKET_PATH" \
  --db "$DB_PATH" \
  --key "$KEY_PATH" \
  --issuer-id "did:user:${USER}@local" \
  --chain-id "$CHAIN_ID" \
  --unsafe-socket-path \
  2>/dev/null &
DAEMON_PID=$!

for _ in $(seq 1 40); do
  [ -S "$SOCKET_PATH" ] && break
  sleep 0.25
done
[ -S "$SOCKET_PATH" ] || { echo "${RED}daemon failed to create socket${NC}"; exit 1; }
echo "   daemon PID=$DAEMON_PID  socket=$(basename "$SOCKET_PATH")"

# ── socat TCP bridge (host side) ───────────────────────────────────────────────
# On macOS, host Unix sockets can't be connected to from inside a Linux
# container via bind-mount. Bridge: TCP port → Unix socket.

echo "${BLUE}==> Starting socat TCP bridge (host.docker.internal:$TCP_PORT → daemon)...${NC}"
socat TCP4-LISTEN:"$TCP_PORT",fork,reuseaddr UNIX-CONNECT:"$SOCKET_PATH" &
SOCAT_PID=$!
sleep 0.3
echo "   socat PID=$SOCAT_PID  port=$TCP_PORT"

# ── sbx network policy ─────────────────────────────────────────────────────────

echo "${BLUE}==> Configuring sbx network policy...${NC}"
# host.docker.internal resolves to fe80::1 inside sbx, which sbx classifies as localhost
sbx policy allow network localhost:11434 2>/dev/null || true       # ollama
sbx policy allow network localhost:"$TCP_PORT" 2>/dev/null || true # obsigna tunnel

# ── sandbox ────────────────────────────────────────────────────────────────────

sbx rm -f "$SANDBOX_NAME" 2>/dev/null || true
echo "${BLUE}==> Creating sbx sandbox...${NC}"
sbx create opencode "$WORKSPACE" \
  --name "$SANDBOX_NAME" \
  --quiet

# ── agent task ─────────────────────────────────────────────────────────────────

TASK="Complete these steps in order without asking questions:
1. Write a Python script to work/fibonacci.py that prints the first 10 Fibonacci numbers (no user input, hardcoded to 10).
2. Run it with python3 and show the output.
3. Run this exact command and show the output: curl -s --max-time 3 https://worldtimeapi.org/api/timezone/UTC || echo '[blocked by network policy]'"

echo "${BLUE}==> Running opencode agent inside sbx (model: $MODEL)...${NC}"
echo "${YELLOW}    Task: write fibonacci.py → run it → attempt outbound network call${NC}"
echo

# The container-side socat bridges the plugin's Unix socket to the host via TCP.
# Container: /tmp/obsigna.sock → host.docker.internal:TCP_PORT → daemon socket
CONTAINER_SOCAT_CMD="rm -f $CONTAINER_SOCKET; socat UNIX-LISTEN:$CONTAINER_SOCKET,fork,reuseaddr TCP4:host.docker.internal:$TCP_PORT &"
WAIT_FOR_SOCK="for i in \$(seq 1 20); do [ -S $CONTAINER_SOCKET ] && break; sleep 0.25; done"

sbx exec "$SANDBOX_NAME" -- \
  sh -c "$CONTAINER_SOCAT_CMD $WAIT_FOR_SOCK && AGENTRECEIPTS_SOCKET='$CONTAINER_SOCKET' OPENCODE_CONFIG_DIR='$WORKSPACE/.opencode' opencode run --model '$MODEL' '$TASK'"

# ── output ─────────────────────────────────────────────────────────────────────

echo
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "${YELLOW}${BOLD}  sbx policy log — what the infrastructure allowed / blocked${NC}"
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
sbx policy log "$SANDBOX_NAME"

echo
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "${GREEN}${BOLD}  obsigna receipt list — what the agent actually did${NC}"
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
obsigna receipt list --db "$DB_PATH"

echo
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "${GREEN}${BOLD}  obsigna verify — chain integrity${NC}"
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
obsigna verify --db "$DB_PATH" --public-key "${KEY_PATH}.pub" --chain-id "$CHAIN_ID"

echo
echo "${GREEN}${BOLD}Done.${NC} Receipts stored at: $DB_PATH"
echo "To inspect: obsigna receipt show 1 --db $DB_PATH --chain-id $CHAIN_ID"
