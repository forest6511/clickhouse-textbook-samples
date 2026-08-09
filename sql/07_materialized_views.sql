-- 第7章 集計を速くする — マテリアライズドビュー
--
-- 前提: 01_clickhouse_setup.sql を流して trips（500万行）がある状態
--
-- 実行:
--   docker exec -i ch clickhouse-client --multiquery < sql/07_materialized_views.sql
--
-- 🔴 注意: 本章の実験は trips に書き込まない。
--    7-3 節だけは MV の反応を見るために trips へ 3 行入れるが、
--    そのあと必ず 01_clickhouse_setup.sql を流し直して 500 万行に戻すこと。
--    （第1〜3章の基準値 500 万行 / 55.66 MiB / 616 マークが崩れるため）

-- ============================================================
-- 7-2 集計先テーブルとマテリアライズドビュー
-- ============================================================

DROP VIEW IF EXISTS mv_daily;
DROP TABLE IF EXISTS daily_stats;

CREATE TABLE daily_stats (
    day          Date,
    payment_type LowCardinality(String),
    trips        UInt64,
    amount_total Float64
) ENGINE = SummingMergeTree
ORDER BY (day, payment_type);

CREATE MATERIALIZED VIEW mv_daily TO daily_stats AS
SELECT toDate(pickup_datetime) AS day,
       payment_type,
       count()           AS trips,
       sum(total_amount) AS amount_total
FROM trips
GROUP BY day, payment_type;

-- 作成直後は 0 件（既存データは入らない）
SELECT count() FROM daily_stats;

-- ============================================================
-- 7-4 既存データを後から流し込む
-- ============================================================

-- 二重計上を避けるため、必ず空にしてから流し込む
TRUNCATE TABLE daily_stats;

INSERT INTO daily_stats
SELECT toDate(pickup_datetime) AS day,
       payment_type,
       count()           AS trips,
       sum(total_amount) AS amount_total
FROM trips
GROUP BY day, payment_type;

SELECT count() FROM daily_stats;   -- 540

-- ============================================================
-- 7-5 読む量を比べる
-- ============================================================

SELECT /* bench_raw */ toDate(pickup_datetime) AS day, payment_type,
       count(), sum(total_amount)
FROM trips GROUP BY day, payment_type FORMAT Null;

SELECT /* bench_mv */ day, payment_type, sum(trips), sum(amount_total)
FROM daily_stats GROUP BY day, payment_type FORMAT Null;

SYSTEM FLUSH LOGS;

SELECT multiIf(query LIKE '%bench_raw%', '生テーブル', 'MV 経由') AS route,
       read_rows,
       formatReadableSize(read_bytes) AS read_bytes,
       query_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND (query LIKE '%bench_raw%' OR query LIKE '%bench_mv%')
  AND query NOT LIKE '%system.query_log%'
ORDER BY event_time DESC LIMIT 6;

-- ============================================================
-- 7-6 平均や一意数を持つ
-- ============================================================

-- 件数が日によって 100 倍違うデータ（平均の平均が誤ることを示す）
DROP TABLE IF EXISTS skew_src;
DROP TABLE IF EXISTS skew_naive;

CREATE TABLE skew_src (pickup_datetime DateTime, total_amount Float32)
ENGINE = MergeTree ORDER BY pickup_datetime;

-- 1日1000件・金額10 の日を10日ぶん
INSERT INTO skew_src
SELECT toDateTime('2026-01-01 00:00:00') + INTERVAL intDiv(number, 1000) DAY,
       10.0
FROM numbers(10000);

-- 1日10件・金額50 の日を5日ぶん
INSERT INTO skew_src
SELECT toDateTime('2026-01-11 00:00:00') + INTERVAL intDiv(number, 10) DAY,
       50.0
FROM numbers(50);

-- 正しい全体の平均: 10.199
SELECT count() AS rows, round(avg(total_amount), 4) AS correct_avg FROM skew_src;

-- 誤り: 日ごとの平均を単純平均 → 23.3333
CREATE TABLE skew_naive (day Date, avg_amount Float64)
ENGINE = MergeTree ORDER BY day;

INSERT INTO skew_naive
SELECT toDate(pickup_datetime), avg(total_amount)
FROM skew_src GROUP BY 1;

SELECT round(avg(avg_amount), 4) AS naive_avg FROM skew_naive;

-- AggregatingMergeTree で途中経過を持つ
DROP VIEW IF EXISTS mv_daily_agg;
DROP TABLE IF EXISTS daily_agg;

CREATE TABLE daily_agg (
    day          Date,
    payment_type LowCardinality(String),
    avg_amount   AggregateFunction(avg, Float32),
    uniq_dist    AggregateFunction(uniq, Float32)
) ENGINE = AggregatingMergeTree
ORDER BY (day, payment_type);

CREATE MATERIALIZED VIEW mv_daily_agg TO daily_agg AS
SELECT toDate(pickup_datetime) AS day,
       payment_type,
       avgState(total_amount)   AS avg_amount,
       uniqState(trip_distance) AS uniq_dist
FROM trips
GROUP BY day, payment_type;

-- 既存データを流し込む
INSERT INTO daily_agg
SELECT toDate(pickup_datetime) AS day, payment_type,
       avgState(total_amount), uniqState(trip_distance)
FROM trips GROUP BY day, payment_type;

-- 読むときは Merge を付ける（10.33 / 18.13 / 30.48、350 / 750 / 1600）
SELECT payment_type,
       round(avgMerge(avg_amount), 2) AS avg_fare,
       uniqMerge(uniq_dist)           AS uniq_distances
FROM daily_agg
GROUP BY payment_type ORDER BY avg_fare;

-- Merge を付け忘れると中間状態がそのまま出る（エラーにならない）
SELECT payment_type, avg_amount FROM daily_agg LIMIT 2;

-- ============================================================
-- 7-7 書くときのコストを測る
-- ============================================================

DROP TABLE IF EXISTS src_mv;
DROP VIEW IF EXISTS mvx_1; DROP TABLE IF EXISTS agg_1;
DROP VIEW IF EXISTS mvx_2; DROP TABLE IF EXISTS agg_2;
DROP VIEW IF EXISTS mvx_3; DROP TABLE IF EXISTS agg_3;

CREATE TABLE src_mv (
    pickup_datetime DateTime,
    payment_type    LowCardinality(String),
    total_amount    Float32
) ENGINE = MergeTree ORDER BY pickup_datetime;

-- MV 0 本で測る（0.132 / 0.130 秒）
INSERT INTO src_mv
SELECT pickup_datetime, payment_type, total_amount FROM trips LIMIT 3000000;

-- MV を 3 本足す（agg_2 / mvx_2、agg_3 / mvx_3 も同様に作る）
CREATE TABLE agg_1 (
    day Date, payment_type LowCardinality(String),
    trips UInt64, amt Float64
) ENGINE = SummingMergeTree ORDER BY (day, payment_type);

CREATE MATERIALIZED VIEW mvx_1 TO agg_1 AS
SELECT toDate(pickup_datetime) AS day, payment_type,
       count() AS trips, sum(total_amount) AS amt
FROM src_mv GROUP BY day, payment_type;

-- MV 3 本で測り直す（0.334 / 0.308 秒 = 約 2.4 倍）
TRUNCATE TABLE src_mv;
INSERT INTO src_mv
SELECT pickup_datetime, payment_type, total_amount FROM trips LIMIT 3000000;

-- ============================================================
-- 7-8 TTL で生データだけ消す
-- ============================================================

DROP TABLE IF EXISTS raw_ttl;

CREATE TABLE raw_ttl (
    pickup_datetime DateTime,
    payment_type    LowCardinality(String),
    total_amount    Float32
) ENGINE = MergeTree
ORDER BY pickup_datetime
TTL pickup_datetime + INTERVAL 90 DAY;

-- マージを止めると 1 行も消えない（TTL の契機はマージであることの証明）
SYSTEM STOP MERGES raw_ttl;

INSERT INTO raw_ttl
SELECT pickup_datetime, payment_type, total_amount FROM trips;

SELECT count() AS rows, min(pickup_datetime) AS oldest FROM raw_ttl;  -- 5000000

SELECT name, level, rows FROM system.parts
WHERE table = 'raw_ttl' AND active ORDER BY name;                     -- level はすべて 0

-- マージを再開すると 90 日より古い行が消える
SYSTEM START MERGES raw_ttl;
OPTIMIZE TABLE raw_ttl FINAL;

SELECT count() AS rows, min(pickup_datetime) AS oldest,
       max(pickup_datetime) AS newest
FROM raw_ttl;

SELECT name, level, delete_ttl_info_min, delete_ttl_info_max, rows
FROM system.parts WHERE table = 'raw_ttl' AND active;

-- 集計先は TTL の影響を受けない（2026-01-01 からのぶんが残る）
SELECT count() AS rows, min(day) AS oldest, max(day) AS newest
FROM daily_stats;
