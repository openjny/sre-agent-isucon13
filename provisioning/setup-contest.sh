#!/bin/bash
set -euo pipefail

# Contest VM setup: MySQL, nginx, PowerDNS, Go webapp
source /etc/isucon13/config.env
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/go/bin:$PATH"
export GOPATH="/home/isucon/go"
export GOMODCACHE="/home/isucon/go/pkg/mod"

ISUCON_DIR="/home/isucon/isucon13"
IFS=',' read -ra CONTEST_IP_ARRAY <<< "$CONTEST_IPS"
MY_IP="${CONTEST_IP_ARRAY[$((VM_INDEX - 1))]}"

# ============================================================
# MySQL 8.0
# ============================================================

if ! command -v mysql &>/dev/null; then
  echo "Installing MySQL 8.0..."
  apt-get install -y -qq mysql-server mysql-client
fi

systemctl enable mysql
systemctl start mysql

# Create databases and users
mysql -e "CREATE DATABASE IF NOT EXISTS isupipe;"
mysql -e "CREATE DATABASE IF NOT EXISTS isudns;"
mysql -e "CREATE USER IF NOT EXISTS 'isucon'@'localhost' IDENTIFIED BY 'isucon';"
mysql -e "GRANT ALL PRIVILEGES ON isupipe.* TO 'isucon'@'localhost';"
mysql -e "GRANT ALL PRIVILEGES ON isudns.* TO 'isucon'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# Load schema (idempotent - ignore errors if tables exist)
if [[ -f "$ISUCON_DIR/webapp/sql/initdb.d/10_schema.sql" ]]; then
  mysql isupipe < "$ISUCON_DIR/webapp/sql/initdb.d/10_schema.sql" 2>/dev/null || true
fi

# ============================================================
# nginx
# ============================================================

if ! command -v nginx &>/dev/null; then
  apt-get install -y -qq nginx
fi

# Copy TLS certs from isucon13 repo
CERT_DIR="/etc/nginx/tls"
mkdir -p "$CERT_DIR"
if [[ -d "$ISUCON_DIR/provisioning/ansible/roles/nginx/files/etc/nginx/tls" ]]; then
  cp "$ISUCON_DIR/provisioning/ansible/roles/nginx/files/etc/nginx/tls/"* "$CERT_DIR/"
fi

# Generate nginx config
cat > /etc/nginx/sites-available/isupipe.conf <<'NGINX_CONF'
server {
    listen 443 ssl;
    server_name *.u.isucon.dev;

    ssl_certificate /etc/nginx/tls/_.u.isucon.dev.crt;
    ssl_certificate_key /etc/nginx/tls/_.u.isucon.dev.key;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX_CONF

ln -sf /etc/nginx/sites-available/isupipe.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

systemctl enable nginx
systemctl restart nginx

# ============================================================
# PowerDNS
# ============================================================

if ! command -v pdns_server &>/dev/null; then
  apt-get install -y -qq pdns-server pdns-backend-mysql
fi

# Disable systemd-resolved to free port 53
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# Configure PowerDNS
cat > /etc/powerdns/pdns.conf <<PDNS_CONF
launch=gmysql
gmysql-host=127.0.0.1
gmysql-port=3306
gmysql-dbname=isudns
gmysql-user=isucon
gmysql-password=isucon
local-address=0.0.0.0
local-port=53
PDNS_CONF

# Initialize PowerDNS schema
if [[ -f /usr/share/doc/pdns-backend-mysql/schema.mysql.sql ]]; then
  mysql isudns < /usr/share/doc/pdns-backend-mysql/schema.mysql.sql 2>/dev/null || true
fi

systemctl enable pdns
systemctl restart pdns

# Initialize DNS zone with VM Private IPs
sleep 2
pdnsutil create-zone u.isucon.dev 2>/dev/null || true
for ip in "${CONTEST_IP_ARRAY[@]}"; do
  pdnsutil add-record u.isucon.dev pipe A 30 "$ip" 2>/dev/null || true
done

# ============================================================
# Build Go webapp
# ============================================================

WEBAPP_DIR="$ISUCON_DIR/webapp/go"
if [[ -d "$WEBAPP_DIR" ]]; then
  cd "$WEBAPP_DIR"
  sudo -u isucon -E bash -c "export HOME=/home/isucon && export GOPATH=/home/isucon/go && export GOMODCACHE=/home/isucon/go/pkg/mod && export PATH=/usr/local/go/bin:\$PATH && cd $WEBAPP_DIR && go build -o isupipe ."
fi

# ============================================================
# systemd service for isupipe-go
# ============================================================

cat > /etc/systemd/system/isupipe-go.service <<SERVICE
[Unit]
Description=ISUPipe Go Application
After=network.target mysql.service

[Service]
Type=simple
User=isucon
Group=isucon
WorkingDirectory=$WEBAPP_DIR
ExecStart=$WEBAPP_DIR/isupipe
Environment="ISUCON13_MYSQL_DIALCONFIG_NET=tcp"
Environment="ISUCON13_MYSQL_DIALCONFIG_ADDRESS=127.0.0.1"
Environment="ISUCON13_MYSQL_DIALCONFIG_PORT=3306"
Environment="ISUCON13_MYSQL_DIALCONFIG_USER=isucon"
Environment="ISUCON13_MYSQL_DIALCONFIG_PASSWORD=isucon"
Environment="ISUCON13_MYSQL_DIALCONFIG_DATABASE=isupipe"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable isupipe-go
systemctl start isupipe-go

# ============================================================
# Initialize data
# ============================================================

if [[ -f "$ISUCON_DIR/webapp/sql/init.sh" ]]; then
  cd "$ISUCON_DIR/webapp/sql"
  bash init.sh 2>/dev/null || true
fi

echo "=== Contest VM setup complete ==="
