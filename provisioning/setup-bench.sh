#!/bin/bash
set -euo pipefail

# Benchmark VM setup: build benchmarker
source /etc/isucon13/config.env
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/go/bin:$PATH"

ISUCON_DIR="/home/isucon/isucon13"
IFS=',' read -ra CONTEST_IP_ARRAY <<< "$CONTEST_IPS"

# ============================================================
# Build benchmarker
# ============================================================

BENCH_DIR="$ISUCON_DIR/bench"
if [[ -d "$BENCH_DIR" ]]; then
  cd "$BENCH_DIR"
  sudo -u isucon -E bash -c "cd $BENCH_DIR && /usr/local/go/bin/go build -o bench_linux_amd64 ."
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
