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
| Provisioning | `scripts/` | Bash, Python |

## デプロイ

```bash
azd up          # インフラ + MCP Server + SRE Agent (~10分)
azd down --purge
```

## エージェントティア (AGENT_TIER)

SRE Agent の構成を4段階で制御。ティアは ISUCON 参加経験のレベルを模擬しており、スキルによって保有する知識の差を表現する。

### 設計方針

- **base skills**: 当日コンテスト参加者全員に渡される情報のみ（isupipe マニュアル、当日マニュアル、MCP ツールガイド）
- **L100**: ISUCON 初参加者。base skills + 汎用エージェント 1 体。事前知識なし。
- **L200**: ISUCON 経験者（初級）。過去の ISUCON で学んだ一般的なチューニング手法（DB インデックス、N+1 解消、キャッシュ戦略）を知っている。
- **L300**: ISUCON 経験者（中級）。プロファイリングツール (alp, pt-query-digest) やミドルウェアチューニング (MySQL, nginx, Go DB) の知見を持つ。
- **L400**: ISUCON 上級者。マルチサーバー分散、DNS 最適化、負荷分散、競技戦略など高度な知識を持つ。

**重要**: L200 以降のスキルは「一般的な ISUCON の傾向・手法」であり、**ISUCON13 (ISUPIPE) 固有の情報**（スキーマ詳細、具体的なボトルネック、ベンチマーカー内部動作、スコア値等）を含んではならない。エージェントは自ら調査してこれらを発見する必要がある。

```bash
# セットアップ（スキル・エージェント・コネクタの作成）
bash scripts/sreagent-setup.sh L200

# エージェントをキック（トリガー作成 + 実行 + ウォッチ）
bash scripts/sreagent-run.sh --watch

# キックのみ（ウォッチなし）
bash scripts/sreagent-run.sh

# 既に実行中のエージェントをウォッチ
bash scripts/sreagent-run.sh --watch

# 全構成を削除してやり直す場合
bash scripts/sreagent-clear.sh
bash scripts/sreagent-setup.sh L100
bash scripts/sreagent-run.sh --watch
```

個別リソースの操作には `srectl` CLI を使用:

```bash
scripts/srectl context                                    # 接続確認
scripts/srectl agent list                                 # エージェント一覧
scripts/srectl agent apply -f sre-config/L100/agents/isucon.yaml  # エージェント作成
scripts/srectl skill add --dir sre-config/base/skills/isucon-mcp-guide  # スキル作成
scripts/srectl tool list                                  # 利用可能ツール一覧
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
