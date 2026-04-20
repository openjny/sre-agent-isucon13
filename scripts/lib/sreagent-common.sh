#!/bin/bash
# =============================================================================
# scripts/lib/sreagent-common.sh — Shared bootstrap for SRE Agent scripts
#
# Source this from sreagent-*.sh scripts:
#   source "$(dirname "$0")/lib/sreagent-common.sh"
#
# Provides:
#   $SRECTL   — path to srectl wrapper
#   $ROOT_DIR — project root
#   Exports SRE_AGENT_ENDPOINT and SRE_AGENT_TOKEN for cross-process caching
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRECTL="$SCRIPT_DIR/srectl"

# Ensure srectl is available
if [ ! -x "$SRECTL" ]; then
	chmod +x "$SRECTL"
fi

# Pre-resolve endpoint + token (one az call per script run)
if [ -z "${SRE_AGENT_ENDPOINT:-}" ]; then
	SRE_AGENT_ENDPOINT=$(azd env get-value SRE_AGENT_ENDPOINT 2>/dev/null || echo "")
	export SRE_AGENT_ENDPOINT
fi
if [ -z "${SRE_AGENT_TOKEN:-}" ]; then
	SRE_AGENT_TOKEN=$(az account get-access-token --resource https://azuresre.ai --query accessToken -o tsv 2>/dev/null || echo "")
	export SRE_AGENT_TOKEN
fi
