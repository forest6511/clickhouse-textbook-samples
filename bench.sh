#!/usr/bin/env bash
# ClickHouse と PostgreSQL に同じ集計を投げて実測する。
# 前提: docker compose up -d 済み
set -euo pipefail

echo "=== バージョン ==="
docker exec ch clickhouse-client --query "SELECT 'ClickHouse ' || version()"
docker exec pg psql -U ch -d chbench -tAc "SELECT 'PostgreSQL ' || current_setting('server_version');"

echo
echo "=== 同一クエリ: payment_type 別の件数と平均運賃 (500万行) ==="
echo "--- ClickHouse"
# 並び順は本文（第3章 リスト 3-5 / 3-6）と揃えて avg_fare 昇順にする。
# 支払い方法ごとの平均運賃の差が読み取りやすくなるため。
docker exec ch clickhouse-client --time --query "
SELECT payment_type, count() AS trips, round(avg(total_amount),2) AS avg_fare
FROM trips GROUP BY payment_type ORDER BY avg_fare FORMAT PrettyCompact"

echo "--- PostgreSQL"
docker exec pg psql -U ch -d chbench -c "\timing on" -c "
SELECT payment_type, count(*) AS trips, round(avg(total_amount)::numeric,2) AS avg_fare
FROM trips GROUP BY payment_type ORDER BY avg_fare;"

echo
echo "=== ディスク使用量 ==="
docker exec ch clickhouse-client --query "
SELECT 'ClickHouse: ' || formatReadableSize(sum(bytes_on_disk))
FROM system.parts WHERE table='trips' AND active"
docker exec pg psql -U ch -d chbench -tAc "
SELECT 'PostgreSQL: ' || pg_size_pretty(pg_total_relation_size('trips'));"
