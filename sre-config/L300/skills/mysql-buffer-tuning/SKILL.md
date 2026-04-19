---
name: mysql-buffer-tuning
description: Tune MySQL InnoDB buffer pool and query settings for ISUCON workloads
---

# MySQL Buffer Tuning — ISUPIPE

Tune MySQL server settings for the ISUCON workload (short benchmark, high concurrency).

## Key Settings

Create or update `/etc/mysql/mysql.conf.d/isucon.cnf`:

```ini
[mysqld]
# Buffer pool — use ~70% of available RAM
innodb_buffer_pool_size = 1G

# Flush behavior — prioritize speed over durability (ISUCON is not production)
innodb_flush_log_at_trx_commit = 0
innodb_flush_method = O_DIRECT

# Log file size — larger = fewer checkpoints
innodb_log_file_size = 256M

# Disable binary log (not needed for single-server ISUCON)
disable_log_bin

# Disable performance schema (saves ~200MB RAM)
performance_schema = OFF

# Connection limits
max_connections = 200
```

## How to Apply

```bash
exec host="vm1" command="sudo tee /etc/mysql/mysql.conf.d/isucon.cnf << 'EOF'
[mysqld]
innodb_buffer_pool_size = 1G
innodb_flush_log_at_trx_commit = 0
innodb_flush_method = O_DIRECT
innodb_log_file_size = 256M
disable_log_bin
performance_schema = OFF
max_connections = 200
EOF"
```

Then restart MySQL:
```bash
exec host="vm1" command="sudo systemctl restart mysql"
```

## Verify Settings

```bash
exec host="vm1" command="mysql -u isucon -pisucon -e \"
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';
SHOW VARIABLES LIKE 'max_connections';
SHOW VARIABLES LIKE 'performance_schema';
\""
```

## VM Memory Considerations

Contest VMs are Standard_D2s_v5 (8 GiB RAM). Budget:
- MySQL: ~4-5 GiB (buffer pool 1G + overhead)
- Go app: ~500 MB
- nginx: ~100 MB
- OS + PowerDNS: ~1 GiB
- Reserve: ~1-2 GiB

If using multi-server distribution, the DB-only VM can use `innodb_buffer_pool_size = 4G`.

## Expected Impact

- Buffer pool hit rate increases significantly
- Write latency drops with flush_at_trx_commit=0
- Typical improvement: +1,000-3,000 score
