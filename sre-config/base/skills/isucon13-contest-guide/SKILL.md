---
name: isucon13-contest-guide
description: "ISUCON13 contest manual — server topology, service management, benchmark execution, and rules. Use when: checking environment setup, running benchmarks, or understanding contest constraints"
---

# ISUCON13 当日マニュアル

## アプリケーション ISUPipe について

ISUPipe の仕様については [ISUPipe アプリケーションマニュアル](../isupipe/SKILL.md) を参照してください。

## 競技環境について

### サーバー構成

競技用サーバー 3 台とベンチマーカーサーバー 1 台が提供されています。

| サーバー | 役割 | サービス |
|---------|------|---------|
| vm1 | Contest Server 1 | nginx, MySQL, PowerDNS, isupipe-go |
| vm2 | Contest Server 2 | nginx, MySQL, PowerDNS, isupipe-go |
| vm3 | Contest Server 3 | nginx, MySQL, PowerDNS, isupipe-go |
| bench | Benchmark Server | benchmarker |

各サーバーには MCP ツールの `exec` コマンドでアクセスできます。

```
exec host="vm1" command="..."
```

コマンドは `isucon` ユーザーで実行されます。root 権限が必要な場合は `sudo` を使用してください。

### サーバー上のファイル構成

```
/home/isucon/isucon13/
├── webapp/
│   ├── go/           # Go 実装（初期状態で稼働中）
│   ├── node/         # Node.js 実装
│   ├── perl/         # Perl 実装
│   ├── php/          # PHP 実装
│   ├── python/       # Python 実装
│   ├── ruby/         # Ruby 実装
│   ├── rust/         # Rust 実装
│   └── sql/
│       ├── initdb.d/10_schema.sql  # DB スキーマ
│       └── init.sh                 # データ初期化スクリプト
├── envcheck/         # 環境確認ツール
└── docs/             # ドキュメント
```

### サービス管理

各コンテストサーバーで以下の systemd サービスが動作しています。

| サービス | ポート | 設定ファイル |
|---------|--------|-------------|
| isupipe-go | 8080 | systemd unit |
| nginx | 443 (HTTPS) | `/etc/nginx/sites-enabled/isupipe.conf` |
| mysql | 3306 | `/etc/mysql/` |
| pdns | 53/UDP | `/etc/powerdns/pdns.conf` |

サービスの確認:
```
exec host="vm1" command="systemctl status isupipe-go nginx mysql pdns --no-pager"
```

サービスの再起動:
```
exec host="vm1" command="sudo systemctl restart isupipe-go"
```

### MySQL 接続情報

- ホスト: 127.0.0.1
- ポート: 3306
- ユーザー: `isucon`
- パスワード: `isucon`
- データベース:
  - `isupipe` — アプリケーションデータ
  - `isudns` — PowerDNS ゾーンデータ

### DNS

各コンテスト VM で PowerDNS が動作し、`*.u.isucon.dev` の名前解決を提供しています。ベンチマーカーは vm1 の PowerDNS をネームサーバーとして使用します。

## ベンチマーカーの実行

ベンチマークは MCP ツールで実行します。ポータルは使用しません。

### ベンチマーク開始

```
benchmark_start
```

ベンチマークは非同期で実行されます。`job_id` が返却されます。同時に実行できるベンチマークは 1 つのみです。

### Pretest（整合性チェックのみ）

```
benchmark_start options="--pretest-only"
```

### ベンチマーク結果の確認

```
benchmark_status job_id="<job_id>"
```

`job_id` を省略すると最新のジョブの状態が返却されます。

### ベンチマーク履歴

```
benchmark_history limit=5
```

## 参考実装

初期状態では Go による実装が起動しています。

### 参考実装の切り替え方法

Go から他の言語に切り替えるには以下の手順を実行します。

1. isupipe-go.service を停止、無効化します:

```
exec host="vm1" command="sudo systemctl disable --now isupipe-go.service"
```

2. isupipe-{各言語}.service を起動、有効化します:

```
exec host="vm1" command="sudo systemctl enable --now isupipe-{各言語}.service"
```

`{各言語}` には perl, ruby, node, python, rust が入ります。

#### PHP への切り替え

PHP の場合のみ、nginx の設定変更が追加で必要です:

```
exec host="vm1" command="sudo ln -s /etc/nginx/sites-available/isupipe-php.conf /etc/nginx/sites-enabled/ && sudo systemctl restart nginx.service"
```

## 競技環境の再構築方法

設定変更等により競技環境を破壊した場合、`azd` を使って環境を再構築できます。

```bash
azd down --purge   # 既存環境を削除
azd up             # 再構築
```

ソースコードや設定ファイル等の移行が必要な場合は、再構築前にバックアップしてください。

## 重要事項

### 変更してはいけない点

以下のファイルや設定は変更しないでください:

* ユーザーのパスワードのハッシュアルゴリズム（bcrypt）やコストの変更
* `POST /api/initialize` のレスポンス形式（`{"lang":"go"}` を返す必要がある）

### スコアについて

* スコアは負荷走行中に得られた ISUCOIN の投げ銭の合計です
* ベンチマーカーが正常終了しない場合、スコアは 0 点となります

### アイコン画像配信

* `GET /api/user/:username/icon` は条件付き GET（`If-None-Match`）に対応できます（MAY）
* アイコン更新後、2 秒以内に変更が反映されている必要があります（MUST）
* 条件付き GET でない場合、304 を返してはいけません（MUST NOT）

### コンテンツ配信サービス

映像とサムネイル画像の配信は `media.xiii.isucon.dev` から行われます。このサーバーはチューニング対象外です。
