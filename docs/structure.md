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
│   ├── srectl.py                    # SRE Agent CLI (kubectl 風)
│   ├── post-provision.sh            # azd hook entrypoint (srectl 呼び出し)
│   ├── provision-vm.sh              # Bicep CSE entrypoint: 共通セットアップ + dispatch
│   ├── provision-vm-contest.sh      # MySQL, nginx, PowerDNS, Go app
│   └── provision-vm-benchmark.sh    # ベンチマーカービルド
├── isucon-mcp-server/             # ISUCON MCP Server (Go)
│   ├── main.go                   # MCP プロトコル + SSH exec + ベンチマーク管理
│   ├── Dockerfile
│   ├── go.mod / go.sum
├── sre-config/                   # SRE Agent 構成ファイル (ティア別)
│   ├── base/                     # 全ティア共通
│   │   ├── memory/               # 共通メモリ (architecture, topology, runbook)
│   │   └── skills/
│   │       └── mcp-tools-guide/  # MCP ツール使い方
│   ├── L100/                     # 初参加者: 1 generalist agent
│   │   └── agents/
│   │       └── isucon.yaml
│   ├── L200/                     # 経験者: 4 agents + 3 skills
│   │   ├── agents/               # isucon (orchestrator) + specialists
│   │   └── skills/               # db-indexing, n-plus-one-fix, icon-caching
│   ├── L300/                     # 上級者: 4 agents + 5 skills
│   │   ├── agents/
│   │   └── skills/               # alp, slow-query, go-db, mysql-buffer, nginx
│   └── L400/                     # 猛者: 4 agents + 7 skills
│       ├── agents/
│       └── skills/               # multi-server, dns, lb, cache, strategy, patterns, rollback
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
  └─ Post-provision hook: post-provision.sh (srectl.py CLI 経由)
      ├─ メモリ追加 (srectl memory add)
      ├─ Skills デプロイ (srectl skill add, base + 累積 L{n}/skills/)
      ├─ Custom Agent 作成 (srectl agent apply, L{current}/agents/)
      ├─ ダウングレード cleanup (srectl skill/agent delete)
      └─ Experimental tools 有効化 (ARM API)
```

## 認証

| API | トークン resource | 用途 |
|-----|------------------|------|
| SRE Agent データプレーン | `https://azuresre.ai` | Memory, Agents, Connectors |
| ARM コントロールプレーン | `https://management.azure.com` | リソース操作, experimental settings |
| ISUCON MCP Server | `Authorization: Bearer <API_KEY>` | exec/benchmark ツール呼び出し |
