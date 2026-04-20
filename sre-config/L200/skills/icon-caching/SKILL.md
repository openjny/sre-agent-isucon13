---
name: icon-caching
description: General techniques for optimizing user icon/avatar image serving in ISUCON web applications
---

# Icon / Image Caching Strategy

ISUCON の Web アプリでは、ユーザーアイコンやプロフィール画像を DB (BLOB) に格納していることが多い。リクエストごとに大きな BLOB を読み出すのはボトルネックになりやすい。

## よくあるパターン

1. **アイコンが DB の BLOB カラムに格納されている** → 毎リクエストで数十〜数百 KB の読み出し
2. **条件付き GET (ETag / If-None-Match) に対応していない** → 変更がなくても毎回フルボディを返す

## 対策

### 方法 A: ETag / 304 Not Modified の実装

1. 画像アップロード時に SHA256 ハッシュを計算・保存
2. GET リクエスト時:
   - `If-None-Match` ヘッダーとハッシュを比較
   - 一致 → `304 Not Modified`（ボディなし）
   - 不一致 → `200 OK` + `ETag` ヘッダー付きで画像返却

```go
// 例: Go (echo)
hash := fmt.Sprintf("%x", sha256.Sum256(imageData))
if c.Request().Header.Get("If-None-Match") == fmt.Sprintf(`"%s"`, hash) {
    return c.NoContent(http.StatusNotModified)
}
c.Response().Header().Set("ETag", fmt.Sprintf(`"%s"`, hash))
return c.Blob(http.StatusOK, "image/jpeg", imageData)
```

### 方法 B: ファイルシステムから配信

1. アップロード時にファイルに書き出し
2. nginx の `sendfile` + `etag on` で直接配信
3. アプリサーバーへのリクエスト自体をなくせる

### 方法 C: インメモリキャッシュ

1. 初回読み出し時にメモリにキャッシュ
2. アップロード時にキャッシュを更新
3. DB アクセスを最小化

## 注意点

- アイコン更新後の反映遅延に注意（ベンチマーカーが一定時間以内の反映を要求する場合がある）
- `POST /api/initialize` でデータリセットされる場合、キャッシュも適切にクリアする
- ファイルシステム配信の場合、パーミッションや nginx の設定に注意

## 効果

- BLOB 読み出しの大部分を 304 レスポンスに置き換えることで、DB 負荷とネットワーク転送量を大幅に削減
