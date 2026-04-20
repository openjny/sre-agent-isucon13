---
name: app-caching
description: Implement application-level in-memory caching in Go using sync.Map for frequently accessed data that rarely changes
---

# Application-Level Caching (Go)

アプリケーション内のメモリキャッシュで、頻繁にアクセスされるが変更が少ないデータの DB クエリを削減する。

## キャッシュすべきデータの見つけ方

1. **アクセス頻度が高い**: 全リクエストで参照される（認証情報、設定データ等）
2. **変更頻度が低い**: ベンチマーク中にほぼ変化しない
3. **データサイズが小さい**: メモリに載せても問題ない

ソースコードとスローログを分析して候補を特定する。

## sync.Map を使った実装

### 基本パターン

```go
var cache sync.Map

func getByID(ctx context.Context, db *sqlx.DB, id int64) (*Model, error) {
    // キャッシュチェック
    if cached, ok := cache.Load(id); ok {
        return cached.(*Model), nil
    }

    // キャッシュミス → DB クエリ
    var model Model
    if err := db.GetContext(ctx, &model, "SELECT * FROM table WHERE id = ?", id); err != nil {
        return nil, err
    }

    // キャッシュに保存
    cache.Store(id, &model)
    return &model, nil
}
```

### キャッシュの無効化

`POST /api/initialize` でデータリセットされる場合、キャッシュもクリアが必要:

```go
func initializeHandler(c echo.Context) error {
    cache = sync.Map{}   // 全キャッシュをリセット
    // ... 既存の初期化ロジック
}
```

更新 API がある場合は、更新時にもキャッシュを無効化:

```go
func updateHandler(c echo.Context) error {
    // ... DB 更新
    cache.Delete(id)  // または cache.Store(id, &updatedModel) で更新
}
```

### 静的データのキャッシュ

ベンチマーク中に一切変更されないマスタデータは起動時にロード:

```go
var masterData []Item

func loadMasterData(db *sqlx.DB) {
    db.Select(&masterData, "SELECT * FROM master_table")
}
```

## TTL 付きキャッシュ

変更される可能性があるデータには TTL（有効期限）を設定:

```go
type CacheEntry struct {
    Value     interface{}
    ExpiresAt time.Time
}

func getCached(key string, ttl time.Duration, fetch func() (interface{}, error)) (interface{}, error) {
    if entry, ok := cache.Load(key); ok {
        if e := entry.(*CacheEntry); time.Now().Before(e.ExpiresAt) {
            return e.Value, nil
        }
    }
    val, err := fetch()
    if err != nil { return nil, err }
    cache.Store(key, &CacheEntry{Value: val, ExpiresAt: time.Now().Add(ttl)})
    return val, nil
}
```

## 注意点

- マルチサーバー構成の場合、各サーバーのキャッシュが不整合になる可能性がある
- キャッシュ更新の反映遅延がベンチマーカーの許容範囲内であることを確認
- メモリ使用量に注意（大量の画像データ等はキャッシュしない）
