#!/bin/bash
set -uo pipefail

# =============================================================================
# post-provision.sh — azd postprovision hook entrypoint
#
# This is the entrypoint called by azd after infrastructure provisioning.
# It delegates to post-configure-agent.sh for the actual SRE Agent configuration.
#
# To run manually: bash scripts/post-configure-agent.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

exec bash "$SCRIPT_DIR/post-configure-agent.sh"
