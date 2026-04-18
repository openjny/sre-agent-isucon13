# プロジェクト構成

```
.
├── azure.yaml                    # azd プロジェクト定義
├── infra/                        # Bicep テンプレート
│   ├── main.bicep                # エントリ (subscription scope, 2 RG)
│   ├── main.bicepparam           # azd env 変数 → Bicep パラメータ
│   ├── resources-system.bicep    # system RG のリソース統合
│   ├── resources-sreagent.bicep  # sreagent RG のリソース統合
│   └── modules/
│       ├── network.bicep         # VNet, NSG, NAT Gateway
│       ├── vm.bicep              # VM + Custom Script Extension
│       ├── aca.bicep             # ACA 環境 + ISUCON MCP Server コンテナ
│       ├── monitoring.bicep      # Azure Monitor (オプション)
│       ├── sre-agent.bicep       # SRE Agent (Microsoft.App/agents)
│       ├── ssh-keygen.bicep      # SSH 鍵生成 (deploymentScript → Key Vault)
│       └── cross-rg-rbac.bicep   # cross-RG RBAC
├── scripts/
│   ├── post-provision.sh            # azd hook entrypoint → post-configure-agent.sh
│   ├── post-configure-agent.sh      # SRE Agent 構成 (KB, MCP, Agents, Tools)
│   ├── provision-vm.sh              # Bicep CSE entrypoint: 共通セットアップ + dispatch
│   ├── provision-vm-contest.sh      # MySQL, nginx, PowerDNS, Go app
│   ├── provision-vm-benchmark.sh    # ベンチマーカービルド
│   └── yaml-to-api-json.py          # YAML → SRE Agent API JSON 変換
├── isucon-mcp-server/             # ISUCON MCP Server (Go)
│   ├── main.go                   # MCP プロトコル + SSH exec + ベンチマーク管理
│   ├── Dockerfile
│   ├── go.mod / go.sum
├── sre-config/                   # SRE Agent 構成ファイル
│   ├── agents/                   # Custom Agent 定義
│   │   ├── benchmark-runner.yaml
│   │   ├── code-optimizer.yaml
│   │   └── performance-investigator.yaml
│   └── knowledge-base/           # Knowledge Base ドキュメント
│       ├── isupipe-architecture.md
│       ├── isupipe-optimization-guide.md
│       ├── benchmark-runbook.md
│       └── server-topology.md
├── docs/                         # プロジェクトドキュメント
└── .vscode/mcp.json              # VS Code MCP Server 接続設定
```

## デプロイフロー

```
azd up
  ├─ Package: Docker build → ISUCON MCP Server イメージ
  ├─ Provision (Bicep):
  │   ├─ RG 2つ作成 (system + sreagent)
  │   ├─ VNet, NSG, NAT GW
  │   ├─ Key Vault + deployer RBAC + SSH 鍵 + TLS 証明書生成 (deploymentScript)
  │   ├─ ACR + ACA 環境 + ISUCON MCP Server (placeholder image)
  │   ├─ VM x4 (SystemAssigned MI + KV Secrets User RBAC)
  │   │   └─ Custom Script Extension → provision-vm.sh
  │   │       ├─ contest: KV から TLS cert/key 取得 → nginx 配置
  │   │       └─ bench: KV から TLS cert 取得 → CA trust store 追加
  │   └─ SRE Agent (Australia East)
  ├─ Deploy: ISUCON MCP Server イメージ → ACR → ACA 更新
  └─ Post-provision hook: post-provision.sh → post-configure-agent.sh
      ├─ KB アップロード (azuresre.ai トークン)
      ├─ MCP Connector 作成 (dataplane v2 API, Mcp + extendedProperties)
      ├─ Custom Agent 作成 (dataplane v2 API)
      └─ Experimental tools 有効化 (ARM API)
```

## 認証

| API | トークン resource | 用途 |
|-----|------------------|------|
| SRE Agent データプレーン | `https://azuresre.ai` | KB, Agents, Connectors |
| ARM コントロールプレーン | `https://management.azure.com` | リソース操作, experimental settings |
| ISUCON MCP Server | `Authorization: Bearer <API_KEY>` | exec/benchmark ツール呼び出し |
