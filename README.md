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
# ISUCON13 × Azure SRE Agent PoC

ISUCON13 過去問「ISUPIPE」を Azure VM 上に構築し、Azure SRE Agent が SSH MCP Server 経由でパフォーマンスチューニングを自律的に行えるかを検証する PoC 環境。

## アーキテクチャ

```
┌─ rg-isucon13-sreagent (Australia East) ─┐
│  SRE Agent ──► MCP Connector            │
└──────────────────┬──────────────────────┘
                   │ HTTPS
┌─ rg-isucon13-system (Southeast Asia) ───┐
│  ACA (SSH MCP Server)                   │
│    │ SSH (Private IP)                   │
│  VNet 10.0.0.0/16                       │
│  ├─ vm1  10.0.1.4  contest (nginx/MySQL/PowerDNS/Go app)
│  ├─ vm2  10.0.1.5  contest
│  ├─ vm3  10.0.1.6  contest
│  └─ bench 10.0.1.7 benchmarker (D4s_v5)
│  Key Vault (SSH秘密鍵), ACR, NAT GW    │
└─────────────────────────────────────────┘
```

- 全 VM は Public IP なし（NAT GW 経由で outbound のみ）
- SSH 鍵ペアは Bicep deploymentScript で自動生成 → Key Vault に格納
- `ENABLE_MONITORING=true` で Azure Monitor (Log Analytics + AMA) を追加可能

## デプロイ

```bash
# 前提: Azure CLI, azd, Git がインストール済み
az login
azd auth login

azd up
```

### パラメータ（すべてオプション）

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `AZURE_LOCATION` | `southeastasia` | VM/インフラのリージョン |
| `SRE_AGENT_LOCATION` | `australiaeast` | SRE Agent のリージョン |
| `ENABLE_MONITORING` | `false` | Azure Monitor 有効化 |
| `VM_SIZE_CONTEST` | `Standard_D2s_v5` | 競技 VM サイズ |
| `VM_SIZE_BENCH` | `Standard_D4s_v5` | ベンチ VM サイズ |

```bash
# 例: モニタリング有効で Southeast Asia にデプロイ
azd env set ENABLE_MONITORING true
azd up
```

## VM への接続

```bash
# az vm run-command 経由
az vm run-command invoke -g rg-isucon13-system -n vm-isucon13-contest1 \
  --command-id RunShellScript --scripts "hostname"

# Key Vault から秘密鍵を取得して SSH
KV=$(az keyvault list -g rg-isucon13-system --query '[0].name' -o tsv)
az keyvault secret show --vault-name $KV --name ssh-private-key --query value -o tsv > /tmp/key
chmod 600 /tmp/key
# (Bastion や VPN 経由でアクセスする場合に使用)
```

## ベンチマーク実行

SRE Agent ポータル (https://sre.azure.com) から、または SSH MCP 経由で：

```
exec bench "sudo -u isucon /home/isucon/run-benchmark.sh"
```

## クリーンアップ

```bash
azd down --purge
```

## ライセンス

MIT License。詳細は [LICENSE](LICENSE) を参照。

ISUCON13 の問題・参考実装 (https://github.com/isucon/isucon13) は MIT License (Copyright (c) 2023 ISUCON13 Contributors) で提供されています。
