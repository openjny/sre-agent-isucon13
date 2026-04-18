# アーキテクチャ設計

## 概要

ISUCON13 過去問「ISUPIPE」を Azure VM 上に再現し、Azure SRE Agent が MCP Server 経由で自律的にパフォーマンスチューニングを行う検証環境。

SRE Agent はインターネット経由で ACA 上の ISUCON MCP Server に接続し、MCP Server が VNet 内の VM に SSH でコマンドを実行する。

```
SRE Agent (Australia East)
    │
    │ HTTPS (Bearer Token)
    ▼
ACA: ISUCON MCP Server (Southeast Asia, VNet 統合)
    │
    │ SSH (ed25519, Private IP)
    ▼
VNet 10.0.0.0/16
├─ vm1  10.0.1.4  contest server
├─ vm2  10.0.1.5  contest server
├─ vm3  10.0.1.6  contest server
└─ bench 10.0.1.7 benchmark server
```

## リソースグループ構成

SRE Agent は利用可能リージョンが限られるため、2 RG に分離。

| RG | リージョン | リソース | 理由 |
|----|-----------|---------|------|
| rg-isucon13-system | Southeast Asia | VNet, VM×4, ACA, ACR, Key Vault, NAT GW | コンピューティングクォータが豊富 |
| rg-isucon13-sreagent | Australia East | SRE Agent, Log Analytics, App Insights | SRE Agent 対応リージョン |

## VM 構成

### Contest VM (vm1, vm2, vm3)

初期状態では 3 台とも同一構成。ISUCON 参加者はこれを自由に再配置する。

| コンポーネント | ポート | 設定ファイル | 説明 |
|---------------|--------|-------------|------|
| nginx | 443 (HTTPS) | `/etc/nginx/sites-enabled/isupipe.conf` | TLS 終端、Go app へリバースプロキシ |
| isupipe-go | 8080 | systemd `isupipe-go` | ISUPIPE Go アプリケーション |
| MySQL 8.0 | 3306 | `/etc/mysql/` | `isupipe` DB + `isudns` DB |
| PowerDNS | 53/UDP | `/etc/powerdns/pdns.conf` | `*.u.isucon.dev` の名前解決 |

- ソースコード: `/home/isucon/isucon13/webapp/go/`
- DB スキーマ: `/home/isucon/isucon13/webapp/sql/initdb.d/10_schema.sql`
- データ初期化: `/home/isucon/isucon13/webapp/sql/init.sh`

### Benchmark VM (bench)

| コンポーネント | パス | 説明 |
|---------------|------|------|
| benchmarker | `/home/isucon/isucon13/bench/bin/bench_linux_amd64` | ISUCON13 ベンチマーカー |
| run-benchmark.sh | `/home/isucon/run-benchmark.sh` | ベンチ実行ヘルパー |

ベンチマーカーは vm1 の PowerDNS (10.0.1.4:53) をネームサーバーとして使用し、`*.u.isucon.dev` ドメインで各 VM にアクセスする。

## ネットワーク

```
VNet: 10.0.0.0/16
├─ snet-vms:  10.0.1.0/24  (VM×4)
└─ snet-aca:  10.0.2.0/23  (ACA Environment)
```

- **Public IP なし**: 全 VM は Private IP のみ。外部アクセスは NAT Gateway 経由。
- **NSG**: VM サブネットへの SSH (22) は VNet 内部からのみ許可。
- **NAT Gateway**: VM からのパッケージインストール等のアウトバウンド用。

## TLS 証明書

### 課題

ISUCON13 のリポジトリには Let's Encrypt で発行された `*.u.isucon.dev` のワイルドカード証明書が含まれているが、2024-01-29 に失効済み。ベンチマーカーは `--enable-ssl` で HTTPS 接続するため、有効な証明書が必要。

### 設計

Bicep の Deployment Script (`ssh-keygen.bicep`) で自己署名証明書を生成し、Key Vault に格納。各 VM がプロビジョニング時に Managed Identity で取得する。

```
Deployment Script (ssh-keygen.bicep)
  └─ openssl で自己署名証明書生成 (*.u.isucon.dev, 10年有効)
      ├─ KV secret: tls-cert
      └─ KV secret: tls-key

Contest VM (SystemAssigned MI → KV Secrets User)
  └─ provision-vm-contest.sh
      └─ IMDS → KV REST API で cert+key 取得 → /etc/nginx/tls/

Bench VM (SystemAssigned MI → KV Secrets User)
  └─ provision-vm-benchmark.sh
      └─ IMDS → KV REST API で cert 取得 → /usr/local/share/ca-certificates/ → update-ca-certificates
```

az cli は VM にインストールしない（重量級）。代わりに IMDS + curl で MI トークンを取得し、KV REST API で直接シークレットを読む。

## DNS

### 仕組み

各 contest VM で PowerDNS が動作し、`*.u.isucon.dev` ゾーンを MySQL (`isudns` DB) から応答する。ベンチマーカーは vm1 (10.0.1.4) をネームサーバーとして指定。

### 初期化

`POST /api/initialize` → Go アプリが `init.sh` → `init_zone.sh` を実行。`init_zone.sh` は `ISUCON13_POWERDNS_SUBDOMAIN_ADDRESS` 環境変数で DNS レコードの IP を決定する。

```
/home/isucon/env.sh
  └─ export ISUCON13_POWERDNS_SUBDOMAIN_ADDRESS=10.0.1.X  (VM の Private IP)
```

この env.sh がないと `127.0.0.1` にフォールバックし、ベンチマーカーが接続できなくなる。プロビジョニング時に `provision-vm-contest.sh` で自動生成。

### 注意

- `pdns.conf` は `chmod 644` にする必要がある（isucon ユーザの `pdnsutil` が読めるように）
- `systemd-resolved` は port 53 を占有するため、プロビジョニング時に無効化

## ISUCON MCP Server

### ツール

| ツール | 説明 | 引数 |
|--------|------|------|
| `exec` | SSH 経由でリモートコマンド実行 | `host`, `command` |
| `benchmark_start` | ベンチマーク非同期実行。ジョブ ID 返却 | `options` (省略可) |
| `benchmark_status` | ジョブ状態・スコア取得 | `job_id` (省略で最新) |

### ベンチマーク管理

ベンチマークは SSH セッションが ~2 分ブロックされるため、`exec` ではなく専用の非同期ツールで管理する。

- **排他制御**: 同時に 1 つのベンチマークのみ実行可能（bench VM が 1 台のため）
- **ジョブ管理**: in-memory map（ACA は `maxReplicas: 1`）
- **スコアパース**: stdout から `score: NNNN` パターンを抽出

### 認証

`API_KEY` 環境変数で設定。`Authorization: Bearer <key>` または `X-API-Key` ヘッダーで認証。

### SSH 鍵

Key Vault から Managed Identity で取得。初回アクセス時にロードし、以降はキャッシュ。

## SRE Agent 構成

### カスタムエージェント

| Agent | 役割 | 主な使用ツール |
|-------|------|---------------|
| benchmark-runner | ベンチ実行・結果解析 | `benchmark_start`, `benchmark_status` |
| performance-investigator | ボトルネック調査 | `exec` (top, vmstat, slow query log 等) |
| code-optimizer | Go コード最適化 | `exec` (ファイル読み書き、ビルド、再起動) |

### MCP Connector

```
名前: isucon-mcp
タイプ: Mcp (not McpServer)
エンドポイント: https://<ACA FQDN>/mcp
認証: BearerToken
```

Dataplane API で作成。ポータルには表示されないが機能する。

### Knowledge Base

SRE Agent に ISUCON13 固有の知識を与えるためのドキュメント群。Dataplane API でアップロード。

- `isupipe-architecture.md` — アプリ構成、API、DB スキーマ
- `isupipe-optimization-guide.md` — 定番の最適化手法（Tier 1-6）
- `benchmark-runbook.md` — ベンチ実行手順、結果の読み方
- `server-topology.md` — VM 構成、IP、サービス管理コマンド

## ベンチマーク

### フロー

```
benchmark_start
  └─ bench VM: /home/isucon/run-benchmark.sh
      └─ bench_linux_amd64 run --target https://pipe.u.isucon.dev --nameserver 10.0.1.4 --enable-ssl
          ├─ POST /api/initialize (42s timeout) → init.sh → DB リセット + DNS ゾーン再読込
          ├─ 整合性チェック (20s)
          ├─ 負荷試験 (60s) → スコア = ISUCOIN 合計
          └─ 最終検証 (10s)
```

### スコア目安

| レベル | スコア |
|--------|--------|
| 初期状態 | ~3,600 |
| インデックス追加 | ~10,000 |
| N+1 解消 | ~30,000-50,000 |
| マルチサーバー分散 | ~100,000+ |
| 大会優勝 | 468,006 |

### 改善サイクル

```
調査 (performance-investigator)
  → 改善 (code-optimizer)
    → pretest (benchmark_start --pretest-only)
      → 本ベンチ (benchmark_start)
        → 結果分析 (benchmark-runner)
          → 次の調査へ
```

- ベンチ実行中は VM への変更操作を行わない（サービス再起動等はベンチ失敗の原因になる）
- pretest で整合性チェックだけ先に通す（~45 秒で完了）
- 本ベンチは ~2 分かかる
