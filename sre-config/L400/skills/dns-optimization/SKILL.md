---
name: dns-optimization
description: Optimize PowerDNS performance for ISUCON competitions where DNS resolution is a component
---

# DNS Optimization (PowerDNS)

ISUCON では PowerDNS + MySQL バックエンドが使われることがある。ベンチマーカーが大量の DNS クエリを発行する場合、DNS がボトルネックになりうる。

## よくある問題

- PowerDNS が MySQL バックエンドにクエリするたびに DB アクセスが発生
- ランダムなサブドメインへの大量クエリ（DNS 水責め攻撃的なパターン）で負荷が増大
- NXDOMAIN（存在しないドメイン）のレスポンスも MySQL への問い合わせが必要

## 対策 1: isudns テーブルにインデックス追加

PowerDNS の records テーブルにインデックスがない場合がある:

```sql
SHOW INDEX FROM records;
ALTER TABLE records ADD INDEX idx_name_type (name, type);
ALTER TABLE records ADD INDEX idx_domain_id (domain_id);
```

## 対策 2: PowerDNS キャッシュの有効化

`/etc/powerdns/pdns.conf` にキャッシュ設定を追加:

```
query-cache-ttl=60
negquery-cache-ttl=60
cache-ttl=60
```

- `query-cache-ttl`: クエリ結果のキャッシュ秒数
- `negquery-cache-ttl`: NXDOMAIN のキャッシュ秒数（水責め対策に効果的）

設定変更後:
```bash
sudo systemctl restart pdns
```

## 対策 3: アプリケーションレベル DNS（上級）

PowerDNS を完全にバイパスして、Go アプリで DNS を処理する:

1. ユーザー作成時にサブドメインをインメモリに登録
2. シンプルな DNS レスポンダーを実装、または PowerDNS の pipe バックエンドを使用
3. NXDOMAIN を高速に返すことが重要（存在しないサブドメインのクエリが大量にくる場合）

## 対策 4: DNS 応答の TTL 設定

ベンチマーカーが TTL に従ってキャッシュする場合、適切な TTL を設定することでクエリ数を削減:

```bash
# 現在の DNS 設定を確認
dig pipe.u.isucon.dev @127.0.0.1 +short

# TTL を確認
dig pipe.u.isucon.dev @127.0.0.1 | grep -A1 'ANSWER SECTION'
```

## 検証

```bash
# DNS 解決速度のベンチマーク
time for i in $(seq 1 100); do dig +short test$i.u.isucon.dev @127.0.0.1 > /dev/null; done
```

## 効果

- インデックス + キャッシュで DNS クエリ時間を大幅削減
- アプリケーションレベル DNS で MySQL オーバーヘッドを完全に排除
