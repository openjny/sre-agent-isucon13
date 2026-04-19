# Azure SRE Agent API リファレンス

このプロジェクトで使用している SRE Agent API の操作方法をまとめる。

## 認証

SRE Agent は **2 種類のトークン** を使い分ける。

| API | resource / audience | 用途 |
|-----|---------------------|------|
| データプレーン | `https://azuresre.ai` | Memory, Custom Agents, Connectors, Skills, Hooks, Triggers (作成/一覧/削除) |
| ARM コントロールプレーン | `https://management.azure.com` | リソース操作, experimental settings, **HTTP Trigger 実行**, Thread メッセージ取得 |

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

### Agent Memory (v1)

エージェントのインデックスにドキュメントを直接追加する v1 API。
v2 では Knowledge Sources (connectors) に統合されたが、v1 の方が確実にインデックスされる。

```bash
# アップロード (multipart)
curl -X POST "$AGENT_ENDPOINT/api/v1/AgentMemory/upload" \
  -H "Authorization: Bearer $TOKEN" \
  -F "triggerIndexing=true" \
  -F "files=@file1.md;type=text/plain" \
  -F "files=@file2.md;type=text/plain"

# ファイル一覧（インデックス状態付き）
curl "$AGENT_ENDPOINT/api/v1/AgentMemory/files" \
  -H "Authorization: Bearer $TOKEN"
```

レスポンス例:

```json
{
  "files": [
    {"name": "runbook.md", "isIndexed": true, "errorReason": null},
    {"name": "knowledge_my-file.bin", "isIndexed": false, "errorReason": "File could not be indexed..."}
  ],
  "continuationToken": ""
}
```

> **Note**: この API は Agent Memory upload で追加したファイルだけでなく、Knowledge Sources (v2 connectors) で追加されたファイルも `knowledge_` prefix 付きで統合表示する。`isIndexed` はインデクシング完了状態を示し、Knowledge File/WebPage のインデクシング状態を確認できる唯一のエンドポイント。
>
> **既知の問題と対処**: Knowledge File API で `fileName` と `contentType` を extendedProperties に指定しないと、ファイルが `.bin` 拡張子で保存されインデクサーが解釈できずエラーになる。`srectl knowledge file add` では自動的にファイル名から `contentType` を推定して付与する。

### Memory vs Knowledge の関係

| 概念 | API バージョン | エンドポイント | 用途 |
|------|-------------|--------------|------|
| **Memory** | v1 | `POST /api/v1/AgentMemory/upload` | ファイルを直接インデックスに追加（確実） |
| **Knowledge File** | v2 | `PUT /api/v2/extendedAgent/connectors/{name}` (KnowledgeFile) | ファイルをコネクタとして管理 |
| **Knowledge WebPage** | v2 | `PUT /api/v2/extendedAgent/connectors/{name}` (KnowledgeWebPage) | Web ページをクロール・インデックス |
| **Knowledge Repo** | v2 | `PUT /api/v2/repos/{name}` | GitHub リポジトリのコード・ドキュメント |

v2 では全外部リソースが「コネクタ」として統一管理される設計。v1 AgentMemory はレガシーだが、ファイルのインデクシングにおいては最も信頼性が高い。

`GET /api/v1/AgentMemory/files` は全ソースの統合ビュー:

| `name` のパターン | ソース |
|-------------------|--------|
| `filename.md` | v1 AgentMemory upload |
| `knowledge_xxx.bin` | v2 Knowledge File connector |
| `knowledge_xxx.html` | v2 Knowledge WebPage connector |

### Knowledge Sources (v2)

ユーザーが登録するナレッジソース。ファイル・Webページ・GitHub リポジトリの3種類。
Agent Memory（エージェントが会話から自動学習する知見）とは別概念。

#### Knowledge File

```bash
# ファイル追加 (PUT) — connectors API 経由、Base64 エンコードで送信
curl -X PUT "$AGENT_ENDPOINT/api/v2/extendedAgent/connectors/{name}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-runbook",
    "type": "KnowledgeItem",
    "properties": {
      "dataConnectorType": "KnowledgeFile",
      "dataSource": "my-runbook",
      "extendedProperties": {
        "displayName": "My Runbook",
        "fileContent": "<base64-encoded-content>"
      }
    }
  }'

# 取得
curl "$AGENT_ENDPOINT/api/v2/extendedAgent/connectors/{name}" \
  -H "Authorization: Bearer $TOKEN"

# 削除
curl -X DELETE "$AGENT_ENDPOINT/api/v2/extendedAgent/connectors/{name}" \
  -H "Authorization: Bearer $TOKEN"
```

#### Knowledge Web Page

```bash
curl -X PUT "$AGENT_ENDPOINT/api/v2/extendedAgent/connectors/{name}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-docs",
    "type": "KnowledgeItem",
    "properties": {
      "dataConnectorType": "KnowledgeWebPage",
      "dataSource": "my-docs",
      "extendedProperties": {
        "url": "https://example.com/docs",
        "displayName": "My Docs",
        "description": "External documentation page"
      }
    }
  }'
```

#### Knowledge GitHub Repository

GitHub リポジトリのコード・ドキュメントをナレッジとして登録。事前に PAT の設定が必要。

```bash
# 1. GitHub PAT 登録
curl -X POST "$AGENT_ENDPOINT/api/v1/github/auth/pat" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "pat=github_pat_xxxxx"

# 2. リポジトリ一覧取得 (optional)
curl "$AGENT_ENDPOINT/api/v1/github/repos" \
  -H "Authorization: Bearer $TOKEN"

# 3. リポジトリ追加
curl -X PUT "$AGENT_ENDPOINT/api/v2/repos/{repo-name}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "repo-name",
    "type": "CodeRepo",
    "properties": {
      "url": "https://github.com/owner/repo",
      "type": "GitHub",
      "description": "Repository description"
    }
  }'

# 4. 登録リポジトリ一覧 (sync 状態確認)
curl "$AGENT_ENDPOINT/api/v2/repos" \
  -H "Authorization: Bearer $TOKEN"

# 5. リポジトリ削除
curl -X DELETE "$AGENT_ENDPOINT/api/v2/repos/{repo-name}" \
  -H "Authorization: Bearer $TOKEN"

# 6. PAT 削除
curl -X DELETE "$AGENT_ENDPOINT/api/v1/github/auth" \
  -H "Authorization: Bearer $TOKEN"
```

> **Note**: Knowledge Sources はバックエンドで AI Search 相当のインデクシングが行われる。追加後に同期完了までラグがある。`GET /api/v2/repos` で sync 状態を確認可能。

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

### Skills

```bash
# 作成・更新 (PUT)
curl -X PUT "$AGENT_ENDPOINT/api/v2/extendedAgent/skills/{skill-name}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "skill-name",
    "type": "Skill",
    "properties": {
      "description": "When to use this skill",
      "tools": [],
      "skillContent": "---\nname: skill-name\ndescription: When to use this skill\n---\n\n# Skill Instructions\n\nStep-by-step guidance here...",
      "additionalFiles": [
        {"filePath": "/references/guide.md", "content": "Reference content here"}
      ]
    }
  }'

# 一覧 (GET)
curl "$AGENT_ENDPOINT/api/v2/extendedAgent/skills" \
  -H "Authorization: Bearer $TOKEN"

# 個別取得 (GET)
curl "$AGENT_ENDPOINT/api/v2/extendedAgent/skills/{skill-name}" \
  -H "Authorization: Bearer $TOKEN"

# 削除 (DELETE)
curl -X DELETE "$AGENT_ENDPOINT/api/v2/extendedAgent/skills/{skill-name}" \
  -H "Authorization: Bearer $TOKEN"
```

> **Note**: `skillContent` は YAML frontmatter 付き Markdown。frontmatter に `name`, `description`, `tools` を記載する。`additionalFiles` で参照ドキュメントを添付可能（`SKILL.md` から相対パスでリンク）。
>
> エージェントに skill を紐付けるには、エージェント定義の `allowedSkills` に skill 名を列挙する。`enableSkills: true` も必要。

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

### Tools 一覧

エージェントが利用可能な全ツール（組み込み + MCP + カスタム）を取得する。

```bash
# ツール一覧 (GET)
curl "$AGENT_ENDPOINT/api/v2/agent/tools" \
  -H "Authorization: Bearer $TOKEN"
```

レスポンス構造:

```json
{
  "data": [
    {
      "name": "RunAzCliReadCommands",
      "source": "system",
      "mcpConnector": null,
      "mcpConnectorDisplayName": null,
      "defaultMode": "enabled",
      "enabled": true,
      "category": "Azure Operation",
      "schema": { ... },
      "description": "Executes read-only Azure CLI commands..."
    },
    {
      "name": "ssh-mcp_exec",
      "source": "mcp",
      "mcpConnector": "ssh-mcp",
      "mcpConnectorDisplayName": "SSH MCP",
      "defaultMode": "disabled",
      "enabled": false,
      "category": null,
      "schema": { ... },
      "description": "Execute a shell command on a remote host..."
    }
  ]
}
```

| フィールド | 説明 |
|-----------|------|
| `name` | ツール名。MCP ツールは `{connector}_{tool}` 形式 |
| `source` | `system` (組み込み) または `mcp` (MCP コネクタ経由) |
| `mcpConnector` | MCP ツールの場合、コネクタ名 |
| `defaultMode` | `always` (常時有効), `enabled` (有効), `disabled` (無効) |
| `enabled` | 現在の有効/無効状態 |
| `category` | カテゴリ分類 (下記参照) |
| `schema` | JSON Schema (パラメータ定義) |

カテゴリ一覧 (2025-05 時点):

| カテゴリ | ツール数 | 主なツール |
|---------|---------|-----------|
| Azure Operation | 2 | RunAzCliReadCommands, RunAzCliWriteCommands |
| DevOps | 18 | CreateGithubIssue, FetchGithubIssues, etc. |
| Knowledge Base | 4 | SearchMemory, SearchIncidentKnowledge, UploadKnowledgeDocument |
| Log Query | 4 | QueryAppInsightsByAppId, QueryLogAnalyticsByWorkspaceId, etc. |
| System | 1 | AskUserQuestion |
| Utility | 2 | ExecutePythonCode, UploadFileToSession |
| Visualization | 5 | PlotBarChart, PlotHeatmap, PlotPieChart, PlotScatter, PlotAreaChart |
| Workspace Operation | 12 | ReadFile, CreateFile, RunInTerminal, GrepSearch, etc. |
| (uncategorized) | 10 | Scheduled task 管理, Task (sub-agent delegation), read_skill_file |

> **Note**: `defaultMode` が `disabled` のツールは Experimental Settings を有効化すると使えるようになるものがある。MCP ツールは `source: "mcp"` で表示され、コネクタ作成後に反映される。

### Apply (宣言的リソース作成)

複数リソースを宣言的に作成・更新する汎用エンドポイント。

> **重要**: `Content-Type: text/yaml` が必須（`application/json` は 415 になる）。Body は YAML でも JSON でも可（YAML パーサーが JSON も解釈する）。

```bash
# 宣言的 apply (PUT)
curl -X PUT "$AGENT_ENDPOINT/api/v1/extendedAgent/apply" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "api_version": "azuresre.ai/v1",
    "kind": "ToolList",
    "spec": {
      "tools": [
        {
          "name": "my-python-tool",
          "type": "PythonFunctionTool",
          "description": "Tool description here",
          "function_code": "def main() -> dict:\n    return {\"result\": \"Hello\"}",
          "timeout_seconds": 120,
          "parameters": []
        }
      ]
    }
  }'
```

#### Python ツール作成

カスタム Python ツールを作成してエージェントに利用させることができる。

```bash
# srectl で作成
python3 scripts/srectl.py tool create \
  --name my-tool \
  --description "My custom tool" \
  --code-file tools/my_tool.py \
  --timeout 120

# 削除
python3 scripts/srectl.py tool delete my-tool
```

**API エンドポイント:**

```bash
# カスタムツール削除
curl -X DELETE "$AGENT_ENDPOINT/api/v1/extendedAgent/tools/{tool-name}" \
  -H "Authorization: Bearer $TOKEN"
```

**Python ツールの要件:**
- `main()` 関数を定義し、`dict` を返す
- パラメータを受け取る場合は `parameters` で JSON Schema 定義
- `timeout_seconds` でタイムアウトを設定（デフォルト 120秒）
- インターネットアクセス可能（Jupyter-style 環境で実行）

**パラメータ付きの例:**

```json
{
  "name": "query-tool",
  "type": "PythonFunctionTool",
  "description": "Execute a custom query",
  "function_code": "def main(query: str, limit: int = 10) -> dict:\n    return {\"query\": query, \"limit\": limit}",
  "timeout_seconds": 60,
  "parameters": [
    {"name": "query", "type": "string", "description": "The query to execute", "required": true},
    {"name": "limit", "type": "integer", "description": "Max results", "required": false}
  ]
}
```

#### Apply の kind 一覧

| api_version | kind | 用途 |
|-------------|------|------|
| `azuresre.ai/v1` | `ToolList` | カスタムツール作成（PythonFunctionTool 等） |
| `azuresre.ai/v2` | `ExtendedAgentTool` | 個別ツール定義（KustoTool 等） |

カスタムツールの type:

| type | 用途 | 備考 |
|------|------|------|
| `PythonFunctionTool` | カスタム Python 関数 | `main()` 関数を定義、pip 依存可 |
| `KustoTool` | KQL クエリ実行 | mode: Query/Function/Script、`##param##` で置換 |
| Link | URL テンプレート | ポータル UI で作成 |
| HTTP client | REST API 呼び出し | ポータル UI で作成 |

#### Kusto ツール定義 (YAML)

```yaml
api_version: azuresre.ai/v2
kind: ExtendedAgentTool
metadata:
  name: query-app-logs
spec:
  type: KustoTool
  connector: my-adx-connector
  mode: Query
  database: mydb
  description: "Query AppLogs for errors in a time range"
  toolMode: Auto
  query: |-
    AppLogs
    | where TimeGenerated > ago(##timeRange##)
    | where Level == "Error"
    | project TimeGenerated, Message
    | take 100
  parameters:
    - name: timeRange
      type: string
      description: "How far back to look (e.g., 1h, 24h)"
```

> **Note**: Apply API は `azuresre.ai/v1` と `azuresre.ai/v2` の2つの API バージョンが確認されている。Link / HTTP client ツールの宣言的作成方法は未検証。

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

## HTTP Triggers (v1)

HTTP Triggers はエージェントを外部から起動するための Webhook エンドポイント。

- 公式ドキュメント: https://sre.azure.com/docs/capabilities/http-triggers

### 認証の使い分け

| 操作 | トークン | 理由 |
|------|---------|------|
| 作成 / 一覧 / 削除 | データプレーン (`https://azuresre.ai`) | 管理操作 |
| **実行 (execute)** | **ARM (`https://management.azure.com`)** | `Microsoft.App/agents/threads/write` 権限が必要 |

### 作成

```bash
POST ${ENDPOINT}/api/v1/httptriggers/create
Content-Type: application/json
Authorization: Bearer ${DATAPLANE_TOKEN}

{
  "name": "start-contest",
  "description": "ISUCON contest kick",
  "agentPrompt": "ISUCON の競技を開始してください。制限時間は今から60分です。",
  "agent": "isucon",
  "agentMode": "autonomous"
}
```

レスポンス:
```json
{
  "triggerId": "18741a6b-...",
  "triggerUrl": "https://...azuresre.ai/api/v1/httptriggers/trigger/18741a6b-...",
  "message": "HTTP trigger created successfully"
}
```

### 一覧

```bash
GET ${ENDPOINT}/api/v1/httptriggers
Authorization: Bearer ${DATAPLANE_TOKEN}
```

### 実行

```bash
POST ${ENDPOINT}/api/v1/httptriggers/${TRIGGER_ID}/execute
Content-Type: application/json
Authorization: Bearer ${ARM_TOKEN}

# ボディはオプション。JSON を渡すとエージェントのプロンプトに追加される
{"key": "value"}
```

レスポンス (HTTP 202):
```json
{
  "message": "HTTP trigger execution initiated successfully",
  "execution": {
    "executionTime": "2026-04-19T10:41:42Z",
    "threadId": "4d16277b-...",
    "success": true
  }
}
```

### 削除

```bash
DELETE ${ENDPOINT}/api/v1/httptriggers/${TRIGGER_ID}
Authorization: Bearer ${DATAPLANE_TOKEN}
```

## Threads (v1)

Trigger 実行やチャットで作成されたスレッドのメッセージを取得する。

### メッセージ取得

```bash
GET ${ENDPOINT}/api/v1/threads/${THREAD_ID}/messages?skip=0&top=20&orderby=timestamp+desc
Authorization: Bearer ${DATAPLANE_TOKEN}
```

レスポンスの各メッセージの構造:
```json
{
  "id": "fe67165d-...",
  "timeStamp": "2026-04-19T10:54:45Z",
  "author": {
    "role": "SREAgent",
    "userId": "agent-default",
    "displayName": "Azure SRE Agent"
  },
  "text": "メッセージ本文...",
  "isComplete": false
}
```

- `author.role` は `SREAgent` / `User` / `System`
- `timeStamp` のキー名は camelCase (大文字 S)
- テキストが空のメッセージはツール実行ログ等

## Agent Hooks

Hooks はエージェントのライフサイクルイベント (Stop, PostToolUse 等) にプロンプトやスクリプトを差し込む仕組み。

- 公式ドキュメント: https://sre.azure.com/docs/capabilities/agent-hooks

### 2 つの設定方法

| 方法 | API | スコープ | 用途 |
|------|-----|---------|------|
| Global Hook | `PUT /api/v2/extendedAgent/hooks/{name}` | 全エージェント | 全体ポリシー (安全ガード等) |
| Agent Inline Hook | `PUT /api/v2/extendedAgent/agents/{name}` の `properties.hooks` | 特定エージェント | エージェント固有の制御 |

### Global Hook CRUD

```bash
# 作成/更新
PUT ${ENDPOINT}/api/v2/extendedAgent/hooks/${HOOK_NAME}
Content-Type: application/json
Authorization: Bearer ${DATAPLANE_TOKEN}

{
  "name": "gatekeeper",
  "type": "GlobalHook",
  "properties": {
    "eventType": "Stop",
    "activationMode": "always",
    "description": "Prevents agent from stopping during contest",
    "hook": {
      "type": "prompt",
      "timeout": 30,
      "failMode": "allow",
      "prompt": "Check if the contest has ended.\n$ARGUMENTS\n...",
      "model": "ReasoningFast",
      "maxRejections": 3
    }
  }
}

# 一覧
GET ${ENDPOINT}/api/v2/extendedAgent/hooks

# 取得
GET ${ENDPOINT}/api/v2/extendedAgent/hooks/${HOOK_NAME}

# 削除
DELETE ${ENDPOINT}/api/v2/extendedAgent/hooks/${HOOK_NAME}
```

### Agent Inline Hooks (v2 JSON)

エージェント作成/更新時に `properties.hooks` に埋め込む:

```bash
PUT ${ENDPOINT}/api/v2/extendedAgent/agents/${AGENT_NAME}
Content-Type: application/json

{
  "name": "my-agent",
  "type": "ExtendedAgent",
  "properties": {
    "instructions": "...(50文字以上必須)...",
    "hooks": {
      "Stop": [{
        "type": "prompt",
        "prompt": "...",
        "timeout": 30,
        "model": "ReasoningFast",
        "maxRejections": 3
      }],
      "PostToolUse": [{
        "type": "command",
        "matcher": "Bash|ExecuteShellCommand",
        "timeout": 30,
        "failMode": "block",
        "script": "#!/usr/bin/env python3\n..."
      }]
    }
  }
}
```

### Agent Inline Hooks (Apply API — YAML)

`kind: AgentConfiguration` で YAML をそのまま送ることも可能:

```bash
PUT ${ENDPOINT}/api/v1/extendedAgent/apply
Content-Type: text/yaml

api_version: azuresre.ai/v1
kind: AgentConfiguration
spec:
  name: my-agent
  system_prompt: |
    (50文字以上必須。短いと 500 Internal Server Error になる)
  agent_type: Autonomous
  enable_skills: true
  hooks:
    Stop:
      - type: prompt
        prompt: |
          Check if the task is complete.
          $ARGUMENTS
          Respond with {"ok": true} or {"ok": false, "reason": "..."}
        model: ReasoningFast
        timeout: 30
        failMode: allow
        maxRejections: 3
```

> **注意**: Apply API は `kind: AgentConfiguration` と `kind: ToolList` のみサポート。`kind: ExtendedAgent` は `400 Unsupported kind` になる。

### Hook イベントタイプ

| eventType | タイミング |
|-----------|----------|
| `Stop` | エージェントが応答を終了しようとする時 |
| `PostToolUse` | ツール実行後 (`matcher` でツール名フィルタ可) |

### Hook タイプ

| type | 説明 |
|------|------|
| `prompt` | LLM にプロンプトを送って判定。`model`: `ReasoningFast` / `ReasoningHeavy` |
| `command` | Python スクリプトを実行して判定。stdin に JSON コンテキスト、stdout に `{"ok": true}` or `{"decision": "block"}` |

### 注意事項

- ポータルの YAML タブに表示される形式 (`api_version: azuresre.ai/v1`, `kind: AgentConfiguration`) は Apply API 用のフォーマット
- `system_prompt` が 50 文字未満だと Apply API で 500 エラー (バリデーションではなくサーバーエラー)
- ポータルは空の `system_prompt` に長い CRITICAL WARNING コメントを自動挿入して 50 文字要件を回避している
- v2 JSON API (`PUT /api/v2/extendedAgent/agents/`) ではこの制限はない（50文字チェックはある）

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
  - [HTTP Triggers](https://sre.azure.com/docs/capabilities/http-triggers)
  - [Scheduled Tasks](https://sre.azure.com/docs/capabilities/scheduled-tasks)
- [SRE Agent ポータル](https://sre.azure.com)

### コミュニティ

- [matthansen0/azure-sre-agent-sandbox](https://github.com/matthansen0/azure-sre-agent-sandbox) — AKS + SRE Agent デモ環境 (PowerShell)。最も API を網羅的に使用。v2 Scheduled Tasks、Outlook/Azure Monitor コネクタ、Incident Filters read-only API の実例あり
- [gderossilive/AzSreAgentLab](https://github.com/gderossilive/AzSreAgentLab) — 複数デモシナリオ集 (Grubify, Grocery, Proactive Reliability)。Grafana MCP Proxy (Managed Identity + Streamable HTTP) の実装例
- [yortch/agentic-devops-demo](https://github.com/yortch/agentic-devops-demo) — Three Rivers Bank デモ。Chaos Engineering 13 シナリオ + Copilot Coding Agent 自動修正。jq のみで YAML→JSON 変換 (Python 不要)、GitHub OAuth フロー全体の自動化
- [msbrettorg/azcapman](https://github.com/msbrettorg/azcapman) — Capacity Management Plugin。`srectl` CLI のスキル定義と詳細な YAML スキーマリファレンス (`azuresre.ai/v2`)
