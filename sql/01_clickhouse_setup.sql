-- ClickHouse: 検証用テーブルと500万行の生成
--
-- 🔴 trips は全章共通の基準テーブル。第1〜3章が
--    「500万行 / 55.66 MiB / 5パーツ / 616マーク / 圧縮率 1.81〜1.00」を
--    "環境で変わらない値" として引用している。
--    **章の実験で trips に INSERT / ALTER しないこと。** 章専用のテーブルを作る。
--    やむを得ず書き込んだ場合は、このファイルを流し直して復元する:
--      docker exec -i ch clickhouse-client --multiquery < sql/01_clickhouse_setup.sql
--    ただし乱数で作り直すため、平均運賃・一意数・件数内訳は元の値に戻らない
--    （構造値だけが再現する）。実測値を引用している章は再確認が必要になる。
--
--    ディスクサイズも厳密には固定ではない。10 回作り直して実測すると
--    58,357,268〜58,366,844 バイト = **55.65〜55.66 MiB**（10 回中 9 回が 55.66）。
--    本書は代表値として 55.66 MiB を採用している。1 バイト単位で一致する値では
--    ないため、55.65 や 55.67 と表示されても異常ではない。
--    完全に固定なのは 5 パーツ / 5,000,000 行 / 616 マークの構造値のほう。
--
-- データ設計の意図:
--   支払い方法ごとに「距離の傾向」を変え、集計結果に意味が出るようにしている。
--   完全な乱数だと平均運賃が全種類で同じ値になり、集計しても何も分からないため。
--     Cash   … 近距離が多い(繁華街での短時間利用)          → 平均運賃が安い
--     Card   … 中〜長距離が多い                             → 平均運賃が高い
--     Wallet … 中距離中心(アプリ配車)                       → その中間
--   運賃は「基本料金 + 距離 × 単価」に揺らぎを足して算出する。
--   これにより第1章の「圧縮が効く列・効かない列」も自然な形で観察できる。
-- 🔴 DROP してから作り直す。
--    以前は CREATE TABLE IF NOT EXISTS + INSERT だったため、復元のつもりで
--    このファイルを流し直すと 500 万行が「追加」され、trips が 1000 万行・
--    107 MiB に倍増していた（基準値がすべて壊れる）。復元手順が壊す側に
--    回っていたので、何度流しても同じ状態になる形に直した。
DROP TABLE IF EXISTS trips;

CREATE TABLE trips (
    pickup_datetime DateTime,
    passenger_count UInt8,
    trip_distance   Float32,
    total_amount    Float32,
    payment_type    LowCardinality(String)
) ENGINE = MergeTree
ORDER BY pickup_datetime;

INSERT INTO trips
SELECT
    toDateTime('2026-01-01 00:00:00') + rand() % (86400 * 180) AS pickup_datetime,
    1 + rand(1) % 5                                            AS passenger_count,
    dist                                                       AS trip_distance,
    -- 基本料金 3.0 + 距離 × 単価 2.6 + 端数(0〜3)
    round(3.0 + dist * 2.6 + (rand(3) % 300) / 100.0, 2)       AS total_amount,
    ptype                                                      AS payment_type
FROM
(
    SELECT
        ['Cash', 'Card', 'Wallet'][1 + rand(4) % 3] AS ptype,
        -- 支払い方法ごとに距離の分布を変える
        multiIf(
            ptype = 'Cash',   round(0.5 + (rand(5) % 350) / 100.0, 2),   -- 0.5〜4.0 km
            ptype = 'Card',   round(2.0 + (rand(5) % 1600) / 100.0, 2),  -- 2.0〜18.0 km
                              round(1.5 + (rand(5) % 750) / 100.0, 2)    -- 1.5〜9.0 km
        ) AS dist
    FROM numbers(5000000)
);
