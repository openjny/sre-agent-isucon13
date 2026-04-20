---
name: n-plus-one-fix
description: General techniques for identifying and fixing N+1 query problems in ISUCON web applications
---

# N+1 Query Elimination

ISUCON の初期実装にはほぼ確実に N+1 クエリ問題が存在する。ループ内でクエリを発行するパターンを見つけて、JOIN やバッチクエリに置き換えるのは定番の最適化。

## N+1 の見つけ方

### 1. ソースコードの grep

```bash
# ループ内のクエリを探す
grep -n 'for.*{' /path/to/webapp/go/*.go | head -20
# その近くにある SELECT を確認
grep -n 'SELECT\|Query\|QueryRow\|Get\|Find' /path/to/webapp/go/*.go
```

### 2. slow query log の分析

同じクエリが大量に実行されていれば N+1 の兆候:

```bash
pt-query-digest /var/log/mysql/slow.log | head -50
```

### 3. よくある発生パターン

- **一覧取得 → ループでリレーション取得**: コメント一覧の各コメントに対してユーザー情報を個別取得
- **統計計算 → ループで集計**: ユーザーごとにループしてスコアを個別集計
- **ネストされた関連データ**: 親 → 子 → 孫と 3 段階ループ

## 修正パターン

### パターン 1: JOIN で一発取得

```sql
-- Before: SELECT * FROM comments WHERE post_id = ? (ループ内)
-- After:
SELECT c.*, u.name, u.display_name
FROM comments c
INNER JOIN users u ON u.id = c.user_id
WHERE c.post_id = ?
```

### パターン 2: バッチ取得 + IN 句

```go
// IDs を集めてまとめて取得
ids := make([]int64, len(items))
for i, item := range items {
    ids[i] = item.UserID
}
// SELECT * FROM users WHERE id IN (?, ?, ?, ...)
```

### パターン 3: 集計クエリの統合

```sql
-- Before: ループで個別 COUNT/SUM
-- After: GROUP BY で一括集計
SELECT user_id, COUNT(*) as cnt, IFNULL(SUM(amount), 0) as total
FROM transactions
GROUP BY user_id
```

## 実装手順

1. スローなエンドポイントを特定（alp や slow query log で）
2. そのハンドラのソースコードを読む
3. ループ内クエリを JOIN / バッチクエリに置き換え
4. リビルド → 再起動 → ベンチマーク

## 注意点

- JOIN にする際、LEFT JOIN と INNER JOIN の使い分けに注意（データが存在しない場合の挙動）
- IN 句のパラメータ数が多すぎる場合は分割が必要（MySQL のデフォルトは問題ないが、数万件は避ける）
- 集計クエリ統合時は、元のロジックと結果が一致することを pretest で検証

## 効果

- O(N) や O(N²) のクエリ回数を O(1) に削減
- 統計・ランキング系エンドポイントでは劇的な改善が見込める
