-- 第11章 どれを選ぶか（PostgreSQL との併用）
--
-- 単一ノード環境（docker-compose.yml の ch / pg）で実行する。
--   docker exec -i ch clickhouse-client < sql/11_choosing_the_right_tool.sql
--
-- 前提: 02_postgres_setup.sql を流して pg 側に trips（500 万行）があること。
--
-- 🔴 基準テーブル trips には書き込まない（SELECT のみ）。
--    検証用に作る trips_from_pg は最後に DROP する。

-- ---------------------------------------------------------------------------
-- 11-2 1 件を書き換えようとする（リスト 11-1）
-- 既定では UPDATE 文は Code: 48 (NOT_IMPLEMENTED) で拒否される。
-- 書き換えるなら ALTER TABLE ... UPDATE（パーツを書き直す処理）を使う。
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS upd_demo SYNC;

CREATE TABLE upd_demo (id UInt32, v String)
ENGINE = MergeTree
ORDER BY id;

INSERT INTO upd_demo SELECT number, 'x' FROM numbers(1000);

-- これは失敗する（本文リスト 11-1 の出力）
-- UPDATE upd_demo SET v = 'y' WHERE id = 1;

-- こちらは通る
ALTER TABLE upd_demo UPDATE v = 'z' WHERE id = 2;

DROP TABLE IF EXISTS upd_demo SYNC;

-- ---------------------------------------------------------------------------
-- 11-6 参照する（リスト 11-2）
-- PostgreSQL のテーブルを、写さずにそのまま集計する
-- ---------------------------------------------------------------------------
SELECT payment_type, count() AS trips, round(avg(total_amount), 2) AS avg_fare
FROM postgresql('pg:5432', 'chbench', 'trips', 'ch', 'ch')
GROUP BY payment_type
ORDER BY avg_fare;

-- ---------------------------------------------------------------------------
-- 11-6 写す（リスト 11-4）
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS trips_from_pg SYNC;

CREATE TABLE trips_from_pg
(
    pickup_datetime DateTime,
    passenger_count UInt8,
    trip_distance   Float32,
    total_amount    Float32,
    payment_type    LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY pickup_datetime;

INSERT INTO trips_from_pg
SELECT * FROM postgresql('pg:5432', 'chbench', 'trips', 'ch', 'ch');

SELECT count() AS rows FROM trips_from_pg;

-- 写したあとのディスク使用量（PostgreSQL 側の 287 MB と比べる）
SELECT formatReadableSize(sum(bytes_on_disk)) AS disk
FROM system.parts WHERE active AND table = 'trips_from_pg';

-- 検証用テーブルなので片付ける
DROP TABLE IF EXISTS trips_from_pg SYNC;

-- ---------------------------------------------------------------------------
-- 11-8 導入判断のために測る 3 つ（読み込み量・ディスク）
-- 秒数は環境で変わるが、以下の 2 つは変わらない
-- ---------------------------------------------------------------------------
SELECT formatReadableSize(sum(bytes_on_disk)) AS clickhouse_disk
FROM system.parts WHERE active AND table = 'trips';

-- 直前のクエリが実際に読んだ量は query_log で確認する
--   SELECT read_rows, formatReadableSize(read_bytes), query_duration_ms
--   FROM system.query_log
--   WHERE type = 'QueryFinish' AND query LIKE '%trips%'
--   ORDER BY event_time DESC LIMIT 1;
