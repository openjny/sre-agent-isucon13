# プロジェクト

Azure SRE Agent が SSH MCP Server 経由で ISUCON13 (ISUPIPE) のパフォーマンスチューニングを自律的に行う検証環境。

## 検証環境

- **rg-isucon13-system** (Southeast Asia): VNet, VM×4, ACA (SSH MCP Server), Key Vault, ACR, NAT GW
- **rg-isucon13-sreagent** (Australia East): SRE Agent リソース

SRE Agent → HTTPS → ACA (SSH MCP Server) → SSH → VM (private IP only)

詳細は [docs/structure.md](docs/structure.md) を参照。

## デプロイ / クリーンアップ

```bash
azd up          # インフラ + SSH MCP Server + SRE Agent 構成 (~10分)
azd down --purge
```

SRE Agent の再構成のみ:

```bash
bash scripts/post-configure-agent.sh
```

パラメータは [README.md](README.md) を参照。

## コンポーネント構成

| コンポーネント | ディレクトリ | 言語/技術 | 説明 |
|---|---|---|---|
| Infrastructure | `infra/` | Bicep | サブスクリプションスコープ、2 RG 構成 |
| SSH MCP Server | `ssh-mcp-server/` | Go 1.22 | HTTP MCP サーバー (POST /mcp, GET /health) |
| Agent 定義 | `sre-config/agents/` | YAML | カスタムエージェント (benchmark-runner, code-optimizer, performance-investigator) |
| Knowledge Base | `sre-config/knowledge-base/` | Markdown | エージェント向けナレッジ |
| Provisioning | `scripts/` | Bash, Python | VM セットアップ、SRE Agent 構成 |

## Azure SRE エージェントの重要な規約・注意点

docs/sre-agent-api.md も参照。

### API 認証の 2 つのレルム

- **Dataplane API** (`/api/v1/`, `/api/v2/`): `az account get-access-token --resource https://azuresre.ai`
- **ARM API** (コントロールプレーン): `az account get-access-token --resource https://management.azure.com`

間違えると 401 エラーになる。詳細は [docs/sre-agent-api.md](docs/sre-agent-api.md)。

### MCP Connector のフォーマット

- `dataConnectorType` は `"Mcp"` を使用（`"McpServer"` は silent fail）
- 接続情報は `extendedProperties.endpoint` + `extendedProperties.authType`
- MCP Server は `ping` メソッド（空レスポンス `{}`）を必ず実装すること

### Dataplane API で作成したリソースのポータル表示

Dataplane API で作成した KB、コネクタ、カスタムエージェントは sre.azure.com ポータルに表示されないが、正常に動作する。

### VM ホストエイリアス

SSH MCP Server の `HOST_MAP` 環境変数でエイリアス解決:

- `vm1` → 10.0.1.4, `vm2` → 10.0.1.5, `vm3` → 10.0.1.6, `bench` → 10.0.1.7

## SSH MCP Server の開発

- エントリポイント: [ssh-mcp-server/main.go](ssh-mcp-server/main.go)
- MCP メソッド: `initialize`, `ping`, `tools/list`, `tools/call` (exec)
- 認証: Bearer token or `X-API-Key` ヘッダー
- SSH 鍵は Azure Key Vault から取得

Dockerfile はマルチステージビルド。`azd deploy ssh-mcp-server` で ACA にデプロイ。

## Bicep インフラの開発

- サブスクリプションスコープ ([infra/main.bicep](infra/main.bicep)) から 2 つの RG モジュールを呼び出す構成
- VM の Custom Script Extension で `scripts/provision-vm.sh` を実行
- SSH 鍵は Deployment Script (`ssh-keygen.bicep`) で生成 → Key Vault 格納
