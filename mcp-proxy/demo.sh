#!/usr/bin/env bash
# mcp-proxy/demo.sh — receipts via the MCP proxy (Tier A)
#
# Captures MCP tool calls. Unlike the plugin (which hooks opencode's native
# tools in-process), obsigna-mcp sits IN the data path: opencode launches it as
# an MCP server, and it transparently wraps a downstream MCP server, signing a
# receipt for every tools/call that passes through. The agent cannot route
# around it — that's the adversary-resistant ("Tier A") property.
#
#   opencode ──stdio──▶ obsigna-mcp ──stdio──▶ @modelcontextprotocol/server-filesystem
#                            │
#                            └─▶ AGENTRECEIPTS_SOCKET ─▶ tunnel ─▶ host daemon
#
# obsigna-mcp runs INSIDE the sandbox, so the Linux binary is downloaded from
# the obsigna release and placed in the bind-mounted workspace.
#
# See ../README.md for prerequisites and architecture.
#
# Usage: ./demo.sh [MODEL]
#   MODEL defaults to openai-compatible/devstral-demo:latest

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
. "$DEMO_DIR/../lib/common.sh"

MODEL="${1:-openai-compatible/devstral-demo:latest}"

# Pin the obsigna release that supplies the Linux obsigna-mcp binary. Using the
# main obsigna release keeps the proxy and the host daemon protocol-aligned.
OBSIGNA_VERSION="${OBSIGNA_VERSION:-0.26.0}"

echo "${BOLD}obsigna + sbx demo — MCP proxy (Tier A)${NC}"
echo

ar_preflight
ar_reset_workspace
cp "$DEMO_DIR/opencode.json" "$WORKSPACE/.opencode/opencode.json"

# ── fetch the Linux obsigna-mcp binary into the bind-mounted workspace ─────────
# The sandbox arch matches the host under Docker Desktop.
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

ar_ensure_key
ar_start_daemon
ar_start_tunnel
# npx pulls the filesystem MCP server from npm on first launch inside the VM.
ar_allow_network registry.npmjs.org:443
ar_create_sandbox

# Steer the model to the MCP server's tools (not opencode's native write/read),
# since only calls that pass through obsigna-mcp get receipted.
TASK="Use ONLY the files_ MCP server tools (not the built-in write/read tools). Every tool takes a parameter named exactly 'path' (an absolute path). Do these steps in order, once each, without asking questions:
1. files_write_file with path='/tmp/obsigna-sbx/work/greeting.txt' and content='Hello from MCP'.
2. files_read_text_file with path='/tmp/obsigna-sbx/work/greeting.txt' and show the contents.
3. files_list_directory with path='/tmp/obsigna-sbx/work'.
Then stop."

echo "${BLUE}==> Running opencode agent inside sbx (model: $MODEL)...${NC}"
echo "${YELLOW}    Task: drive the filesystem MCP server through the obsigna-mcp proxy${NC}"
echo

TUNNEL="$(ar_container_tunnel_cmd)"
sbx exec "$SANDBOX_NAME" -- \
  sh -c "$TUNNEL AGENTRECEIPTS_SOCKET='$CONTAINER_SOCKET' OPENCODE_CONFIG_DIR='$WORKSPACE/.opencode' opencode run --model '$MODEL' '$TASK'"

ar_show_results
