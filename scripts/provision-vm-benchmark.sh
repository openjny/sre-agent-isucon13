#!/bin/bash
set -euo pipefail

# Benchmark VM setup: build benchmarker
source /etc/isucon13/config.env
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/go/bin:$PATH"
export GOPATH="/home/isucon/go"
export GOMODCACHE="/home/isucon/go/pkg/mod"

ISUCON_DIR="/home/isucon/isucon13"

# ============================================================
# Trust TLS certificate from Key Vault (for benchmarker SSL)
# ============================================================

if [[ -n ${KEY_VAULT_NAME:-} ]]; then
	echo "Fetching TLS certificate from Key Vault for CA trust: $KEY_VAULT_NAME"
	TOKEN=$(curl -s 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -H Metadata:true | jq -r '.access_token')
	KV_URL="https://${KEY_VAULT_NAME}.vault.azure.net"
	curl -s "${KV_URL}/secrets/tls-cert?api-version=7.4" -H "Authorization: Bearer ${TOKEN}" | jq -r '.value' >/usr/local/share/ca-certificates/isucon.crt
	update-ca-certificates
fi

IFS=',' read -ra CONTEST_IP_ARRAY <<<"$CONTEST_IPS"
export CONTEST_IP_ARRAY

# ============================================================
# Build benchmarker
# ============================================================

BENCH_DIR="$ISUCON_DIR/bench"
if [[ -d $BENCH_DIR ]]; then
	cd "$BENCH_DIR"
	# bench directory may have a subdirectory structure - find main package
	if [[ -f "$BENCH_DIR/main.go" ]] || ls "$BENCH_DIR"/*.go &>/dev/null; then
		sudo -u isucon -E bash -c "export HOME=/home/isucon && export GOPATH=/home/isucon/go && export GOMODCACHE=/home/isucon/go/pkg/mod && export PATH=/usr/local/go/bin:\$PATH && cd $BENCH_DIR && go build -o bin/bench_linux_amd64 ."
	else
		# Try make if available
		sudo -u isucon -E bash -c "export HOME=/home/isucon && export GOPATH=/home/isucon/go && export GOMODCACHE=/home/isucon/go/pkg/mod && export PATH=/usr/local/go/bin:\$PATH && cd $BENCH_DIR && make" 2>/dev/null || true
	fi
fi

# ============================================================
# Create run-benchmark helper script
# ============================================================

cat >/home/isucon/run-benchmark.sh <<'SCRIPT'
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
./bin/bench_linux_amd64 run \
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
