---
name: alp-profiling
description: Install and use alp (Access Log Profiler) to identify slow nginx endpoints and analyze request patterns
---

# alp Profiling — nginx Access Log Analysis

alp は nginx のアクセスログを LTSV 形式で解析し、遅いエンドポイントを特定するツール。ISUCON では定番のプロファイリング手法。

## alp のインストール

```bash
wget -q https://github.com/tkuchiki/alp/releases/download/v1.0.21/alp_linux_amd64.tar.gz -O /tmp/alp.tar.gz && cd /tmp && tar xzf alp.tar.gz && sudo mv alp /usr/local/bin/ && alp --version
```

## nginx を LTSV 形式に設定

`/etc/nginx/nginx.conf` の `http` ブロック内に以下を追加:

```nginx
log_format ltsv "time:$time_local"
                "\thost:$remote_addr"
                "\tforwardedfor:$http_x_forwarded_for"
                "\treq:$request"
                "\tstatus:$status"
                "\tmethod:$request_method"
                "\turi:$request_uri"
                "\tsize:$body_bytes_sent"
                "\treferer:$http_referer"
                "\tua:$http_user_agent"
                "\treqtime:$request_time"
                "\tcache:$upstream_http_x_cache"
                "\truntime:$upstream_http_x_runtime"
                "\tapptime:$upstream_response_time"
                "\tvhost:$host";

access_log /var/log/nginx/access.log ltsv;
```

設定後に nginx をリロード:
```bash
sudo nginx -t && sudo systemctl reload nginx
```

## 使い方

### 基本（合計時間でソート）

```bash
sudo alp ltsv --file /var/log/nginx/access.log --sort sum -r
```

### パラメータ付き URL のグルーピング

動的パス（ID 等）を含む URL は `-m` オプションで正規表現グルーピングする。アプリのルーティングを確認して適切なパターンを設定:

```bash
# 例: /api/users/123 や /api/posts/456/comments をグルーピング
sudo alp ltsv --file /var/log/nginx/access.log --sort sum -r \
  -m '/api/users/[0-9]+,/api/posts/[0-9]+/comments,/api/posts/[0-9]+$'
```

**ポイント**: まずソースコードのルーティング定義 (router) を読んで、パラメータ付き URL を特定してからパターンを作成する。

## 主要メトリクス

| Column | 意味 |
|--------|------|
| COUNT | リクエスト数 |
| SUM | レスポンス時間合計 |
| AVG | 平均レスポンス時間 |
| MAX | 最大レスポンス時間 |
| P99 | 99パーセンタイル |

## ワークフロー

1. ログをクリア: `sudo truncate -s 0 /var/log/nginx/access.log`
2. ベンチマーク実行
3. alp で解析: SUM が最も大きいエンドポイントが最優先の改善対象
4. 改善 → 再ベンチ → 再解析のサイクルを回す

## Tips

- SUM（合計時間）が最も重要。1 リクエスト 0.1 秒でも 10,000 回呼ばれれば 1,000 秒
- MAX が大きいエンドポイントはタイムアウトや異常系の可能性
- COUNT が多い = ベンチマーカーが重点的にアクセスしている箇所
