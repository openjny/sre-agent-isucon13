---
name: db-indexing
description: General strategy for identifying and adding missing database indexes in ISUCON web applications
---

# Database Indexing Strategy

ISUCON の初期実装では、テーブルに適切なインデックスが設定されていないことが多い。スキーマを調査し、クエリパターンに基づいてインデックスを追加するのは最も ROI の高い最適化の一つ。

## 調査手順

### 1. スキーマの確認

```bash
# テーブル一覧
mysql -u <user> -p<password> <database> -e "SHOW TABLES"

# テーブル定義の確認
mysql -u <user> -p<password> <database> -e "SHOW CREATE TABLE <table_name>"

# 既存インデックスの確認
mysql -u <user> -p<password> <database> -e "SHOW INDEX FROM <table_name>"
```

### 2. クエリパターンの特定

- ソースコードの SQL クエリを grep して、`WHERE`, `JOIN`, `ORDER BY` で使われるカラムを特定
- slow query log を有効化して頻出クエリを分析

```bash
# Go の場合
grep -rn 'SELECT\|WHERE\|JOIN\|ORDER BY' /path/to/webapp/go/
```

## インデックスの追加パターン

### 外部キー (FK) カラム

`user_id`, `*_id` などの参照カラムにインデックスがない場合は追加:

```sql
ALTER TABLE <table> ADD INDEX idx_<column> (<column>);
```

### 複合インデックス

WHERE + ORDER BY の組み合わせが頻出する場合:

```sql
ALTER TABLE <table> ADD INDEX idx_<col1>_<col2> (<col1>, <col2>);
```

### カバリングインデックス

SELECT するカラムも含めて、テーブルアクセスなしで結果を返せる場合:

```sql
ALTER TABLE <table> ADD INDEX idx_covering (<where_col>, <select_col>);
```

## 重要な注意点

- ISUCON のベンチマーカーは多くの場合 `/api/initialize` でデータを初期化する
- `init.sh` やスキーマファイルで DROP TABLE / CREATE TABLE される場合、**インデックスも消える**
- インデックスを永続化するには、スキーマファイル自体を修正するか、初期化後に実行されるスクリプトに追加する

## 効果

- フルテーブルスキャンをインデックススキャンに変えるだけで 10-100 倍の高速化が見込める
- 特に統計・集計系エンドポイントへの効果が大きい
