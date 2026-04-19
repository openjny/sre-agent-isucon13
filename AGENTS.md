# プロジェクト

Azure SRE Agent が ISUCON MCP Server 経由で ISUCON13 (ISUPIPE) のパフォーマンスチューニングを自律的に行う検証環境。

アーキテクチャ詳細は [docs/architecture.md](docs/architecture.md) を参照。

## コンポーネント構成

| コンポーネント | ディレクトリ | 言語/技術 |
|---|---|---|
| Infrastructure | `infra/` | Bicep |
| ISUCON MCP Server | `isucon-mcp-server/` | Go 1.22 |
| Agent 定義 | `sre-config/{L100..L400}/agents/` | YAML |
| Skills 定義 | `sre-config/{base,L200..L400}/skills/` | Markdown (SKILL.md) |
| Agent Memory | `sre-config/base/memory/` | Markdown |
| Provisioning | `scripts/` | Bash, Python |

## デプロイ

```bash
azd up          # インフラ + MCP Server + SRE Agent (~10分)
azd down --purge
```

## エージェントティア (AGENT_TIER)

SRE Agent の構成を4段階で制御できる。

```bash
# セットアップ（トリガー作成 + キックまで自動実行）
bash scripts/sreagent-setup.sh L200

# 全構成を削除してやり直す場合
bash scripts/sreagent-clear.sh
bash scripts/sreagent-setup.sh L100

# エージェントの動向をウォッチ
bash scripts/watch-sreagent.sh
```

個別リソースの操作には `srectl` CLI を使用:

```bash
uv run --project srectl srectl context                                    # 接続確認
uv run --project srectl srectl agent list                                 # エージェント一覧
uv run --project srectl srectl agent apply -f sre-config/L100/agents/isucon.yaml  # エージェント作成
uv run --project srectl srectl skill add --dir sre-config/base/skills/isucon-mcp-guide  # スキル作成
uv run --project srectl srectl memory add sre-config/base/memory/*.md               # メモリ追加
uv run --project srectl srectl tool list                                  # 利用可能ツール一覧
```

| Tier | Agents | Skills (累積) | 概要 |
|------|--------|--------------|------|
| L100 | 1 (isucon) | 1 | 初参加者: 汎用エージェント + MCP ツールガイドのみ |
| L200 | 4 | 4 | 経験者: オーケストレーター + 専門3体 + DB index/N+1/icon caching |
| L300 | 4 | 9 | 上級者: + alp/slow query/Go DB/MySQL buffer/nginx tuning |
| L400 | 4 | 16 | 猛者: + multi-server/DNS/LB/cache/strategy/patterns/rollback |

デフォルトは `L100`。冪等で、ダウングレード時は上位ティアのリソースを自動削除。

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
