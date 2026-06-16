#!/usr/bin/env bash
# opencode-plugin/demo.sh — receipts via the opencode plugin
#
# Captures opencode's NATIVE tool calls (write, bash, edit). The obsigna
# plugin is installed from npm by opencode itself (declared in opencode.json),
# so there is no build step.
#
# See ../README.md for prerequisites and architecture.
#
# Usage: ./demo.sh [MODEL]
#   MODEL defaults to openai-compatible/devstral-demo:latest

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/sbx.sh disable=SC1091
. "$DEMO_DIR/../lib/sbx.sh"

MODEL="${1:-openai-compatible/devstral-demo:latest}"

echo "${BOLD}obsigna + sbx demo — opencode plugin${NC}"
echo

ar_preflight
ar_reset_workspace
cp "$DEMO_DIR/opencode.json" "$WORKSPACE/.opencode/opencode.json"
ar_ensure_key
ar_start_daemon
ar_start_tunnel
ar_allow_network
ar_create_sandbox

TASK="Complete these steps in order without asking questions:
1. Write a Python script to work/fibonacci.py that prints the first 10 Fibonacci numbers (no user input, hardcoded to 10).
2. Run it with python3 and show the output.
3. Run this exact command and show the output: curl -s --max-time 3 https://worldtimeapi.org/api/timezone/UTC || echo '[blocked by network policy]'"

echo "${BLUE}==> Running opencode agent inside sbx (model: $MODEL)...${NC}"
echo "${YELLOW}    Task: write fibonacci.py → run it → attempt outbound network call${NC}"
echo

TUNNEL="$(ar_container_tunnel_cmd)"
sbx exec "$SANDBOX_NAME" -- \
  sh -c "$TUNNEL AGENTRECEIPTS_SOCKET='$CONTAINER_SOCKET' OPENCODE_CONFIG_DIR='$WORKSPACE/.opencode' opencode run --model '$MODEL' '$TASK'"

ar_show_results
