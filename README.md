# ISUCON13 × Azure SRE Agent PoC

ISUCON13 過去問「ISUPIPE」を Azure VM 上に構築し、Azure SRE Agent が SSH MCP Server 経由でパフォーマンスチューニングを自律的に行えるかを検証する PoC 環境。

## アーキテクチャ

```
┌─ rg-isucon13-sreagent (Australia East) ──┐
│  SRE Agent ──► MCP Connector (ssh-mcp)   │
└───────────────────┬──────────────────────┘
                    │ HTTPS
┌─ rg-isucon13-system (Southeast Asia) ────┐
│  ACA (SSH MCP Server, API Key 認証)      │
│    │ SSH (Private IP)                    │
│  VNet 10.0.0.0/16                        │
│  ├─ vm1  10.0.1.4  contest              │
│  ├─ vm2  10.0.1.5  contest              │
│  ├─ vm3  10.0.1.6  contest              │
│  └─ bench 10.0.1.7 benchmarker          │
│  Key Vault, ACR, NAT GW                 │
└──────────────────────────────────────────┘
```

詳細は [docs/](docs/) を参照。

## デプロイ

```bash
az login
azd auth login
azd up                          # ~8分: インフラ + SSH MCP Server
bash scripts/setup-ssh-keys.sh  # ~3分: SSH 鍵生成 + VM 配布
bash scripts/post-provision.sh  # ~2分: SRE Agent 構成 (KB, Agents, MCP)
```

### パラメータ（すべてオプション）

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `AZURE_LOCATION` | `southeastasia` | VM/インフラ |
| `SRE_AGENT_LOCATION` | `australiaeast` | SRE Agent |
| `ENABLE_MONITORING` | `false` | Azure Monitor |
| `VM_SIZE_CONTEST` | `Standard_D2s_v5` | 競技 VM |
| `VM_SIZE_BENCH` | `Standard_D4s_v5` | ベンチ VM |

## クリーンアップ

```bash
azd down --purge
```

## ライセンス

MIT License。ISUCON13 ([isucon/isucon13](https://github.com/isucon/isucon13)) は MIT License (Copyright (c) 2023 ISUCON13 Contributors)。
