-- PostgreSQL: 同一条件のテーブルと500万行の生成
--
-- ClickHouse 側(01_clickhouse_setup.sql)と同じ分布になるように作る。
-- 分布が違うと「同じデータに同じクエリ」という比較の前提が崩れるため、
-- 支払い方法ごとの距離レンジ・運賃の計算式を必ず一致させること。
--     Cash   … 0.5〜4.0 km  (近距離)
--     Card   … 2.0〜18.0 km (中〜長距離)
--     Wallet … 1.5〜9.0 km  (中距離)
--   運賃 = 3.0 + 距離 × 2.6 + 端数(0〜3)
-- 🔴 何度流しても同じ状態に戻るよう、必ず DROP してから作り直す。
--    CREATE TABLE IF NOT EXISTS + 無条件 INSERT にしていると、
--    流し直すたびに 500 万行が「追記」され、行数もサイズも倍になる
--    （実際に 10,000,000 行 / 575 MB になっている状態を検出した。2026-08-10）。
--    第1・3章が 5,000,000 行 / 287 MB を基準値として参照しているため、
--    ここが壊れると比較そのものが成立しなくなる。
DROP TABLE IF EXISTS trips;

CREATE TABLE trips (
    pickup_datetime timestamp,
    passenger_count smallint,
    trip_distance   real,
    total_amount    real,
    payment_type    text
);

INSERT INTO trips
SELECT pickup_datetime,
       passenger_count,
       dist AS trip_distance,
       round((3.0 + dist * 2.6 + random() * 3)::numeric, 2)::real AS total_amount,
       ptype AS payment_type
FROM (
    SELECT timestamp '2026-01-01' + (random() * 86400 * 180) * interval '1 sec' AS pickup_datetime,
           1 + (random() * 4)::int AS passenger_count,
           ptype,
           CASE ptype
               WHEN 'Cash' THEN round((0.5 + random() * 3.5)::numeric, 2)::real
               WHEN 'Card' THEN round((2.0 + random() * 16.0)::numeric, 2)::real
               ELSE             round((1.5 + random() * 7.5)::numeric, 2)::real
           END AS dist
    FROM (
        -- floor() を使う。(random() * 2.999)::int は四捨五入で 3 になり得るため、
        -- 配列の範囲外(4番目)を参照して NULL が混入する。
        SELECT (ARRAY['Cash','Card','Wallet'])[1 + floor(random() * 3)::int] AS ptype
        FROM generate_series(1, 5000000)
    ) s
) t;

VACUUM ANALYZE trips;
