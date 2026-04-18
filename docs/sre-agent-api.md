# Azure SRE Agent API リファレンス

このプロジェクトで使用している SRE Agent API の操作方法をまとめる。

## 認証

SRE Agent は **2 種類のトークン** を使い分ける。

| API | resource / audience | 用途 |
|-----|---------------------|------|
| データプレーン | `https://azuresre.ai` | KB, Custom Agents, Connectors, Chat |
| ARM コントロールプレーン | `https://management.azure.com` | リソース操作, experimental settings |

```bash
# データプレーン
TOKEN=$(az account get-access-token --resource https://azuresre.ai --query accessToken -o tsv)

# ARM
az rest --method PATCH --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=2025-05-01-preview" --body '...'
```

> **Note**: 他のリポジトリでは `https://azuresre.dev` を使用している例があるが、これは Microsoft 内部の開発環境用 audience。外部向けは `https://azuresre.ai` を使う。どちらもアプリ ID `59f0a04a-b322-4310-adc9-39ac41e9631e` にマッピングされる。

### データプレーン API とポータル表示の関係

データプレーン API で作成したリソースはエージェントから利用可能だが、ポータル (sre.azure.com) の一部画面には表示されない。ポータルは ARM コントロールプレーンの情報を参照しているため。

| リソース | データプレーン API | ポータル表示 | エージェント利用 |
|---|---|---|---|
| Connectors | ✓ 作成可 | ✗ Connectors 一覧に非表示 | ✓ MCP ツール利用可 |
| Knowledge Base | ✓ アップロード可 | ✗ Knowledge sources に非表示 | ✓ チャットで検索可 |
| Custom Agents | ✓ 作成可 | ✓ Agent Canvas に表示 | ✓ `/agent` で呼出可 |

自動化 (post-provision) ではデータプレーン API のみで十分。ポータル表示が必要な場合は ARM API も併用する。

## エンドポイント取得

```bash
RG="rg-isucon13-sreagent"
AGENT_NAME=$(az resource list -g "$RG" --resource-type "Microsoft.App/agents" --query "[0].name" -o tsv)
AGENT_ENDPOINT=$(az resource show -g "$RG" -n "$AGENT_NAME" \
  --resource-type "Microsoft.App/agents" --api-version 2025-05-01-preview \
  --query "properties.agentEndpoint" -o tsv)
```

## データプレーン API

### Knowledge Base

```bash
# アップロード
curl -X POST "$AGENT_ENDPOINT/api/v1/AgentMemory/upload" \
  -H "Authorization: Bearer $TOKEN" \
  -F "triggerIndexing=true" \
  -F "files=@file1.md;type=text/plain" \
  -F "files=@file2.md;type=text/plain"

# ファイル一覧
curl "$AGENT_ENDPOINT/api/v1/AgentMemory/files" \
  -H "Authorization: Bearer $TOKEN"
```

### Custom Agents

```bash
# 作成・更新 (PUT)
curl -X PUT "$AGENT_ENDPOINT/api/v2/extendedAgent/agents/{agent-name}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "agent-name",
    "type": "ExtendedAgent",
    "tags": [],
    "owner": "",
    "properties": {
      "instructions": "system prompt here",
      "handoffDescription": "when to use this agent",
      "handoffs": [],
      "tools": ["azure_cli"],
      "mcpTools": ["isucon-mcp/*"],
      "allowParallelToolCalls": true,
      "enableSkills": true
    }
  }'

# 個別取得 (GET)
curl "$AGENT_ENDPOINT/api/v2/extendedAgent/agents/{agent-name}" \
  -H "Authorization: Bearer $TOKEN"

# 一覧 (GET)
curl "$AGENT_ENDPOINT/api/v2/extendedAgent/agents" \
  -H "Authorization: Bearer $TOKEN"
```

HTTP 202 は非同期処理の受理（成功）。

### Connectors

```bash
# 一覧 (GET)
curl "$AGENT_ENDPOINT/api/v2/extendedAgent/connectors" \
  -H "Authorization: Bearer $TOKEN"

# 個別取得 (GET)
curl "$AGENT_ENDPOINT/api/v2/extendedAgent/connectors/{connector-name}" \
  -H "Authorization: Bearer $TOKEN"
```

> **Note**: データプレーン API で作成したコネクタはポータルの Connectors 一覧には表示されないが、エージェントからは利用可能。ポータル表示が必要な場合は ARM API (`DataConnectors`) も併用する。

#### MCP Server コネクタ

```bash
# dataConnectorType は "Mcp" を使う（"McpServer" ではない）
# URL は extendedProperties.endpoint に設定する
curl -X PUT "$AGENT_ENDPOINT/api/v2/extendedAgent/connectors/{connector-name}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "isucon-mcp",
    "type": "AgentConnector",
    "properties": {
      "dataConnectorType": "Mcp",
      "dataSource": "placeholder",
      "identity": "",
      "extendedProperties": {
        "type": "http",
        "endpoint": "https://your-mcp-server.azurecontainerapps.io/mcp",
        "authType": "BearerToken",
        "bearerToken": "YOUR_API_KEY"
      }
    }
  }'
```

> **注意**: `dataConnectorType: "McpServer"` + `url`/`headers` 形式は API が受理するが接続情報が保存されない（`endpoint: null`）。必ず `Mcp` + `extendedProperties` を使うこと。
>
> MCP サーバーは `ping` メソッド（空レスポンス `{}` を返す）を実装する必要がある。未実装だとポータルで Disconnected と表示される。

#### GitHub OAuth コネクタ

```bash
curl -X PUT "$AGENT_ENDPOINT/api/v2/extendedAgent/connectors/github" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "github",
    "type": "AgentConnector",
    "properties": {
      "dataConnectorType": "GitHubOAuth",
      "dataSource": "github-oauth"
    }
  }'
```

GitHub OAuth は ARM 側にも作成が必要（OAuth フロー用）:

```bash
az rest --method PUT \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/github?api-version=2025-05-01-preview" \
  --body '{"properties":{"dataConnectorType":"GitHubOAuth","dataSource":"github-oauth"}}'
```

#### その他のコネクタタイプ

| `dataConnectorType` | 用途 | ポータル認可 |
|---------------------|------|-------------|
| `Mcp` | MCP サーバー接続 (`extendedProperties` で URL/認証設定) | 不要 |
| `StreamableHttp` | Streamable HTTP MCP (GitHub MCP 等、`serverUri`/`credentials` で設定) | 不要 |
| `GitHubOAuth` | GitHub OAuth (コード検索・Issue 作成) | 必要 |
| `AzureMonitor` | Azure Monitor インシデント | 不要 |
| `Outlook` | メール送信 (SendOutlookEmail ツール) | 必要 |

### Response Plans (インシデント対応)

```bash
# 作成・更新 (PUT)
curl -X PUT "$AGENT_ENDPOINT/api/v1/incidentPlayground/filters/{plan-id}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "id": "plan-id",
    "name": "Plan Name",
    "priorities": ["Sev0","Sev1","Sev2","Sev3"],
    "titleContains": "",
    "handlingAgent": "agent-name",
    "agentMode": "autonomous",
    "maxAttempts": 3
  }'

# 一覧 (GET)
curl "$AGENT_ENDPOINT/api/v1/incidentPlayground/filters" \
  -H "Authorization: Bearer $TOKEN"

# 削除 (DELETE)
curl -X DELETE "$AGENT_ENDPOINT/api/v1/incidentPlayground/filters/{plan-id}" \
  -H "Authorization: Bearer $TOKEN"

# インシデントプラットフォーム種別の確認
curl "$AGENT_ENDPOINT/api/v1/incidentPlayground/incidentPlatformType" \
  -H "Authorization: Bearer $TOKEN"
```

> **Note**: `api/v2/extendedAgent/incidentFilters` (GET) でも一覧取得できるが read-only。作成は v1 API を使う。

### Scheduled Tasks

```bash
# 作成 (POST) — v1 API
curl -X POST "$AGENT_ENDPOINT/api/v1/scheduledtasks" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "task-name",
    "description": "Task description",
    "cronExpression": "0 */12 * * *",
    "agentPrompt": "Do something...",
    "agent": "agent-name"
  }'

# 一覧 (GET)
curl "$AGENT_ENDPOINT/api/v1/scheduledtasks" \
  -H "Authorization: Bearer $TOKEN"

# 削除 (DELETE)
curl -X DELETE "$AGENT_ENDPOINT/api/v1/scheduledtasks/{task-id}" \
  -H "Authorization: Bearer $TOKEN"
```

v2 API でも作成可能:

```bash
# 作成・更新 (PUT) — v2 API
curl -X PUT "$AGENT_ENDPOINT/api/v2/extendedAgent/scheduledTasks/{task-name}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "task-name",
    "type": "ScheduledTask",
    "properties": {
      "cronExpression": "0 8 * * *",
      "agentPrompt": "Run health check",
      "agentName": "agent-name",
      "enabled": true
    }
  }'
```

### GitHub リポジトリ連携

```bash
# GitHub OAuth URL の取得
curl "$AGENT_ENDPOINT/api/v1/github/config" \
  -H "Authorization: Bearer $TOKEN"
# => {"oAuthUrl": "https://..."} — ブラウザで開いて認可

# コードリポジトリの追加 (OAuth 認可後)
curl -X PUT "$AGENT_ENDPOINT/api/v2/repos/{repo-name}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "repo-name",
    "type": "CodeRepo",
    "properties": {
      "url": "https://github.com/owner/repo",
      "authConnectorName": "github"
    }
  }'
```

## ARM API

### Experimental Settings 有効化

```bash
az rest --method PATCH \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=2025-05-01-preview" \
  --body '{"properties":{"experimentalSettings":{"EnableWorkspaceTools":true,"EnableDevOpsTools":true,"EnablePythonTools":true}}}'
```

### Azure Monitor インシデントプラットフォーム有効化

```bash
az rest --method PATCH \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=2025-05-01-preview" \
  --body '{"properties":{"incidentManagementConfiguration":{"type":"AzMonitor","connectionName":"azmonitor"}}}'
```

### Connectors 一覧 (ARM)

```bash
az rest --method GET \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors?api-version=2025-05-01-preview"
```

## Bicep リソース定義

```bicep
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    knowledgeGraphConfiguration: {
      managedResources: [resourceGroupId]
      identity: identityId
    }
    actionConfiguration: {
      mode: 'autonomous'  // or 'Review'
      identity: identityId
      accessLevel: 'Low'
    }
    mcpServers: []
  }
}
```

## 参考リソース

### 公式

- [microsoft/sre-agent](https://github.com/microsoft/sre-agent) — 公式サンプル・ラボ
  - [labs/starter-lab](https://github.com/microsoft/sre-agent/tree/main/labs/starter-lab) — 本プロジェクトの参考元。post-provision.sh の API 呼び出しパターン
  - [labs/vm-cosmosdb](https://github.com/microsoft/sre-agent/tree/main/labs/vm-cosmosdb) — VM + CosmosDB のラボ
  - [samples/deployment-compliance](https://github.com/microsoft/sre-agent/tree/main/samples/deployment-compliance) — Kusto MCP の例
  - [samples/hands-on-lab](https://github.com/microsoft/sre-agent/tree/main/samples/hands-on-lab) — Grubify ハンズオンラボ
- [SRE Agent ドキュメント](https://learn.microsoft.com/en-us/azure/sre-agent/) — 公式 docs
  - [Overview](https://learn.microsoft.com/en-us/azure/sre-agent/overview)
  - [Custom Agents](https://learn.microsoft.com/en-us/azure/sre-agent/sub-agents)
  - [Connectors](https://learn.microsoft.com/en-us/azure/sre-agent/connectors)
  - [MCP Connector 設定](https://learn.microsoft.com/en-us/azure/sre-agent/mcp-connector)
  - [Deep Context](https://learn.microsoft.com/en-us/azure/sre-agent/workspace-tools)
  - [Agent Hooks](https://learn.microsoft.com/en-us/azure/sre-agent/agent-hooks)
- [SRE Agent ポータル](https://sre.azure.com)

### コミュニティ

- [matthansen0/azure-sre-agent-sandbox](https://github.com/matthansen0/azure-sre-agent-sandbox) — AKS + SRE Agent デモ環境 (PowerShell)。最も API を網羅的に使用。v2 Scheduled Tasks、Outlook/Azure Monitor コネクタ、Incident Filters read-only API の実例あり
- [gderossilive/AzSreAgentLab](https://github.com/gderossilive/AzSreAgentLab) — 複数デモシナリオ集 (Grubify, Grocery, Proactive Reliability)。Grafana MCP Proxy (Managed Identity + Streamable HTTP) の実装例
- [yortch/agentic-devops-demo](https://github.com/yortch/agentic-devops-demo) — Three Rivers Bank デモ。Chaos Engineering 13 シナリオ + Copilot Coding Agent 自動修正。jq のみで YAML→JSON 変換 (Python 不要)、GitHub OAuth フロー全体の自動化
- [msbrettorg/azcapman](https://github.com/msbrettorg/azcapman) — Capacity Management Plugin。`srectl` CLI のスキル定義と詳細な YAML スキーマリファレンス (`azuresre.ai/v2`)
