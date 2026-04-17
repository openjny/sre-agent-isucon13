#!/bin/bash
set -euo pipefail

# ISUCON13 Environment Bootstrap Script
# Runs via Custom Script Extension on Azure VMs.
# Usage: bootstrap.sh --role <contest|bench> --contest-ips <ip1,ip2,ip3> --bench-ip <ip> [--vm-index <n>]

LOG_FILE="/var/log/isucon13-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== ISUCON13 Bootstrap started at $(date -u) ==="

# Parse arguments
ROLE=""
CONTEST_IPS=""
BENCH_IP=""
VM_INDEX=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --contest-ips) CONTEST_IPS="$2"; shift 2 ;;
    --bench-ip) BENCH_IP="$2"; shift 2 ;;
    --vm-index) VM_INDEX="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$ROLE" || -z "$CONTEST_IPS" || -z "$BENCH_IP" ]]; then
  echo "ERROR: --role, --contest-ips, --bench-ip are required"
  exit 1
fi

echo "Role: $ROLE, Contest IPs: $CONTEST_IPS, Bench IP: $BENCH_IP, VM Index: $VM_INDEX"

# Save config for later use
mkdir -p /etc/isucon13
cat > /etc/isucon13/config.env <<EOF
ROLE=$ROLE
CONTEST_IPS=$CONTEST_IPS
BENCH_IP=$BENCH_IP
VM_INDEX=$VM_INDEX
EOF

# ============================================================
# 1. Install base packages
# ============================================================

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq \
  ansible \
  git \
  curl \
  wget \
  jq \
  unzip \
  build-essential \
  software-properties-common

# ============================================================
# 2. Create isucon user (if not exists)
# ============================================================

if ! id isucon &>/dev/null; then
  useradd -m -s /bin/bash isucon
  echo "isucon ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/isucon
fi

# Copy SSH keys from admin user
if [[ -d /home/isucon/.ssh ]]; then
  echo "SSH dir already exists"
else
  mkdir -p /home/isucon/.ssh
  cp /home/isucon/../isucon/.ssh/authorized_keys /home/isucon/.ssh/ 2>/dev/null || \
    cp /home/*/.ssh/authorized_keys /home/isucon/.ssh/ 2>/dev/null || true
  chown -R isucon:isucon /home/isucon/.ssh
  chmod 700 /home/isucon/.ssh
  chmod 600 /home/isucon/.ssh/authorized_keys 2>/dev/null || true
fi

# ============================================================
# 3. Clone ISUCON13 repository
# ============================================================

ISUCON_DIR="/home/isucon/isucon13"
if [[ ! -d "$ISUCON_DIR" ]]; then
  git clone --depth 1 https://github.com/isucon/isucon13.git "$ISUCON_DIR"
  chown -R isucon:isucon "$ISUCON_DIR"
fi

# ============================================================
# 4. Install Go
# ============================================================

GO_VERSION="1.21.5"
if [[ ! -f /usr/local/go/bin/go ]]; then
  wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm /tmp/go.tar.gz
fi

export PATH="/usr/local/go/bin:$PATH"
echo 'export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"' > /etc/profile.d/go.sh

# ============================================================
# 5. Run role-specific setup
# ============================================================

if [[ "$ROLE" == "contest" ]]; then
  echo "=== Setting up CONTEST server ==="
  bash "$(dirname "$0")/setup-contest.sh"
elif [[ "$ROLE" == "bench" ]]; then
  echo "=== Setting up BENCHMARK server ==="
  bash "$(dirname "$0")/setup-bench.sh"
fi

echo "=== ISUCON13 Bootstrap completed at $(date -u) ==="
