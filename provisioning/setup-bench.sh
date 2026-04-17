#!/bin/bash
set -euo pipefail

# Benchmark VM setup: build benchmarker
source /etc/isucon13/config.env
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/go/bin:$PATH"
export GOPATH="/home/isucon/go"
export GOMODCACHE="/home/isucon/go/pkg/mod"

ISUCON_DIR="/home/isucon/isucon13"
IFS=',' read -ra CONTEST_IP_ARRAY <<< "$CONTEST_IPS"

# ============================================================
# Build benchmarker
# ============================================================

BENCH_DIR="$ISUCON_DIR/bench"
if [[ -d "$BENCH_DIR" ]]; then
  cd "$BENCH_DIR"
  # bench directory may have a subdirectory structure - find main package
  if [[ -f "$BENCH_DIR/main.go" ]] || ls "$BENCH_DIR"/*.go &>/dev/null; then
    sudo -u isucon -E bash -c "export HOME=/home/isucon && export GOPATH=/home/isucon/go && export GOMODCACHE=/home/isucon/go/pkg/mod && export PATH=/usr/local/go/bin:\$PATH && cd $BENCH_DIR && go build -o bench_linux_amd64 ."
  else
    # Try make if available
    sudo -u isucon -E bash -c "export HOME=/home/isucon && export GOPATH=/home/isucon/go && export GOMODCACHE=/home/isucon/go/pkg/mod && export PATH=/usr/local/go/bin:\$PATH && cd $BENCH_DIR && make" 2>/dev/null || true
  fi
fi

# ============================================================
# Create run-benchmark helper script
# ============================================================

cat > /home/isucon/run-benchmark.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
source /etc/isucon13/config.env
IFS=',' read -ra IPS <<< "$CONTEST_IPS"

TARGET_IP="${IPS[0]}"
WEBAPP_ARGS=""
for ip in "${IPS[@]:1}"; do
  WEBAPP_ARGS="$WEBAPP_ARGS --webapp $ip"
done

cd /home/isucon/isucon13/bench
./bench_linux_amd64 run \
  --target "https://pipe.u.isucon.dev" \
  --nameserver "$TARGET_IP" \
  --enable-ssl \
  $WEBAPP_ARGS \
  "$@"
SCRIPT

chmod +x /home/isucon/run-benchmark.sh
chown isucon:isucon /home/isucon/run-benchmark.sh

echo "=== Benchmark VM setup complete ==="
echo "Run benchmark: sudo -u isucon /home/isucon/run-benchmark.sh"
