---
name: isucon-scoring-patterns
description: Common ISUCON scoring patterns and strategies to achieve score jumps based on historical competition data
---

# ISUCON Scoring Patterns — Historical Strategies

過去の ISUCON (ISUCON 9-13) で観察された、スコアジャンプにつながるパターン集。

## スコア停滞と突破のパターン

| 状態 | 突破戦略 |
|------|---------|
| 初期実装のまま | DB インデックス追加、明らかな N+1 修正 |
| 基本インデックス済み | ホットパスの N+1 解消、キャッシュ導入 |
| 単一サーバーで最適化済み | マルチサーバー分散、LB セットアップ |
| マルチサーバー + クエリ最適化 | アプリレベルキャッシュ、DNS 最適化 |
| 全最適化済み | ファインチューニング、エッジケース、並行性 |

## 高インパクトパターン

### 1. "Index Everything" パターン
全 ISUCON で意図的にインデックスが欠落している。全 FK カラムと WHERE で使われるカラムをチェック:
```sql
SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = '<dbname>' AND TABLE_NAME NOT IN (
    SELECT DISTINCT TABLE_NAME FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = '<dbname>' AND INDEX_NAME != 'PRIMARY'
);
```

### 2. "Single Heavy Endpoint" パターン
通常、1 つのエンドポイントが全体の 50% 以上の時間を消費している。そのエンドポイントを修正するだけでスコアが倍になる。
- alp でプロファイルして SUM が最大のエンドポイントを見つける

### 3. "Serve Static from nginx" パターン
アプリが画像/ファイルをアプリケーション経由で配信している場合 → nginx の直接配信に移行。

### 4. "Split DB and App" パターン
単一サーバーで CPU がボトルネックの場合:
- DB 専用サーバーに全 RAM を buffer pool に割り当て
- App サーバーにリクエスト処理の全 CPU を割り当て

### 5. "Denormalize Statistics" パターン
重い集計を毎リクエスト計算する代わりに、事前計算・インクリメンタル更新:
```sql
-- 毎回: SELECT SUM(amount) FROM transactions WHERE user_id = ?
-- 代わりに: INSERT/UPDATE 時にカウンターを更新
UPDATE user_stats SET total_amount = total_amount + ? WHERE user_id = ?
```

## メタ戦略

1. **計測してから最適化** (alp + slow query)
2. **最大のボトルネックを修正** (最も簡単なものではなく)
3. **一度に一つの変更** (影響を分離)
4. **pretest で検証** してからフルベンチマーク
5. **スコア推移を追跡** (収穫逓減 → 次のティアへ)
