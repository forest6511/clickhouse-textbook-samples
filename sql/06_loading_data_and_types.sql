-- 第6章「データを入れる — 型の選び方と取り込み」の検証用テーブル
--
-- 前提: 01_clickhouse_setup.sql で trips(500万行) が作られていること。
-- 実行方法:
--   docker exec -i ch clickhouse-client --multiquery < sql/06_loading_data_and_types.sql
--
-- 注意: 列ごとの大きさ(system.parts_columns)は Compact パートでは記録されないため、
--       投入後に OPTIMIZE TABLE ... FINAL を打ってから計測する。

-- 6-1 型の幅を測る -----------------------------------------------------------
DROP TABLE IF EXISTS w_u8;
DROP TABLE IF EXISTS w_u32;
DROP TABLE IF EXISTS w_u64;

CREATE TABLE w_u8  (pickup_datetime DateTime, passenger_count UInt8)
ENGINE = MergeTree ORDER BY pickup_datetime;

CREATE TABLE w_u32 (pickup_datetime DateTime, passenger_count UInt32)
ENGINE = MergeTree ORDER BY pickup_datetime;

CREATE TABLE w_u64 (pickup_datetime DateTime, passenger_count UInt64)
ENGINE = MergeTree ORDER BY pickup_datetime;

INSERT INTO w_u8  SELECT pickup_datetime, passenger_count FROM trips;
INSERT INTO w_u32 SELECT pickup_datetime, passenger_count FROM trips;
INSERT INTO w_u64 SELECT pickup_datetime, passenger_count FROM trips;

OPTIMIZE TABLE w_u8  FINAL;
OPTIMIZE TABLE w_u32 FINAL;
OPTIMIZE TABLE w_u64 FINAL;

-- 6-2 Nullable を避ける理由 --------------------------------------------------
DROP TABLE IF EXISTS n_plain;
DROP TABLE IF EXISTS n_null;
DROP TABLE IF EXISTS n_wide;

CREATE TABLE n_plain (pickup_datetime DateTime, passenger_count UInt8)
ENGINE = MergeTree ORDER BY pickup_datetime;

CREATE TABLE n_null (pickup_datetime DateTime,
                     passenger_count Nullable(UInt8))
ENGINE = MergeTree ORDER BY pickup_datetime;

INSERT INTO n_plain SELECT pickup_datetime, passenger_count FROM trips;
INSERT INTO n_null  SELECT pickup_datetime, passenger_count FROM trips;

OPTIMIZE TABLE n_plain FINAL;
OPTIMIZE TABLE n_null  FINAL;

-- Wide 形式を強制する(列ごとにファイルが分かれる様子を見るため)
CREATE TABLE n_wide (pickup_datetime DateTime,
                     passenger_count Nullable(UInt8))
ENGINE = MergeTree ORDER BY pickup_datetime
SETTINGS min_bytes_for_wide_part = 0;

INSERT INTO n_wide SELECT pickup_datetime, passenger_count FROM trips;

-- 6-4 ファイルから取り込む ---------------------------------------------------
-- trips_sample.csv / trips_sample.parquet は user_files に書き出しておく。
--   INSERT INTO FUNCTION file('trips_sample.csv', CSVWithNames)
--   SELECT * FROM trips LIMIT 100000;
DROP TABLE IF EXISTS trips_from_csv;

CREATE TABLE trips_from_csv (
    pickup_datetime DateTime,
    passenger_count UInt8,
    trip_distance   Float32,
    total_amount    Float32,
    payment_type    LowCardinality(String)
) ENGINE = MergeTree ORDER BY pickup_datetime;

-- 6-5 取り込みエラーを無視しない ---------------------------------------------
-- bad.csv は user_files に置く(8 データ行のうち 6 行目が notanumber)。
DROP TABLE IF EXISTS ingest_demo;

CREATE TABLE ingest_demo (
    pickup_datetime DateTime,
    passenger_count UInt8,
    trip_distance   Float32,
    total_amount    Float32,
    payment_type    LowCardinality(String)
) ENGINE = MergeTree ORDER BY pickup_datetime;

-- 6-7 大量のデータを入れる ---------------------------------------------------
DROP TABLE IF EXISTS batch_demo;

CREATE TABLE batch_demo (id UInt32, v UInt32)
ENGINE = MergeTree ORDER BY id;
