-- 第8章 ログとイベントを扱う — JSON / Dynamic 型
--
-- 前提: docker compose up -d で ch が起動していること
-- 実行: docker exec -i ch clickhouse-client --multiquery < sql/08_logs_and_json_types.sql
--
-- 🔴 このスクリプトは基準テーブル trips に一切書き込まない。
--    章専用のテーブル(logs_str / logs_json / logs_hint / ev_mixed / var_demo)だけを使う。

DROP TABLE IF EXISTS logs_str;
DROP TABLE IF EXISTS logs_json;
DROP TABLE IF EXISTS logs_hint;
DROP TABLE IF EXISTS ev_mixed;
DROP TABLE IF EXISTS var_demo;

-- ============================================================
-- 8-1 列が決まらないデータの置き場所(文字列方式)
-- ============================================================

-- リスト 8-1
CREATE TABLE logs_str
(
    ts   DateTime,
    body String
)
ENGINE = MergeTree
ORDER BY ts;

-- リスト 8-2
-- 時間帯でエラー率が変わるように作る(2〜4 時のバッチ時間帯に 500 が増える)。
-- 一律の乱数にすると 8-15 の「時間帯別エラー率」が全時間帯で同じ値になり、
-- 集計しても何も分からなくなるため。
INSERT INTO logs_str
SELECT
    ts,
    concat(
      '{"user_id":', toString(user_id),
      ',"path":"', path,
      '","status":', toString(status),
      ',"ms":', toString(ms),
      ',"ua":"', ua,
      '","cached":', if(cached, 'true', 'false'),
      '}'
    ) AS body
FROM (
  SELECT
      toDateTime('2026-01-01 00:00:00') + intDiv(number, 24) AS ts,
      number % 50000 AS user_id,
      ['/', '/search', '/items', '/cart', '/checkout'][(number % 5) + 1]
          AS path,
      multiIf(
          toHour(ts) BETWEEN 2 AND 4 AND (number % 5) < 2, 500,
          (number % 50) = 0, 404,
          (number % 97) = 0, 503,
          200
      ) AS status,
      10 + (number * 7919) % 400 AS ms,
      ['Chrome','Safari','Firefox','Edge'][(number % 4) + 1] AS ua,
      (number % 3) = 0 AS cached
  FROM numbers(2000000)
);

-- リスト 8-3
-- TSVRaw で出す。罫線テーブルだと 1 行が長すぎて狭い画面で読めないため。
SELECT body FROM logs_str LIMIT 3 FORMAT TSVRaw;

-- リスト 8-4
SELECT JSONExtractInt(body, 'status') AS status, count() AS c
FROM logs_str
GROUP BY status
ORDER BY status;

-- リスト 8-5  型が合わないキーは 0、存在しないキーは空文字列(エラーにならない)
SELECT
    JSONExtractInt(body, 'ua')           AS ua_as_int,
    JSONExtractString(body, 'nosuchkey') AS missing
FROM logs_str
LIMIT 3;

-- ============================================================
-- 8-2 JSON 型で受け取る
-- ============================================================

-- リスト 8-6
CREATE TABLE logs_json
(
    ts   DateTime,
    body JSON
)
ENGINE = MergeTree
ORDER BY ts;

-- リスト 8-7  比較を公平にするため、まったく同じ本文を入れる
INSERT INTO logs_json SELECT ts, body FROM logs_str;

OPTIMIZE TABLE logs_str FINAL;
OPTIMIZE TABLE logs_json FINAL;

-- リスト 8-8  実験設定は Obsolete(何もしない)になっている
SELECT name, value, tier
FROM system.settings
WHERE name IN (
    'allow_experimental_json_type',
    'allow_experimental_dynamic_type',
    'allow_experimental_variant_type'
);

-- リスト 8-9
SELECT JSONAllPathsWithTypes(body) FROM logs_json LIMIT 1 FORMAT Vertical;

-- ============================================================
-- 8-3 キーを取り出して集計する
-- ============================================================

-- リスト 8-10 はエラーになる例(Code: 44)。動作確認したい場合のみ手で実行する:
--   SELECT status, count() FROM logs_json GROUP BY body.status AS status;

-- リスト 8-11
SELECT body.status.:Int64 AS status, count() AS c
FROM logs_json
GROUP BY status
ORDER BY status;

-- リスト 8-12  文字列方式と違い NULL が返る
SELECT
    body.ua.:Int64 AS ua_as_int,
    body.nosuchkey AS missing
FROM logs_json
LIMIT 3;

-- リスト 8-13
SELECT
    body.path.:String             AS path,
    count()                       AS reqs,
    round(avg(body.ms.:Int64), 1) AS avg_ms
FROM logs_json
GROUP BY path
ORDER BY reqs DESC;

-- リスト 8-14
SELECT body.path.:String AS path, count() AS c
FROM logs_json
WHERE body.user_id.:Int64 = 42
GROUP BY path
ORDER BY path;

-- リスト 8-15
SELECT
    toHour(ts)                         AS hour,
    count()                            AS total,
    countIf(body.status.:Int64 >= 500) AS errors,
    round(errors / total * 100, 2)     AS error_pct
FROM logs_json
GROUP BY hour
ORDER BY hour
LIMIT 6;

-- ============================================================
-- 8-5 どれだけ違うのか
-- ============================================================

-- リスト 8-18
SELECT
    table,
    formatReadableSize(sum(bytes_on_disk)) AS disk,
    sum(rows)                              AS rows
FROM system.parts
WHERE table IN ('logs_str', 'logs_json') AND active
GROUP BY table
ORDER BY table;

-- リスト 8-19 の前に、比較対象の 2 クエリを実行しておく
SELECT body.status.:Int64 AS s, count() FROM logs_json GROUP BY s FORMAT Null;
SELECT JSONExtractInt(body, 'status') AS s, count() FROM logs_str GROUP BY s FORMAT Null;
SYSTEM FLUSH LOGS;

-- リスト 8-19
SELECT
    if(query LIKE '%logs_json%', 'JSON 型', 'String + JSONExtract') AS method,
    formatReadableSize(read_bytes) AS read_bytes,
    round(query_duration_ms / 1000, 3) AS sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - 120
  AND (query LIKE '%FROM logs_json GROUP BY s%'
    OR query LIKE '%FROM logs_str GROUP BY s%')
  AND query NOT LIKE '%query_log%'
ORDER BY event_time DESC
LIMIT 2;

-- ============================================================
-- 8-6 同じキーに違う型が入ってくる場合
-- ============================================================

-- リスト 8-20
CREATE TABLE ev_mixed (ts DateTime, body JSON)
ENGINE = MergeTree ORDER BY ts;

-- ※ JSONEachRow の INSERT は clickhouse-client の対話モードか、
--    docker exec -i ch clickhouse-client --query "INSERT INTO ev_mixed FORMAT JSONEachRow" < data/ev_mixed.jsonl
--    で投入する。ここでは同じ内容を SQL で表現する。
INSERT INTO ev_mixed
SELECT toDateTime('2026-01-01 00:00:00') + 0, '{"event":"purchase","value":1980}'::JSON
UNION ALL
SELECT toDateTime('2026-01-01 00:00:00') + 1, '{"event":"search","value":"shoes"}'::JSON
UNION ALL
SELECT toDateTime('2026-01-01 00:00:00') + 2, '{"event":"rate","value":4.5}'::JSON
UNION ALL
SELECT toDateTime('2026-01-01 00:00:00') + 3, '{"event":"toggle","value":true}'::JSON
UNION ALL
SELECT toDateTime('2026-01-01 00:00:00') + 4, '{"event":"tags","value":[1,2,3]}'::JSON;

-- リスト 8-21
SELECT
    body.event              AS event,
    body.value              AS value,
    dynamicType(body.value) AS type
FROM ev_mixed
ORDER BY ts;

-- リスト 8-22
SELECT
    body.event         AS event,
    body.value.:Int64  AS as_int,
    body.value.:String AS as_str
FROM ev_mixed
ORDER BY ts;

-- リスト 8-23  :: はリテラルを文字列として渡すため String になる
SELECT
    dynamicType(42::Dynamic)              AS with_colons,
    dynamicType(CAST(42, 'Dynamic'))      AS with_cast,
    dynamicType(materialize(42)::Dynamic) AS with_materialize;

-- リスト 8-24
EXPLAIN SYNTAX SELECT 42::Dynamic;

-- リスト 8-25
CREATE TABLE var_demo (v Variant(UInt64, String, Array(UInt64)))
ENGINE = Memory;

INSERT INTO var_demo VALUES (42), ('hello'), ([1,2,3]), (NULL);

SELECT v, variantType(v) AS type, v.UInt64 AS as_uint, v.String AS as_str
FROM var_demo;

-- ============================================================
-- 8-7 よく使うキーは実型に固定する
-- ============================================================

-- リスト 8-26
CREATE TABLE logs_hint
(
    ts   DateTime,
    body JSON(status Int64, user_id Int64, SKIP ua)
)
ENGINE = MergeTree
ORDER BY ts;

INSERT INTO logs_hint SELECT ts, body FROM logs_str LIMIT 500000;
OPTIMIZE TABLE logs_hint FINAL;

-- リスト 8-27  ヒントを付けた status は Int64、付けていない ms は Dynamic
SELECT
    toTypeName(body.status) AS status_type,
    toTypeName(body.ms)     AS ms_type
FROM logs_hint
LIMIT 1;

-- リスト 8-28  SKIP した ua が消えている
SELECT JSONAllPaths(body) AS paths FROM logs_hint LIMIT 1;
