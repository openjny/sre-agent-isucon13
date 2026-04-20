---
name: go-db-tuning
description: Tune Go database/sql connection pool settings for optimal MySQL performance under ISUCON load
---

# Go DB Connection Pool Tuning

Go の `database/sql` パッケージのデフォルト設定は ISUCON のような高負荷ワークロードに最適化されていない。接続プールの設定を調整する。

## 主要設定

`sql.Open()` の直後に以下を追加:

```go
db.SetMaxOpenConns(25)       // 同時接続数の上限 (デフォルト: 無制限)
db.SetMaxIdleConns(25)       // アイドル接続の保持数 (デフォルト: 2)
db.SetConnMaxLifetime(0)     // 接続の最大寿命 (0 = 無制限)
db.SetConnMaxIdleTime(0)     // アイドルタイムアウト (0 = 無制限)
```

## 各設定の意味

| 設定 | デフォルト | 推奨値 | 理由 |
|------|-----------|--------|------|
| MaxOpenConns | ∞ | 25 | MySQL のmax_connections を超えないようにする |
| MaxIdleConns | 2 | = MaxOpenConns | コネクション再作成のオーバーヘッドを回避 |
| ConnMaxLifetime | ∞ | 0 | ベンチ中は接続ローテーション不要 |

### MaxOpenConns の決め方

- MySQL のデフォルト `max_connections` は 151
- 複数サーバーからの接続を考慮: `max_connections / サーバー数` 程度
- 少なすぎると待ち行列が発生、多すぎると MySQL が過負荷

## Prepared Statements の最適化

`db.Prepare()` を使っている場合、`interpolateParams=true` を DSN に追加すると round-trip を削減できる:

```go
// 3 round-trip (Prepare → Execute → Close) → 1 round-trip に
dsn := "user:password@tcp(host:3306)/dbname?parseTime=true&interpolateParams=true"
```

## 確認方法

```bash
# Go ソースで sql.Open を探す
grep -n 'sql.Open\|db.Set' /path/to/webapp/go/*.go
```

## 効果

- 高負荷時の "too many connections" エラーを防止
- コネクション再作成のオーバーヘッドを排除
- アイドル接続の再利用でレイテンシ改善
