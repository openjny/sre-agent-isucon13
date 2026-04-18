# デプロイ手順

## 前提条件

- Azure CLI 2.60+
- Azure Developer CLI (azd) 1.9+
- Git
- Docker
- Python 3.10+ (post-provision スクリプト用)

## 手順

### 1. Azure ログイン

```bash
az login
azd auth login
```

### 2. デプロイ

```bash
azd up
```

初回は Azure サブスクリプションとリージョンの選択を求められます。
所要時間: 約 8 分。

### 3. SSH 鍵セットアップ

```bash
bash scripts/setup-ssh-keys.sh
```

SSH 鍵ペアを生成し、Key Vault に秘密鍵を格納、全 VM に公開鍵を配布します。
所要時間: 約 3 分。

### 4. SRE Agent 構成

```bash
bash scripts/post-provision.sh
```

SRE Agent の Knowledge Base, Custom Agents, MCP Connector を自動構成します。
所要時間: 約 2 分。

## パラメータ

```bash
azd env set AZURE_LOCATION southeastasia       # デフォルト
azd env set SRE_AGENT_LOCATION australiaeast   # デフォルト
azd env set ENABLE_MONITORING true             # Azure Monitor 有効化
azd env set VM_SIZE_CONTEST Standard_D2s_v5    # デフォルト
azd env set VM_SIZE_BENCH Standard_D4s_v5      # デフォルト
```

## VM への接続

```bash
# az vm run-command (SSH 不要)
az vm run-command invoke -g rg-isucon13-system -n vm-isucon13-contest1 \
  --command-id RunShellScript --scripts "hostname"

# Key Vault から秘密鍵を取得
KV=$(az keyvault list -g rg-isucon13-system --query '[0].name' -o tsv)
az keyvault secret show --vault-name $KV --name ssh-private-key --query value -o tsv > /tmp/key
chmod 600 /tmp/key
```

## VS Code MCP 接続

`.vscode/mcp.json` が含まれているため、VS Code で開くと SSH MCP Server に接続可能です。
初回接続時に API Key の入力を求められます（`azd env get-value MCP_API_KEY` で取得）。

## クリーンアップ

```bash
azd down --purge
```

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| CSE 失敗 (VM プロビジョニング) | `az vm get-instance-view -g rg-isucon13-system -n <vm> --query instanceView.extensions` |
| post-provision.sh で 401 | `az login` で User として再ログイン（SP ではなく） |
| SSH MCP Server 接続不可 | `curl -s https://<FQDN>/health` で確認 |
| Key Vault アクセス拒否 | deployer に KV Secrets Officer が付与されているか確認 |
