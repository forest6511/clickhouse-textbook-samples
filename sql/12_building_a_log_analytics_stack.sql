-- 第12章 実践 — アクセスログ分析基盤を作る
--
-- 前提: docker compose up -d で ch と pg が起動していること
-- 実行: docker exec -i ch clickhouse-client --multiquery < sql/12_building_a_log_analytics_stack.sql
--
-- 🔴 基準テーブル trips には一切書き込まない。本章は access_log 系の
--    章専用テーブルだけを作って使う。

DROP VIEW IF EXISTS mv_access_1m;
DROP VIEW IF EXISTS mv_access_1d;
DROP TABLE IF EXISTS access_log;
DROP TABLE IF EXISTS access_1m;
DROP TABLE IF EXISTS access_1d;
DROP TABLE IF EXISTS access_1d_q;
DROP TABLE IF EXISTS access_ttl_demo;

-- ============================================================
-- 12-3 生ログ用テーブルを設計する
-- 12-4 ORDER BY と PARTITION BY を決める
-- 12-5 型を絞る
-- ============================================================

CREATE TABLE access_log (
    ts        DateTime,
    host      LowCardinality(String),
    path      LowCardinality(String),
    method    LowCardinality(String),
    status    UInt16,
    duration_ms UInt32,
    user_id   UInt32,
    bytes     UInt32
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (path, ts);

-- ============================================================
-- 12-6 サンプルログを生成して投入する
--   3,000 万行 / 30 日分。
--   status は 200 が大半、5xx が少数混じるように偏らせる。
--   duration_ms は path ごとに分布を変えて、分位数に差が出るようにする。
-- ============================================================

INSERT INTO access_log
SELECT
    -- 30,000,000 行を 1 秒あたり 12 行で並べると約 29 日分になる
    toDateTime('2026-07-01 00:00:00') + intDiv(number, 12)   AS ts,
    ['web01','web02','web03'][number % 3 + 1]               AS host,
    p                                                        AS path,
    if(p = '/api/checkout', 'POST', 'GET')                   AS method,
    -- 200 が約 96%、404 が約 2%、500 が約 1.5%、503 が約 0.5%
    multiIf(r <  960, 200,
            r <  980, 404,
            r <  995, 500,
                      503)                                   AS status,
    -- path ごとに応答時間の分布を変える(checkout が重く、静的ファイルが軽い)
    toUInt32(multiIf(p = '/api/checkout', 120 + rand(3) % 900,
                     p = '/api/search',    40 + rand(4) % 300,
                     p = '/static/app.js',  2 + rand(9) %  15,
                     p = '/',               5 + rand(5) %  40,
                                           10 + rand(6) % 120)) AS duration_ms,
    rand(7) % 50000                                          AS user_id,
    500 + rand(8) % 40000                                    AS bytes
FROM (
    SELECT
        number,
        ['/', '/api/search', '/api/checkout', '/static/app.js', '/health']
            [number % 5 + 1] AS p,
        rand(2) % 1000 AS r
    FROM numbers(30000000)
);

-- 投入結果の確認
SELECT count() AS rows, min(ts) AS from_ts, max(ts) AS to_ts FROM access_log;

SELECT
    formatReadableSize(sum(bytes_on_disk)) AS on_disk,
    count()                                AS parts
FROM system.parts
WHERE table = 'access_log' AND active;

-- ============================================================
-- 12-7 1分単位の集計 MV
-- ============================================================

CREATE TABLE access_1m (
    minute      DateTime,
    path        LowCardinality(String),
    status      UInt16,
    -- 🔴 生の UInt64 は AggregatingMergeTree に拒否される(Code: 36)。
    --    マージで ORDER BY が同じ行がまとまるとき、どちらの値を残すか決まらないため。
    hits        SimpleAggregateFunction(sum, UInt64),
    dur_total   SimpleAggregateFunction(sum, UInt64),
    dur_state   AggregateFunction(quantile(0.95), UInt32),
    users_state AggregateFunction(uniq, UInt32)
)
ENGINE = AggregatingMergeTree
ORDER BY (path, minute, status);

CREATE MATERIALIZED VIEW mv_access_1m TO access_1m AS
SELECT
    toStartOfMinute(ts)              AS minute,
    path,
    status,
    count()                          AS hits,
    sum(duration_ms)                 AS dur_total,
    quantileState(0.95)(duration_ms) AS dur_state,
    uniqState(user_id)               AS users_state
FROM access_log
GROUP BY minute, path, status;

-- 既存データを流し込む(作成直後は空のため)
INSERT INTO access_1m
SELECT
    toStartOfMinute(ts), path, status,
    count(), sum(duration_ms),
    quantileState(0.95)(duration_ms), uniqState(user_id)
FROM access_log
GROUP BY 1, 2, 3;

SELECT count() FROM access_1m;

-- ============================================================
-- 12-8 1日単位の集計 MV(1分集計をさらに畳む)
-- ============================================================

CREATE TABLE access_1d (
    day         Date,
    path        LowCardinality(String),
    status      UInt16,
    hits        UInt64,
    dur_total   UInt64
)
ENGINE = SummingMergeTree
ORDER BY (day, path, status);

CREATE MATERIALIZED VIEW mv_access_1d TO access_1d AS
SELECT
    toDate(ts)       AS day,
    path,
    status,
    count()          AS hits,
    sum(duration_ms) AS dur_total
FROM access_log
GROUP BY day, path, status;

INSERT INTO access_1d
SELECT toDate(ts), path, status, count(), sum(duration_ms)
FROM access_log GROUP BY 1, 2, 3;

SELECT count() FROM access_1d;

-- ============================================================
-- 12-9 エラー率
-- ============================================================

-- 生ログから
SELECT
    day,
    sum(hits)                                        AS total,
    sum(if(status >= 500, hits, 0))                  AS errors,
    round(sum(if(status >= 500, hits, 0)) / sum(hits) * 100, 3) AS error_pct
FROM access_1d
GROUP BY day
ORDER BY day
LIMIT 5;

-- ============================================================
-- 12-10 分位数
-- ============================================================

SELECT
    path,
    round(quantile(0.50)(duration_ms)) AS p50,
    round(quantile(0.95)(duration_ms)) AS p95,
    round(quantile(0.99)(duration_ms)) AS p99
FROM access_log
GROUP BY path
ORDER BY p95 DESC;

-- 集計済みから(quantileMerge)
SELECT
    path,
    round(quantileMerge(0.95)(dur_state)) AS p95
FROM access_1m
GROUP BY path
ORDER BY p95 DESC;

-- 正確な分位数
SELECT round(quantileExact(0.95)(duration_ms)) AS p95_exact FROM access_log;
SELECT round(quantile(0.95)(duration_ms))      AS p95_approx FROM access_log;

-- ============================================================
-- 12-6節の解決: 粒度を日次に落とした集計テーブル
--   1分粒度(access_1m)は状態が重く、生ログより遅くなる。
--   問い合わせの粒度(パスごとの p95)に合わせて日次で持ち直す。
-- ============================================================

DROP TABLE IF EXISTS access_1d_q;
CREATE TABLE access_1d_q (
    day         Date,
    path        LowCardinality(String),
    hits        SimpleAggregateFunction(sum, UInt64),
    dur_state   AggregateFunction(quantile(0.95), UInt32),
    users_state AggregateFunction(uniq, UInt32)
)
ENGINE = AggregatingMergeTree
ORDER BY (path, day);

INSERT INTO access_1d_q
SELECT toDate(ts), path, count(),
       quantileState(0.95)(duration_ms), uniqState(user_id)
FROM access_log
GROUP BY 1, 2;

SELECT count() FROM access_1d_q;   -- 145

SELECT path, round(quantileMerge(0.95)(dur_state)) AS p95
FROM access_1d_q
GROUP BY path
ORDER BY p95 DESC;

-- 読んだ量を 3 者で比べる(SYSTEM FLUSH LOGS のあと)
SYSTEM FLUSH LOGS;
SELECT
    if(query LIKE '%quantileMerge%', 'MV', 'raw') AS src,
    read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    query_duration_ms AS ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 5 MINUTE
  AND (query LIKE '%quantile(0.95)(duration_ms) FROM access_log%'
       OR query LIKE '%quantileMerge(0.95)(dur_state) FROM access_1m%')
ORDER BY event_time DESC
LIMIT 4;

-- ============================================================
-- 12-12 上位パスのランキング
-- ============================================================

-- 🔴 別名 hits が元の列名と衝突し Code: 184 になる。total_hits に変える。
SELECT path,
       sum(hits) AS total_hits,
       round(sum(dur_total) / sum(hits), 1) AS avg_ms
FROM access_1d
GROUP BY path
ORDER BY total_hits DESC;

-- ============================================================
-- 12-13 / 12-14 uniq と uniqExact
-- ============================================================

-- user_id は一意 50,000 しかないため、uniq でも正確な値が返り差が出ない
-- (uniq の状態はハッシュ値のサンプルを最大 65,536 個保持するため)
SELECT uniq(user_id)      AS approx FROM access_log;   -- 50000
SELECT uniqExact(user_id) AS exact  FROM access_log;   -- 50000

-- カーディナリティを上げる(約 2,900 万種類)と近似の性質が見える
SELECT
    uniq(user_id * 7919 + bytes)      AS approx,
    uniqExact(user_id * 7919 + bytes) AS exact,
    round((uniq(user_id * 7919 + bytes)
           - uniqExact(user_id * 7919 + bytes))
          / uniqExact(user_id * 7919 + bytes) * 100, 3) AS err_pct
FROM access_log;

-- ピークメモリの差(約 220 倍)を確認する
SYSTEM FLUSH LOGS;
SELECT
    if(query LIKE '%uniqExact%', 'uniqExact', 'uniq') AS fn,
    formatReadableSize(memory_usage) AS peak_memory,
    query_duration_ms AS ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 3 MINUTE
  AND query LIKE '%user_id * 7919%'
ORDER BY event_time DESC
LIMIT 4;

-- 集計済みから
SELECT uniqMerge(users_state) AS approx_from_mv FROM access_1m;

-- ============================================================
-- 12-15 生ログに TTL を設定する
-- ============================================================

-- 🔴 これを流すと access_log の 30,000,000 行が全部消える。
--    生成データは 2026-07 で、実行日から見て 7 日を超えているため。
--    TTL は「テーブルに入ってからの経過時間」ではなく
--    「指定した列の値と現在時刻の差」で判定される。
--    ALTER TABLE access_log MODIFY TTL ts + INTERVAL 7 DAY;

-- 動きの確認は now() 相対の小さな専用テーブルで行う
DROP TABLE IF EXISTS access_ttl_demo;
CREATE TABLE access_ttl_demo (ts DateTime, path String)
ENGINE = MergeTree
ORDER BY ts
TTL ts + INTERVAL 7 DAY;

INSERT INTO access_ttl_demo VALUES
  (now() - INTERVAL 1 DAY,  '/recent'),
  (now() - INTERVAL 3 DAY,  '/recent'),
  (now() - INTERVAL 10 DAY, '/old'),
  (now() - INTERVAL 30 DAY, '/old');

-- 入れた直後に /old は既に無い(4 行入れて 2 行)。
-- ただし削除はマージの契機で起きるため、投入直後に読むと
-- まだ /old が見えることがある。数秒おくか OPTIMIZE ... FINAL を打つ。
SELECT path, count() AS c FROM access_ttl_demo GROUP BY path ORDER BY path;

-- ============================================================
-- 12-17 PostgreSQL で同じ集計を書いたときと比べる
--   (bench.sh 側 / 手動で pg に流す)
-- ============================================================

-- ============================================================
-- 12-19 同時アクセスが増えたときの設定
-- ============================================================

SELECT getSetting('max_threads') AS max_threads;

SELECT name, value FROM system.server_settings
WHERE name IN ('max_concurrent_queries', 'background_pool_size');

-- クエリキャッシュ
SELECT count() FROM access_1d SETTINGS use_query_cache = 1;

SELECT name, value FROM system.settings
WHERE name IN ('use_query_cache', 'query_cache_ttl', 'query_cache_min_query_runs');

-- ============================================================
-- 12-20 片付け
-- ============================================================

-- DROP VIEW IF EXISTS mv_access_1m;
-- DROP VIEW IF EXISTS mv_access_1d;
-- DROP TABLE IF EXISTS access_log;
-- DROP TABLE IF EXISTS access_1m;
-- DROP TABLE IF EXISTS access_1d;
-- DROP TABLE IF EXISTS access_1d_q;
-- DROP TABLE IF EXISTS access_ttl_demo;
