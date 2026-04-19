---
name: emergency-rollback
description: Emergency rollback procedures when changes break the ISUPIPE application or benchmark fails
---

# Emergency Rollback — ISUPIPE

When a change breaks the application and the benchmark fails or score drops significantly.

## Quick Diagnosis

```bash
# Check if the app is running
exec host="vm1" command="systemctl status isupipe-go --no-pager"

# Check app logs for errors
exec host="vm1" command="journalctl -u isupipe-go --no-pager -n 30 --since '5 minutes ago'"

# Check if nginx is running
exec host="vm1" command="sudo nginx -t && systemctl status nginx --no-pager"

# Check MySQL
exec host="vm1" command="systemctl status mysql --no-pager"
exec host="vm1" command="mysql -u isucon -pisucon -e 'SELECT 1'"
```

## Rollback: Go Application

If Go code changes broke the build or runtime:

```bash
# Revert Go source to original
exec host="vm1" command="cd /home/isucon/isucon13/webapp/go && git checkout -- ."

# Rebuild
exec host="vm1" command="cd /home/isucon/isucon13/webapp/go && go build -o isupipe ."

# Restart
exec host="vm1" command="sudo systemctl restart isupipe-go"
```

## Rollback: Database

If schema changes or data corruption occurred:

```bash
# Re-initialize the database (drops and recreates all tables)
exec host="vm1" command="cd /home/isucon/isucon13/webapp/sql && sudo -u isucon bash init.sh"
```

**Warning:** This resets all data AND removes any added indexes. Re-apply indexes after init.

## Rollback: nginx Configuration

```bash
# Check for syntax errors
exec host="vm1" command="sudo nginx -t"

# If broken, restore default config
exec host="vm1" command="cd /home/isucon/isucon13 && git checkout -- ../env/*/etc/nginx/"
exec host="vm1" command="sudo systemctl reload nginx"
```

## Rollback: MySQL Configuration

```bash
# Remove custom config
exec host="vm1" command="sudo rm -f /etc/mysql/mysql.conf.d/isucon.cnf"
exec host="vm1" command="sudo systemctl restart mysql"
```

## Rollback: Multi-Server Distribution

If multi-server setup is broken, return to single-server:

```bash
# Restore MySQL to vm1 only
exec host="vm2" command="sudo systemctl start mysql"
exec host="vm3" command="sudo systemctl start mysql"

# Point apps back to localhost
exec host="vm2" command="sudo sed -i 's|ISUCON13_MYSQL_DIALCONFIG_ADDRESS=.*|ISUCON13_MYSQL_DIALCONFIG_ADDRESS=127.0.0.1|' /home/isucon/env.sh && sudo systemctl restart isupipe-go"
exec host="vm3" command="sudo sed -i 's|ISUCON13_MYSQL_DIALCONFIG_ADDRESS=.*|ISUCON13_MYSQL_DIALCONFIG_ADDRESS=127.0.0.1|' /home/isucon/env.sh && sudo systemctl restart isupipe-go"

# Restart app on vm1
exec host="vm1" command="sudo systemctl start isupipe-go"
```

## Full Reset (Nuclear Option)

Re-initialize everything on all VMs:

```bash
for vm in vm1 vm2 vm3; do
    exec host="$vm" command="cd /home/isucon/isucon13/webapp/go && git checkout -- . && go build -o isupipe . && sudo systemctl restart isupipe-go"
    exec host="$vm" command="cd /home/isucon/isucon13/webapp/sql && sudo -u isucon bash init.sh"
    exec host="$vm" command="sudo systemctl restart nginx mysql pdns"
done
```

## Post-Rollback Verification

```bash
# Pretest to verify everything works
benchmark_start options="--pretest-only"
benchmark_status
```

If pretest passes, run a full benchmark to confirm score is back to expected level.
