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
# Signing key lives OUTSIDE $WORKSPACE. $WORKSPACE is bind-mounted read-write into
# the sandbox, so a key under it would be readable by the agent — which could then
# forge or strip receipts offline, and "the key never enters the VM" would be a
# lie. The daemon reads the key host-side; nothing in the VM needs it. (The receipt
# DB stays under $WORKSPACE on purpose: the checkpoint-anchor demo relies on the
# agent being able to tamper with the store.)
KEY_DIR=/tmp/obsigna-keys
KEY_PATH="$KEY_DIR/signing.key"
# Forensic X25519 keypair for parameter disclosure (ADR-0012). The daemon needs
# only the PUBLIC key (to HPKE-encrypt tool parameters into the receipt's
# parameters_disclosure); the PRIVATE key is held by the operator to decrypt
# later via `obsigna receipt disclose`. Both live OUTSIDE $WORKSPACE: $WORKSPACE
# is bind-mounted read-write into the sandbox, so a forensic private key under it
# would be readable by the agent — it could decrypt its own disclosed parameters
# and the boundary would be a lie (same reason the checkpoint anchor sits outside
# the mount).
FORENSIC_DIR=/tmp/obsigna-forensic
FORENSIC_KEY_PATH="$FORENSIC_DIR/forensic.key"
FORENSIC_PUBKEY_PATH="$FORENSIC_DIR/forensic.key.pub"
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

# ob_rm_anchor_dir — rm -rf the checkpoint anchor dir, but ONLY when it sits under
# the demo's /tmp/obsigna-* prefix. OB_ANCHOR_DIR is env-supplied; a typo (empty,
# '/', '$HOME', '.') must never let an `rm -rf` reach unintended host data.
ob_rm_anchor_dir() {
  case "${OB_ANCHOR_DIR:-}" in
    "") return 0 ;;
    /tmp/obsigna-*) rm -rf "$OB_ANCHOR_DIR" ;;
    *) echo "${YELLOW}refusing to rm OB_ANCHOR_DIR outside /tmp/obsigna-*: ${OB_ANCHOR_DIR}${NC}" >&2 ;;
  esac
}

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
  ob_rm_anchor_dir
  # The off-mount key dirs ($KEY_DIR, $FORENSIC_DIR) are intentionally NOT removed:
  # like the signing key always was, they're cached across runs and the printed
  # "To inspect / To disclose" commands need them after the script exits. The DB
  # they pair with persists too (it's reset at the next run's start, not here).
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
# The cached bin/ at the workspace root is preserved. (The signing key is not
# here — it lives off the mount under $KEY_DIR; see ob_ensure_key.)
ob_reset_workspace() {
  rm -rf "$WORKSPACE/.opencode" "$WORKSPACE/work"
  # Scrub any signing key left in the mount by an older version of this lib (the
  # key now lives off-mount under $KEY_DIR). Without this, an upgrade would leave
  # a forgeable key sitting in the agent-readable workspace.
  rm -f "$WORKSPACE/signing.key" "$WORKSPACE/signing.key.pub"
  mkdir -p "$WORKSPACE/.opencode" "$WORKSPACE/work"
}

ob_ensure_key() {
  if [ ! -f "$KEY_PATH" ] || [ ! -f "${KEY_PATH}.pub" ]; then
    echo "${BLUE}==> Generating signing key...${NC}"
    mkdir -p "$KEY_DIR"
    # keys generate won't overwrite an existing key; clear a half-written pair so
    # a missing .pub (which `obsigna verify` needs) self-heals.
    rm -f "$KEY_PATH" "${KEY_PATH}.pub"
    obsigna keys generate --key "$KEY_PATH"
  fi
}

# ob_ensure_forensic_key — generate the X25519 forensic keypair (ADR-0012) used
# for parameter disclosure, if it doesn't already exist. Called from
# ob_start_daemon so every sbx example gets disclosure with no per-demo wiring.
#
# On a normal host, `obsigna-daemon --init` now bundles this — it generates the
# forensic keypair and writes a disclosure-on config in one step. We deliberately
# use the standalone `--init-forensic-key` here instead, because --init writes the
# private key to the default local path; in the sandbox the private key must live
# OUTSIDE $WORKSPACE (see FORENSIC_DIR above) so the agent cannot decrypt its own
# disclosed parameters.
ob_ensure_forensic_key() {
  if [ ! -f "$FORENSIC_KEY_PATH" ] || [ ! -f "$FORENSIC_PUBKEY_PATH" ]; then
    echo "${BLUE}==> Generating forensic key (parameter disclosure)...${NC}"
    # --init-forensic-key refuses to overwrite EITHER output, so a half-written
    # pair from an interrupted run (private present, public missing, or vice
    # versa) would make it error and the daemon would then fail to start on the
    # missing public key. Clear any partial pair first so generation is atomic.
    rm -rf "$FORENSIC_DIR"
    mkdir -p "$FORENSIC_DIR"
    obsigna-daemon --init-forensic-key \
      --forensic-key "$FORENSIC_KEY_PATH" \
      --forensic-public-key "$FORENSIC_PUBKEY_PATH" >/dev/null
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
  ob_ensure_forensic_key
  echo "${BLUE}==> Starting obsigna-daemon on host (outside the VM)...${NC}"
  # Build the arg list as a (never-empty) array so adding the optional
  # checkpoint flags stays safe under `set -u` even on macOS's bash 3.2.
  #
  # Parameter disclosure (ADR-0012) is on for every sbx example: the daemon
  # HPKE-encrypts each tool call's parameters to the forensic PUBLIC key and
  # stores the envelope in the receipt's parameters_disclosure. The signed
  # receipt still carries only the parameter HASH for integrity; the cleartext
  # is recoverable solely by the forensic PRIVATE-key holder (see
  # ob_show_results' `obsigna receipt disclose`). --forensic-public-key is
  # required for disclosure to take effect — without it --parameter-disclosure
  # is inert (and the daemon refuses to start if the path is missing).
  local args=(
    --socket "$SOCKET_PATH"
    --db "$DB_PATH"
    --key "$KEY_PATH"
    --issuer-id "did:user:${USER}@local"
    --chain-id "$CHAIN_ID"
    --unsafe-socket-path
    --forensic-public-key "$FORENSIC_PUBKEY_PATH"
    --parameter-disclosure true
  )
  if [ -n "${OB_CHECKPOINT_ANCHOR:-}" ]; then
    ob_rm_anchor_dir
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
  echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
  echo "${GREEN}${BOLD}  obsigna receipt disclose — forensic recovery of parameters${NC}"
  echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
  echo "The signed receipt carries only a parameter HASH. The cleartext is HPKE-"
  echo "encrypted (ADR-0012) and recoverable solely with the forensic private key,"
  echo "which lives on the host outside the sandbox mount — so the actual file"
  echo "contents written and shell commands run are recoverable, not just hashes:"
  ob_disclose_all

  echo
  echo "${GREEN}${BOLD}Done.${NC} Receipts stored at: $DB_PATH"
  echo "To inspect:  obsigna receipt show 1 --db $DB_PATH --chain-id $CHAIN_ID"
  echo "To disclose: obsigna receipt disclose 1 --db $DB_PATH --chain-id $CHAIN_ID --key $FORENSIC_KEY_PATH"
}

# ob_disclose_all — decrypt and print the parameters of every receipt that
# carries a disclosure envelope. Not every receipt type has one (lifecycle
# markers don't), so scan from seq 1 and print each success; for `bash` receipts
# this reveals the exact command string that ran, not just its hash. Honest
# sentinel if none disclosed.
ob_disclose_all() {
  # Walk receipts from seq 1. A receipt that exists but carries no envelope exits
  # 0 with empty stdout; a nonexistent seq ends the chain cleanly with a "no
  # receipt at sequence N" stderr note. Any OTHER non-zero exit (e.g. an
  # unreadable forensic private key) is a real failure we surface — never report
  # it as "nothing to disclose". Byte-identical disclosures (e.g. repeated todo
  # snapshots) are collapsed so distinct actions stay readable.
  local seq=1 out rc found=0 errored=0 dups=0
  # Explicit trailing-X template (portable across GNU/BSD) under the demo's
  # /tmp/obsigna-* prefix, so the temp file is recognizable and matches the
  # cleanup conventions used elsewhere here.
  local errfile; errfile="$(mktemp /tmp/obsigna-disclose.XXXXXX)"
  local -a shown=()
  while :; do
    # Keep the disclose in an `if` condition: a command substitution that exits
    # non-zero in a plain assignment would abort the demo under `set -e` (which
    # mcp-proxy/opencode-plugin use). The condition form is exempt, so we capture
    # the real exit status instead of dying at end-of-chain.
    if out="$(obsigna receipt disclose "$seq" --db "$DB_PATH" --chain-id "$CHAIN_ID" --key "$FORENSIC_KEY_PATH" 2>"$errfile")"; then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      if ! grep -q "no receipt at sequence" "$errfile"; then
        errored=1
        echo "${YELLOW}  disclosure failed: $(cat "$errfile")${NC}"
      fi
      break
    fi
    if [ -n "$out" ]; then
      local dup=0 s
      if [ "${#shown[@]}" -gt 0 ]; then
        for s in "${shown[@]}"; do [ "$s" = "$out" ] && { dup=1; break; }; done
      fi
      if [ "$dup" -eq 1 ]; then
        dups=$((dups + 1))
      else
        shown+=("$out")
        found=1
        echo "${BOLD}  receipt #$seq parameters:${NC}"
        while IFS= read -r line; do echo "    $line"; done <<< "$out"
      fi
    fi
    seq=$((seq + 1))
  done
  rm -f "$errfile"
  [ "$dups" -gt 0 ] && echo "${YELLOW}  (+$dups later receipt(s) disclosed identical parameters)${NC}"
  { [ "$found" -eq 0 ] && [ "$errored" -eq 0 ]; } && echo "${YELLOW}  (no receipt carried a disclosure envelope)${NC}"
  return 0
}
