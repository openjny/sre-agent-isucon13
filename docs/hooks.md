# SRE Agent Hooks ガイド

エージェントの動作を制御するカスタムチェックポイント。YAML v2 (`api_version: azuresre.ai/v2`, `kind: ExtendedAgent`) 専用機能。

## 概要

```
Agent が応答を返そうとする → Stop hook が評価 → allow / block
Agent がツールを使う       → PostToolUse hook が結果を検査 → allow / block / context 注入
```

## YAML 構造

```yaml
api_version: azuresre.ai/v2
kind: ExtendedAgent
metadata:
  name: my_agent
spec:
  instructions: |
    ...
  hooks:
    Stop:
      - type: prompt | command
        ...
    PostToolUse:
      - type: prompt | command
        matcher: "ToolName|OtherTool"  # 必須（正規表現、* で全ツール）
        ...
```

## イベントタイプ

| イベント | タイミング | 用途 |
|---------|----------|------|
| **Stop** | エージェントが最終応答を返す直前 | 品質ゲート、完了条件の検証、フォーマット強制、作業継続の強制 |
| **PostToolUse** | ツール実行成功後（**実行後**であり防止ではない） | 監査ログ、危険操作検知、コンテキスト注入 |

## 実行タイプ

| タイプ | 仕組み | 適用場面 |
|-------|-------|---------|
| **prompt** | LLM がプロンプトを評価し JSON を返す | 主観的な品質評価（「調査は十分か？」） |
| **command** | bash/Python スクリプトがサンドボックスで実行 | 決定論的チェック、ポリシー強制、監査ログ |

## 設定オプション

| オプション | 型 | デフォルト | 説明 |
|-----------|---|----------|------|
| `type` | string | `prompt` | `prompt` or `command` |
| `prompt` | string | — | LLM プロンプト。`$ARGUMENTS` でコンテキスト注入（prompt 用） |
| `script` | string | — | 複数行スクリプト（command 用、`command` と排他） |
| `command` | string | — | インラインコマンド（command 用、`script` と排他） |
| `matcher` | string | — | ツール名の正規表現（PostToolUse **必須**）。`*` で全ツール。`^(pattern)$` でアンカーされる |
| `timeout` | int | `30` | タイムアウト秒数（1–300） |
| `failMode` | string | `allow` | エラー時の挙動: `allow` or `block` |
| `model` | string | `ReasoningFast` | prompt hooks 用モデル |
| `maxRejections` | int | `3` | 最大リジェクション回数（1–25）。**prompt タイプの Stop hook のみ有効**。command タイプには効かない |

## レスポンス形式

### prompt hooks

```json
{"ok": true}
{"ok": false, "reason": "理由を記載"}
```

### command hooks

```json
{"decision": "allow"}
{"decision": "block", "reason": "理由を記載"}
{"decision": "allow", "hookSpecificOutput": {"additionalContext": "監査メモ"}}
```

command hooks は exit code でも制御可能:

| Exit code | 挙動 |
|-----------|------|
| `0` + 出力なし | allow |
| `0` + JSON | JSON をパース |
| `2` | 常に block（stderr が reason になる） |
| その他 | `failMode` に従う |

> **注意**: Stop hook で reason なしの rejection は **approval として扱われる**。block 時は必ず `reason` を付けること。

## Hook コンテキスト（stdin / $ARGUMENTS）

command hooks は `stdin` から JSON を受け取る。prompt hooks は `$ARGUMENTS` プレースホルダ経由。

### 共通フィールド

```json
{
  "hook_event_name": "Stop",
  "agent_name": "test",
  "current_turn": 4,
  "max_turns": 250,
  "execution_summary": "/mnt/data/hook_transcript_XXXX.txt"
}
```

### Stop hook 追加フィールド

```json
{
  "final_output": "エージェントの最終応答テキスト",
  "stop_hook_active": false,
  "stop_rejection_count": 0
}
```

### PostToolUse hook 追加フィールド

```json
{
  "tool_name": "ExecutePythonCode",
  "tool_input": { "code": "print(2+2)" },
  "tool_result": "4",
  "tool_succeeded": true
}
```

### execution_summary の中身

`execution_summary` はファイルパスで、会話トランスクリプトを含む JSON ファイル:

```json
{
  "items": [
    { "type": "text", "role": "user",      "text": "@test: はろー" },
    { "type": "text", "role": "assistant",  "text": "{\"notifyUserMessage\":\"...\", \"reasoningScratchPad\":\"...\", \"state\":\"CompletedSuccessfully\", \"stateExplanation\":\"...\"}" }
  ]
}
```

assistant の応答は JSON 文字列で、以下のフィールドを含む:

| フィールド | 内容 |
|-----------|------|
| `notifyUserMessage` | ユーザーに表示されるメッセージ |
| `reasoningScratchPad` | エージェントの内部思考過程 |
| `state` | 状態（`CompletedSuccessfully` 等） |
| `stateExplanation` | 状態の説明 |

## command タイプの Stop hook で maxRejections を自前実装

`maxRejections` は prompt タイプ専用。command タイプでは `stop_rejection_count` を使ってスクリプト内で制御する:

```yaml
hooks:
  Stop:
  - type: command
    timeout: 30
    failMode: block
    script: |
      #!/usr/bin/env python3
      import sys, json
      context = json.load(sys.stdin)
      MAX_REJECTIONS = 25
      if context.get('stop_rejection_count', 0) >= MAX_REJECTIONS:
          print(json.dumps({"decision": "allow"}))
      else:
          print(json.dumps({"decision": "block", "reason": "作業を継続してください。"}))
```

## 注意点・罠

### reason に大きなデータを入れると膨張する

hook の `reason` は **user メッセージとして会話に注入される**。次の Stop 時に `execution_summary` にその注入メッセージも含まれるため、reason にコンテキスト全体をダンプすると再帰的に膨張し、最終的に `Failed to parse hook output` エラーになる。

**対策**: デバッグ情報は `stderr` に出力する（`print(..., file=sys.stderr)`）。reason は短いメッセージに留める。

### PostToolUse は防止ではなく検知

PostToolUse はツール実行**後**に発火する。`decision: block` はツール結果の利用をブロックするが、コマンド自体は既に実行済み。真の防止には RBAC や Review モードを併用する。

### ポータルに表示されない

REST API v2 で設定した hooks はポータルの YAML タブに表示されないが、正常に動作する。Builder → Hooks ページで確認可能。

## 参考リポジトリ・ドキュメント

| リソース | URL | 特徴 |
|---------|-----|------|
| MS Learn 公式 | https://learn.microsoft.com/azure/sre-agent/agent-hooks | スキーマ定義、公式例 |
| raskip/azure-sre-agent-stuff | https://github.com/raskip/azure-sre-agent-stuff/tree/main/hooks | 8 つの実例 YAML + 詳細ガイド |
| microsoft/sre-agent | https://github.com/microsoft/sre-agent/tree/main/samples | 公式サンプル（v1 形式、hooks なし） |
| Tech Community Blog | https://techcommunity.microsoft.com/blog/appsonazureblog/agent-hooks-production-grade-governance-for-azure-sre-agent/4500292 | PostgreSQL インシデントの実践例 |

### raskip/azure-sre-agent-stuff の Hook 実例

| Hook | イベント | タイプ | 用途 |
|------|--------|-------|------|
| `block-dangerous-commands` | PostToolUse | command | `rm -rf`, `sudo`, `chmod 777`, `DROP TABLE` 等を検知 |
| `audit-all-tool-usage` | PostToolUse | command | 全ツール呼び出しを監査ログ |
| `enforce-structured-response` | Stop | prompt | Root Cause / Evidence / Recommended Actions の構造を強制 |
| `require-evidence-in-diagnostics` | Stop | prompt | 具体的な数値（CPU 94%等）を含む回答を強制 |
| `block-vm-deletion` | PostToolUse | command | VM/RG/Disk 等の削除操作を検知 |
| `restrict-to-readonly` | PostToolUse | command | 書き込み操作を検知（読み取り専用モード） |
| `require-summary-section` | Stop | prompt | Summary セクションの必須化 |
| `allowlist-remediation` | PostToolUse | command | 承認済み修正コマンドのみ許可 |
