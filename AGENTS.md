# プロジェクト

Azure SRE Agent が ISUCON MCP Server 経由で ISUCON13 (ISUPIPE) のパフォーマンスチューニングを自律的に行う検証環境。

アーキテクチャ詳細は [docs/architecture.md](docs/architecture.md) を参照。

## コンポーネント構成

| コンポーネント | ディレクトリ | 言語/技術 |
|---|---|---|
| Infrastructure | `infra/` | Bicep |
| ISUCON MCP Server | `isucon-mcp-server/` | Go 1.22 |
| Agent 定義 | `sre-config/agents/` | YAML |
| Provisioning | `scripts/` | Bash, Python |

## デプロイ

```bash
azd up          # インフラ + MCP Server + SRE Agent (~10分)
azd down --purge
```

## 開発時に知っておくべきこと

### SRE Agent API の認証

- **Dataplane** (`/api/v1/`, `/api/v2/`): `--resource https://azuresre.ai`
- **ARM**: `--resource https://management.azure.com`

間違えると 401。詳細は [docs/sre-agent-api.md](docs/sre-agent-api.md)。

### MCP Connector

- `dataConnectorType` は `"Mcp"`（`"McpServer"` は silent fail）
- `ping` メソッド必須（空 `{}` を返す）
- Dataplane API で作成したリソースはポータルに表示されないが動作する

### ISUCON MCP Server

- エントリポイント: [isucon-mcp-server/main.go](isucon-mcp-server/main.go)
- ツール: `exec`, `benchmark_start`, `benchmark_status`
- デプロイ: `azd deploy isucon-mcp-server`

### Bicep

- サブスクリプションスコープ、2 RG 構成
- SSH 鍵 + TLS 証明書は Deployment Script → Key Vault
- VM は SystemAssigned MI で KV から証明書取得
