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
    "properties": {
      "instructions": "system prompt here",
      "handoffDescription": "when to use this agent",
      "tools": ["azure_cli"],
      "mcpTools": ["ssh-mcp/*"],
      "enableSkills": true
    }
  }'

# 一覧
curl "$AGENT_ENDPOINT/api/v2/extendedAgent/agents" \
  -H "Authorization: Bearer $TOKEN"
```

HTTP 202 は非同期処理の受理（成功）。

### MCP Connectors

```bash
# 作成 (PUT)
curl -X PUT "$AGENT_ENDPOINT/api/v2/extendedAgent/connectors/{connector-name}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "ssh-mcp",
    "type": "AgentConnector",
    "properties": {
      "dataConnectorType": "McpServer",
      "dataSource": "ssh-mcp",
      "url": "https://your-mcp-server.azurecontainerapps.io/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_API_KEY"
      }
    }
  }'
```

注意: ARM API の `DataConnectors` ではなく、データプレーン v2 API を使う。

### GitHub OAuth Connector

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

### Response Plans (インシデント対応)

```bash
curl -X PUT "$AGENT_ENDPOINT/api/v1/incidentPlayground/filters/{plan-id}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "id": "plan-id",
    "name": "Plan Name",
    "priorities": ["Sev0","Sev1","Sev2","Sev3"],
    "handlingAgent": "agent-name",
    "agentMode": "autonomous",
    "maxAttempts": 3
  }'
```

### Scheduled Tasks

```bash
curl -X POST "$AGENT_ENDPOINT/api/v1/scheduledtasks" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "task-name",
    "cronExpression": "0 */12 * * *",
    "agentPrompt": "Do something...",
    "agent": "agent-name"
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

- [microsoft/sre-agent](https://github.com/microsoft/sre-agent) — 公式サンプル・ラボ
  - [labs/starter-lab](https://github.com/microsoft/sre-agent/tree/main/labs/starter-lab) — 本プロジェクトの参考元。post-provision.sh の API 呼び出しパターン
  - [labs/vm-cosmosdb](https://github.com/microsoft/sre-agent/tree/main/labs/vm-cosmosdb) — VM + CosmosDB のラボ
  - [samples/deployment-compliance](https://github.com/microsoft/sre-agent/tree/main/samples/deployment-compliance) — Kusto MCP の例
- [SRE Agent ドキュメント](https://learn.microsoft.com/en-us/azure/sre-agent/) — 公式 docs
  - [Overview](https://learn.microsoft.com/en-us/azure/sre-agent/overview)
  - [Custom Agents](https://learn.microsoft.com/en-us/azure/sre-agent/sub-agents)
  - [Connectors](https://learn.microsoft.com/en-us/azure/sre-agent/connectors)
  - [MCP Connector 設定](https://learn.microsoft.com/en-us/azure/sre-agent/mcp-connector)
  - [Deep Context](https://learn.microsoft.com/en-us/azure/sre-agent/workspace-tools)
- [SRE Agent ポータル](https://sre.azure.com)
