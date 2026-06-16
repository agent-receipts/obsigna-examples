#!/usr/bin/env bash
# multi-agent-attribution/demo.sh — attribution over shared state
#
# Reproduces https://obsigna.dev/blog/attribution-over-undo/ with real sandboxes:
# two opencode agents, each ISOLATED in its OWN Docker sbx sandbox, both editing
# ONE shared file on the host. Sandboxing keeps the agents apart; it does nothing
# for the state they share. Obsigna gives the missing piece — ATTRIBUTION: one
# signed, hash-linked receipt chain that records who changed the shared file, in
# what order, tamper-evident.
#
#   host: obsigna-daemon (one signing key, one chain)
#           ▲ socat TCP tunnel
#   host dir: /tmp/obsigna-sbx/work  ◀── the shared state both agents contend over
#       ▲ bind-mount            ▲ bind-mount
#   ┌───┴─────────────┐    ┌────┴────────────┐
#   │ sbx: alice      │    │ sbx: bob        │
#   │ opencode +      │    │ opencode +      │
#   │ obsigna-mcp     │    │ obsigna-mcp     │
#   │ operator=alice  │    │ operator=bob    │
#   └─────────────────┘    └─────────────────┘
#
# Each agent's obsigna-mcp carries a distinct --operator-id/--issuer-name. The
# daemon copies those verbatim into issuer.operator, so every receipt attributes
# its mutation to the right agent even though all share one daemon and one chain.
#
# Usage: ./demo.sh [MODEL]
#   MODEL defaults to openai-compatible/devstral-demo:latest

set -uo pipefail

DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/sbx.sh disable=SC1091
. "$DEMO_DIR/../lib/sbx.sh"

MODEL="${1:-openai-compatible/devstral-demo:latest}"

# Pin the obsigna release that supplies the Linux obsigna-mcp binary, matching
# the host daemon so the proxy and daemon stay protocol-aligned.
OBSIGNA_VERSION="${OBSIGNA_VERSION:-0.26.0}"

# The two agents that will contend over the shared file. Each name becomes a
# sandbox, an opencode config dir, and a distinct receipt operator identity.
AGENTS=(alice bob)

# The one shared file both agents edit (under the bind-mounted work dir).
SHARED_FILE="$WORKSPACE/work/deploy.yaml"

echo "${BOLD}obsigna + sbx demo — multi-agent attribution${NC}"
echo "${YELLOW}Two isolated agents, one shared file, one attributed receipt chain.${NC}"
echo

# python3 renders the attribution view (attribution.py) from receipt JSON.
ob_preflight python3

# Fresh workspace, plus the per-agent opencode config dirs (ob_reset_workspace
# only clears the single-sandbox .opencode/ and work/).
ob_reset_workspace
for agent in "${AGENTS[@]}"; do
  rm -rf "$WORKSPACE/.opencode-$agent"
done

# ── per-agent opencode config ─────────────────────────────────────────────────
# Each agent gets its own obsigna-mcp wrapping the SAME filesystem root, but with
# a distinct operator identity. That identity is the attribution axis: it rides
# the emit frame into issuer.operator on every receipt the agent produces.
write_agent_config() {
  local agent="$1"
  local dir="$WORKSPACE/.opencode-$agent"
  mkdir -p "$dir"
  cat > "$dir/opencode.json" << EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "mcp": {
    "files": {
      "type": "local",
      "command": [
        "$WORKSPACE/bin/obsigna-mcp",
        "--socket", "$CONTAINER_SOCKET",
        "--name", "files",
        "--issuer-name", "opencode/$agent",
        "--operator-id", "did:agent:$agent",
        "--operator-name", "$agent",
        "npx", "-y", "@modelcontextprotocol/server-filesystem", "$WORKSPACE/work"
      ],
      "environment": {
        "AGENTRECEIPTS_SOCKET": "$CONTAINER_SOCKET"
      }
    }
  },
  "provider": {
    "openai-compatible": {
      "options": {
        "baseURL": "http://host.docker.internal:11434/v1",
        "apiKey": "ollama"
      },
      "models": {
        "devstral-demo:latest": { "name": "Devstral Demo (32K ctx)", "tool_call": true },
        "qwen2.5-coder:32b": { "name": "Qwen 2.5 Coder 32B", "tool_call": true }
      }
    }
  },
  "model": "openai-compatible/devstral-demo:latest"
}
EOF
}

for agent in "${AGENTS[@]}"; do
  write_agent_config "$agent"
done

# ── fetch the Linux obsigna-mcp binary into the bind-mounted workspace ─────────
case "$(uname -m)" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=amd64 ;;
  *) echo "${RED}unsupported arch: $(uname -m)${NC}"; exit 1 ;;
esac
BIN_DIR="$WORKSPACE/bin"
mkdir -p "$BIN_DIR"
if [ ! -x "$BIN_DIR/obsigna-mcp" ]; then
  echo "${BLUE}==> Downloading obsigna-mcp (linux/$ARCH, v$OBSIGNA_VERSION)...${NC}"
  TARBALL="obsigna_${OBSIGNA_VERSION}_linux_${ARCH}.tar.gz"
  URL="https://github.com/agent-receipts/obsigna/releases/download/obsigna/v${OBSIGNA_VERSION}/${TARBALL}"
  TMP="$(mktemp -d)"
  curl -fsSL "$URL" -o "$TMP/$TARBALL"
  tar xzf "$TMP/$TARBALL" -C "$TMP" obsigna-mcp
  mv "$TMP/obsigna-mcp" "$BIN_DIR/obsigna-mcp"
  chmod +x "$BIN_DIR/obsigna-mcp"
  rm -rf "$TMP"
  echo "   → $BIN_DIR/obsigna-mcp"
fi

# ── host plumbing: one daemon, one tunnel, shared by every agent ──────────────
ob_ensure_key
ob_start_daemon
ob_start_tunnel
ob_allow_network registry.npmjs.org:443

# One sandbox per agent — each bind-mounts the same $WORKSPACE, so work/ is the
# shared state. Each is its own isolated Docker container.
for agent in "${AGENTS[@]}"; do
  ob_create_named_sandbox "obsigna-sbx-$agent"
done

# ── drive each agent over the shared file, in order ───────────────────────────
# Agents run sequentially so the story is deterministic: alice sets the deploy
# config, bob changes it. The daemon assigns chain sequence regardless of timing,
# so the interleaving and attribution would hold under real concurrency too.
TUNNEL="$(ob_container_tunnel_cmd)"

run_agent() {
  local agent="$1" task="$2"
  echo
  echo "${BLUE}==> Agent ${BOLD}$agent${NC}${BLUE} acting in its sandbox (model: $MODEL)...${NC}"
  sbx exec "obsigna-sbx-$agent" -- \
    sh -c "$TUNNEL AGENTRECEIPTS_SOCKET='$CONTAINER_SOCKET' OPENCODE_CONFIG_DIR='$WORKSPACE/.opencode-$agent' opencode run --model '$MODEL' '$task'"
}

ALICE_TASK="Use ONLY the files_ MCP server tools (not the built-in write/read tools). Every tool takes a parameter named exactly 'path' (an absolute path). Do this once, without asking questions:
files_write_file with path='$SHARED_FILE' and content='replicas: 2\nimage: app:1.0'.
Then stop."

BOB_TASK="Use ONLY the files_ MCP server tools (not the built-in write/read tools). Every tool takes a parameter named exactly 'path' (an absolute path). Do these steps in order, once each, without asking questions:
1. files_read_text_file with path='$SHARED_FILE' and show the contents.
2. files_write_file with path='$SHARED_FILE' and content='replicas: 5\nimage: app:2.0'.
Then stop."

run_agent alice "$ALICE_TASK"
run_agent bob "$BOB_TASK"

# ── the payoff ────────────────────────────────────────────────────────────────
sleep 0.5
echo
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "${YELLOW}${BOLD}  Shared file on the host — its final state${NC}"
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "${SHARED_FILE}:"
cat "$SHARED_FILE" 2>/dev/null || echo "(not written — model may not have called the tool)"

echo
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "${GREEN}${BOLD}  Attribution — who changed the shared file, in order${NC}"
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
obsigna receipt list --db "$DB_PATH" --json | python3 "$DEMO_DIR/attribution.py"

echo
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo "${GREEN}${BOLD}  obsigna verify — chain integrity (tamper-evident)${NC}"
echo "${BOLD}══════════════════════════════════════════════════════════════${NC}"
obsigna verify --db "$DB_PATH" --public-key "${KEY_PATH}.pub" --chain-id "$CHAIN_ID"

echo
echo "${GREEN}${BOLD}Done.${NC} Receipts stored at: $DB_PATH"
echo "Full receipt for a single act: obsigna receipt show <seq> --db $DB_PATH --json"
