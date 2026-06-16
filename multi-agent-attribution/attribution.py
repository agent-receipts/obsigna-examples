#!/usr/bin/env python3
# attribution.py — render the per-agent attribution view of a receipt chain.
#
# `obsigna receipt list` (text) shows sequence, time, and tool, but NOT who
# acted — the per-agent identity lives in issuer.operator / issuer.name, which
# the daemon copies verbatim from each agent's obsigna-mcp. This view surfaces
# it: one shared file, one chain, every mutation attributed to the right agent.
#
# Usage: obsigna receipt list --db <db> --json | attribution.py
import sys
import json


def seq(receipt):
    return receipt.get("credentialSubject", {}).get("chain", {}).get("sequence", 0)


def main():
    receipts = json.load(sys.stdin)
    print("SEQ  OPERATOR (who acted)   AGENT NAME       TOOL")
    print("---  ---------------------  ---------------  -----------------")
    for r in sorted(receipts, key=seq):
        issuer = r.get("issuer") or {}
        operator = issuer.get("operator") or {}
        action = (r.get("credentialSubject") or {}).get("action") or {}
        tool = action.get("tool_name", "-")
        # Synthetic chain-control receipts (chain_interrupted, key_rotated) carry
        # no operator — they are the daemon's own bookkeeping, not an agent act.
        operator_id = operator.get("id") or "(daemon)"
        agent_name = issuer.get("name") or "-"
        print("%3d  %-21s  %-15s  %s" % (seq(r), operator_id, agent_name, tool))


if __name__ == "__main__":
    main()
