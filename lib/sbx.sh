# sbx.sh — shared scaffolding for the Docker-sbx examples.
#
# Source this from an example's demo.sh. It provides the host-side plumbing that
# every sbx example needs: the signing daemon, the socat TCP tunnel into the
# sandbox, the sbx network policy, sandbox lifecycle, and the side-by-side
# result display. Examples that don't use sbx simply don't source this.
#
# A demo script is expected to:
#   1. source this file
#   2. call ob_preflight (optionally with extra required commands)
#   3. populate "$WORKSPACE/.opencode/" with its own config
#   4. call ob_start_daemon, ob_start_tunnel, ob_allow_network, ob_create_sandbox
#   5. run its agent via `sbx exec`
#   6. call ob_show_results
#
# shellcheck shell=bash

WORKSPACE=/tmp/obsigna-sbx
SOCKET_PATH="$WORKSPACE/obsigna.sock"
TCP_PORT=3923
CONTAINER_SOCKET=/tmp/obsigna.sock
DB_PATH="$WORKSPACE/receipts.db"
KEY_PATH="$WORKSPACE/signing.key"
SANDBOX_NAME="obsigna-sbx-demo"
CHAIN_ID="$(date -u +%Y-%m-%d)"

BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
NC=$'\033[0m'

DAEMON_PID=""
SOCAT_PID=""
# Extra sandboxes created by multi-agent demos (see ob_create_named_sandbox).
# Single-sandbox demos leave this empty and rely on SANDBOX_NAME alone.
OB_SANDBOXES=()

ob_cleanup() {
  [ -n "$SOCAT_PID" ] && kill "$SOCAT_PID" 2>/dev/null || true
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null || true
  sbx rm -f "$SANDBOX_NAME" 2>/dev/null || true
  if [ "${#OB_SANDBOXES[@]}" -gt 0 ]; then
    local _sb
    for _sb in "${OB_SANDBOXES[@]}"; do
      sbx rm -f "$_sb" 2>/dev/null || true
    done
  fi
  rm -f "$SOCKET_PATH"
  [ -n "${OB_ANCHOR_DIR:-}" ] && rm -rf "$OB_ANCHOR_DIR"
  return 0
}
trap ob_cleanup EXIT

# ob_preflight [extra-cmd ...]
# Verifies required commands, sbx auth, ollama, and creates the devstral-demo
# model variant (32K context) if missing. Exits non-zero on any failure.
ob_preflight() {
  local missing=0 cmd
  for cmd in obsigna-daemon obsigna sbx socat "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "${RED}missing: $cmd${NC}"; missing=1; }
  done
  if ! sbx ls >/dev/null 2>&1; then
    echo "${RED}sbx not authenticated — run: sbx login${NC}"; missing=1
  fi
  if ! curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "${RED}ollama not reachable at localhost:11434${NC}"; missing=1
  fi
  # opencode's system prompt + tool schemas overflow ollama's default 4096-token
  # context, leaving the model no room to emit tool calls. Use a 32K variant.
  if ! curl -sf http://localhost:11434/api/show -d '{"name":"devstral-demo:latest"}' >/dev/null 2>&1; then
    echo "${YELLOW}devstral-demo not found in ollama — creating it (32K context window)...${NC}"
    cat > /tmp/devstral-demo.modelfile << 'EOF'
FROM devstral-small-2:latest
PARAMETER num_ctx 32768
EOF
    ollama create devstral-demo -f /tmp/devstral-demo.modelfile \
      || { echo "${RED}failed to create devstral-demo${NC}"; missing=1; }
  fi
  [ "$missing" -eq 0 ] || { echo "Fix the above and re-run."; exit 1; }
}

# ob_reset_workspace — fresh runtime workspace under a short path so the daemon
# socket stays within macOS's 103-byte AF_UNIX sun_path limit. Clears .opencode
# and work so a stale config or plugin from another demo can't leak in (opencode
# auto-loads plugins from .opencode/plugins/, which would double-count receipts).
# The cached bin/ and signing key at the workspace root are preserved.
ob_reset_workspace() {
  rm -rf "$WORKSPACE/.opencode" "$WORKSPACE/work"
  mkdir -p "$WORKSPACE/.opencode" "$WORKSPACE/work"
}

ob_ensure_key() {
  if [ ! -f "$KEY_PATH" ]; then
    echo "${BLUE}==> Generating signing key...${NC}"
    obsigna keys generate --key "$KEY_PATH"
  fi
}

# ob_start_daemon — obsigna-daemon on the host. The signing key never enters
# the VM.
#
# Optional, env-gated (off by default, so other examples are unaffected):
#   OB_CHECKPOINT_ANCHOR   sink spec passed to --checkpoint-anchor
#                          (e.g. git:/tmp/obsigna-anchor). When set, the daemon
#                          emits out-of-band signed checkpoints (ADR-0008). Put
#                          the sink OUTSIDE $WORKSPACE — $WORKSPACE is bind-mounted
#                          into the sandbox, so an anchor under it would be
#                          writable by the agent and the boundary would be a lie.
#   OB_CHECKPOINT_CADENCE  receipts between checkpoints (default 1 = every receipt).
#   OB_ANCHOR_DIR          host dir for the sink; reset on start, removed on cleanup.
ob_start_daemon() {
  rm -f "$SOCKET_PATH" "$DB_PATH"
  echo "${BLUE}==> Starting obsigna-daemon on host (outside the VM)...${NC}"
  # Build the arg list as a (never-empty) array so adding the optional
  # checkpoint flags stays safe under `set -u` even on macOS's bash 3.2.
  local args=(
    --socket "$SOCKET_PATH"
    --db "$DB_PATH"
    --key "$KEY_PATH"
    --issuer-id "did:user:${USER}@local"
    --chain-id "$CHAIN_ID"
    --unsafe-socket-path
  )
  if [ -n "${OB_CHECKPOINT_ANCHOR:-}" ]; then
    [ -n "${OB_ANCHOR_DIR:-}" ] && rm -rf "$OB_ANCHOR_DIR"
    args+=(--checkpoint-anchor "$OB_CHECKPOINT_ANCHOR")
    args+=(--checkpoint-cadence "${OB_CHECKPOINT_CADENCE:-1}")
    echo "   checkpoint anchor: $OB_CHECKPOINT_ANCHOR (cadence ${OB_CHECKPOINT_CADENCE:-1}, on host, outside the mount)"
  fi
  obsigna-daemon "${args[@]}" 2>/dev/null &
  DAEMON_PID=$!
  local _
  for _ in $(seq 1 40); do
    [ -S "$SOCKET_PATH" ] && break
    sleep 0.25
  done
  [ -S "$SOCKET_PATH" ] || { echo "${RED}daemon failed to create socket${NC}"; exit 1; }
  echo "   daemon PID=$DAEMON_PID  socket=$(basename "$SOCKET_PATH")"
}

# ob_start_tunnel — host-side socat bridge. On macOS a host Unix socket is
# visible inside a Linux container via bind-mount but not connectable, so we
# bridge through TCP and keep the daemon (and key) on the host.
ob_start_tunnel() {
  echo "${BLUE}==> Starting socat TCP bridge (host.docker.internal:$TCP_PORT → daemon)...${NC}"
  socat TCP4-LISTEN:"$TCP_PORT",fork,reuseaddr UNIX-CONNECT:"$SOCKET_PATH" &
  SOCAT_PID=$!
  sleep 0.3
  echo "   socat PID=$SOCAT_PID  port=$TCP_PORT"
}

# ob_allow_network [host:port ...] — allow ollama, the obsigna tunnel, and any
# extra host:port pairs. host.docker.internal resolves to fe80::1 inside sbx,
# which sbx classifies as localhost.
ob_allow_network() {
  echo "${BLUE}==> Configuring sbx network policy...${NC}"
  sbx policy allow network localhost:11434 2>/dev/null || true
  sbx policy allow network localhost:"$TCP_PORT" 2>/dev/null || true
  local hp
  for hp in "$@"; do
    sbx policy allow network "$hp" 2>/dev/null || true
  done
}

ob_create_sandbox() {
  sbx rm -f "$SANDBOX_NAME" 2>/dev/null || true
  echo "${BLUE}==> Creating sbx sandbox...${NC}"
  sbx create opencode "$WORKSPACE" --name "$SANDBOX_NAME" --quiet
}

# ob_create_named_sandbox NAME — create one opencode sandbox bind-mounting the
# shared $WORKSPACE under NAME, and register it for cleanup. Multi-agent demos
# call this once per agent: every sandbox mounts the SAME host workspace, so its
# work/ subdir is the shared state the isolated agents contend over.
ob_create_named_sandbox() {
  local name="$1"
  sbx rm -f "$name" 2>/dev/null || true
  echo "${BLUE}==> Creating sbx sandbox: ${name}...${NC}"
  sbx create opencode "$WORKSPACE" --name "$name" --quiet
  OB_SANDBOXES+=("$name")
}

# ob_container_tunnel_cmd — shell snippet (for use inside `sbx exec`) that
# stands up the container-side socat: a Linux Unix socket tunnelled back to the
# host daemon over TCP. Echoes the snippet; callers prepend it to their command.
ob_container_tunnel_cmd() {
  printf "rm -f %s; socat UNIX-LISTEN:%s,fork,reuseaddr TCP4:host.docker.internal:%s & for i in \$(seq 1 20); do [ -S %s ] && break; sleep 0.25; done;" \
    "$CONTAINER_SOCKET" "$CONTAINER_SOCKET" "$TCP_PORT" "$CONTAINER_SOCKET"
}

# ob_show_results — the side-by-side payoff: infra view vs agent-action view.
ob_show_results() {
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
}
