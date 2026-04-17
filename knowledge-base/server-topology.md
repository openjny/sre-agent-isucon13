# Server Topology

## VMs

| Alias | Role | Private IP | VM Size | Services |
|-------|------|------------|---------|----------|
| vm1 | Contest Server 1 | 10.0.1.4 | Standard_D2s_v5 (2vCPU/8GiB) | nginx, MySQL, PowerDNS, isupipe-go |
| vm2 | Contest Server 2 | 10.0.1.5 | Standard_D2s_v5 (2vCPU/8GiB) | nginx, MySQL, PowerDNS, isupipe-go |
| vm3 | Contest Server 3 | 10.0.1.6 | Standard_D2s_v5 (2vCPU/8GiB) | nginx, MySQL, PowerDNS, isupipe-go |
| bench | Benchmark Server | 10.0.1.7 | Standard_D4s_v5 (4vCPU/16GiB) | benchmarker |

## Network
- VNet: 10.0.0.0/16
- VM Subnet: 10.0.1.0/24
- No public IPs — all communication via private network
- NAT Gateway for outbound internet access (package installs)
- DNS zone `u.isucon.dev` served by PowerDNS on contest VMs

## SSH Access
- User: `isucon`
- All VMs accessible via SSH MCP Server exec tool
- Commands: `exec vm1 "command"`, `exec bench "command"`

## Service Management
- Start/stop services: `systemctl start|stop|restart <service>`
- Services: `isupipe-go`, `nginx`, `mysql`, `pdns`
- Logs: `journalctl -u <service> --no-pager -n 50`

## Initial State (after bootstrap)
- Each contest VM runs all components independently
- All VMs have identical configuration
- PowerDNS on each VM resolves `*.u.isucon.dev` to all 3 contest VM IPs
- Benchmark targets vm1 as nameserver, vm2/vm3 as additional webapp targets
