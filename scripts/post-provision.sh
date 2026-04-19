#!/bin/bash
set -uo pipefail

# =============================================================================
# post-provision.sh — azd postprovision hook entrypoint
#
# Delegates to sreagent-setup.sh with the configured AGENT_TIER.
#
# Usage: bash scripts/post-provision.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_TIER=$(azd env get-value AGENT_TIER 2>/dev/null || echo "L100")

exec bash "$SCRIPT_DIR/sreagent-setup.sh" "$AGENT_TIER"
