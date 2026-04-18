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
│       ├── aca.bicep             # ACA 環境 + SSH MCP Server コンテナ
│       ├── monitoring.bicep      # Azure Monitor (オプション)
│       ├── sre-agent.bicep       # SRE Agent (Microsoft.App/agents)
│       ├── ssh-keygen.bicep      # SSH 鍵生成 (deploymentScript, 未使用)
│       └── cross-rg-rbac.bicep   # cross-RG RBAC
├── scripts/
│   ├── bootstrap.sh              # VM CSE エントリ: 引数解析 → role 別実行
│   ├── setup-contest.sh          # MySQL, nginx, PowerDNS, Go app
│   ├── setup-bench.sh            # ベンチマーカービルド
│   ├── post-provision.sh         # SRE Agent 自動構成 (KB, Agents, MCP)
│   ├── setup-ssh-keys.sh         # SSH 鍵生成 + KV 格納 + VM 配布
│   └── yaml-to-api-json.py       # YAML → SRE Agent API JSON 変換
├── ssh-mcp-server/               # SSH MCP Server (Go)
│   ├── main.go                   # MCP プロトコル + SSH exec
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
  ├─ Package: Docker build → SSH MCP Server イメージ
  ├─ Provision (Bicep):
  │   ├─ RG 2つ作成 (system + sreagent)
  │   ├─ VNet, NSG, NAT GW
  │   ├─ Key Vault + deployer RBAC
  │   ├─ ACR + ACA 環境 + SSH MCP Server (placeholder image)
  │   ├─ VM x4 + Custom Script Extension (bootstrap.sh)
  │   │   └─ git clone → setup-contest.sh / setup-bench.sh
  │   └─ SRE Agent (Australia East)
  ├─ Deploy: SSH MCP Server イメージ → ACR → ACA 更新
  └─ Post-provision hook: (azd hook で自動実行されるが、
      SSH 鍵は別途手動実行が必要)

bash scripts/setup-ssh-keys.sh
  └─ SSH 鍵生成 → Key Vault 格納 → 全 VM に公開鍵配布

bash scripts/post-provision.sh
  ├─ KB アップロード (azuresre.ai トークン)
  ├─ Custom Agent 作成 (dataplane v2 API)
  ├─ MCP Connector 作成 (dataplane v2 API)
  └─ Experimental tools 有効化 (ARM API)
```

## 認証

| API | トークン resource | 用途 |
|-----|------------------|------|
| SRE Agent データプレーン | `https://azuresre.ai` | KB, Agents, Connectors |
| ARM コントロールプレーン | `https://management.azure.com` | リソース操作, experimental settings |
| SSH MCP Server | `Authorization: Bearer <API_KEY>` | exec ツール呼び出し |
