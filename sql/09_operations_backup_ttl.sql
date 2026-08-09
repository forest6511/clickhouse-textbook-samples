-- 第9章 運用 — バックアップ・TTL・ディスク
--
-- 前提: docker compose up -d で ch が起動していること
--       第8章の logs_hint / logs_str が存在すること
--       (無い場合は先に sql/08_logs_and_json_types.sql を流す)
-- 実行: docker exec -i ch clickhouse-client --multiquery < sql/09_operations_backup_ttl.sql
--
-- 🔴 基準テーブル trips には書き込まない。SELECT のみ。
--    章専用テーブル(bk_demo / ttl_demo)と、第8章の logs_hint を使う。
--
-- 🔴 2 回目以降に流すときは、先にバックアップ実体を消すこと。
--    テーブルは下の DROP で消えるが、バックアップは同名で作れず
--    Code: 598 BACKUP_ALREADY_EXISTS で止まる。
--
--    docker exec -u root ch sh -c 'rm -rf /var/lib/clickhouse/backups/*'

DROP TABLE IF EXISTS bk_demo;
DROP TABLE IF EXISTS bk_demo_restored;
DROP TABLE IF EXISTS bk_flat;
DROP TABLE IF EXISTS ttl_demo;
DROP TABLE IF EXISTS logs_hint_restored;

-- ============================================================
-- 9-1 バックアップを取る
-- ============================================================

-- リスト 9-1 は失敗する例(Code: 36)。試す場合のみ手で実行する:
--   BACKUP TABLE logs_hint TO File('/tmp/bk_test');

-- リスト 9-3  allowed_path(既定は backups)の内側なら通る
BACKUP TABLE logs_hint TO File('bk1');

-- リスト 9-5
SELECT
    name,
    status,
    formatReadableSize(total_size) AS size,
    num_files AS files
FROM system.backups
ORDER BY start_time;

-- ============================================================
-- 9-2 復元して確かめる
-- ============================================================

-- リスト 9-6  別名で戻せるので本番テーブルを壊さずに検証できる
RESTORE TABLE default.logs_hint AS default.logs_hint_restored FROM File('bk1');

-- リスト 9-7
SELECT * FROM (
    SELECT 'original' AS tbl, count() AS c FROM logs_hint
    UNION ALL
    SELECT 'restored' AS tbl, count() AS c FROM logs_hint_restored
)
ORDER BY tbl;

-- ============================================================
-- 9-3 増分バックアップ
-- ============================================================

-- ---- 効かない例: パーティションを分けず 1 パーツにまとめたテーブル ----
-- 🔴 第8章の logs_hint は汚さない(章をまたぐ基準値が崩れるため)。
--    専用の bk_flat を作って実演する。

-- リスト 9-8
CREATE TABLE bk_flat
(
    ts   DateTime,
    body JSON(status Int64, user_id Int64, SKIP ua)
)
ENGINE = MergeTree
ORDER BY ts;

INSERT INTO bk_flat SELECT ts, body FROM logs_str LIMIT 500000;
OPTIMIZE TABLE bk_flat FINAL;

SELECT name, rows, level FROM system.parts
WHERE table = 'bk_flat' AND active;

-- リスト 9-9  1 パーツだと増分がほとんど効かない
BACKUP TABLE bk_flat TO File('flat_full');

INSERT INTO bk_flat SELECT ts, body FROM logs_str LIMIT 100000;
OPTIMIZE TABLE bk_flat FINAL;

BACKUP TABLE bk_flat TO File('flat_incr')
SETTINGS base_backup = File('flat_full');

BACKUP TABLE bk_flat TO File('flat_full2');

-- リスト 9-10  増分(flat_incr)と全量(flat_full2)の書き出し量が同じになる。
-- du -sh はブロック単位で丸めるため実行環境で 2.6M/2.7M と揺れる。
-- compressed_size のほうが安定するので本文はこちらを載せている。
SELECT
    name,
    formatReadableSize(compressed_size) AS written,
    num_entries
FROM system.backups
WHERE name LIKE '%flat%' AND status = 'BACKUP_CREATED'
ORDER BY start_time;

-- ---- 効く例: 月ごとにパーティションを分けたテーブル ----

-- リスト 9-11  月ごとにパーティションを分ける。
-- 単一パーティション(1 パーツ)だと増分がほとんど効かないため、
-- 効く条件を示すためにパーティションを分けている。
CREATE TABLE bk_demo (ts DateTime, v UInt64)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY ts;

INSERT INTO bk_demo
SELECT toDateTime('2026-01-01 00:00:00') + number * 2, number
FROM numbers(1000000);

INSERT INTO bk_demo
SELECT toDateTime('2026-02-01 00:00:00') + number * 2, number
FROM numbers(1000000);

-- リスト 9-12
BACKUP TABLE bk_demo TO File('demo_full');

INSERT INTO bk_demo
SELECT toDateTime('2026-03-01 00:00:00') + number * 2, number
FROM numbers(1000000);

BACKUP TABLE bk_demo TO File('demo_incr')
SETTINGS base_backup = File('demo_full');

-- 比較用: 同じ状態を全量で取り直す
BACKUP TABLE bk_demo TO File('demo_full2');

-- リスト 9-13 はシェルで実行する:
--   docker exec ch du -sh /var/lib/clickhouse/backups/demo_full \
--                         /var/lib/clickhouse/backups/demo_incr \
--                         /var/lib/clickhouse/backups/demo_full2

-- リスト 9-14  total_size は論理的な総量。実際に書いた量は compressed_size
SELECT
    name,
    formatReadableSize(total_size)      AS total,
    formatReadableSize(compressed_size) AS written,
    num_entries
FROM system.backups
WHERE name LIKE '%demo%' AND status = 'BACKUP_CREATED'
ORDER BY start_time;

-- リスト 9-15  増分からの復元(base_backup も残っている必要がある)
RESTORE TABLE default.bk_demo AS default.bk_demo_restored FROM File('demo_incr');

SELECT * FROM (
    SELECT 'original' AS tbl, count() AS c FROM bk_demo
    UNION ALL
    SELECT 'restored' AS tbl, count() AS c FROM bk_demo_restored
)
ORDER BY tbl;

-- ============================================================
-- 9-4 TTL(マージ時にのみ適用される)
-- ============================================================

-- リスト 9-16
CREATE TABLE ttl_demo (ts DateTime, v UInt64)
ENGINE = MergeTree
ORDER BY ts
TTL ts + INTERVAL 30 DAY;

-- リスト 9-17  マージを止めると TTL は適用されない
SYSTEM STOP MERGES ttl_demo;

INSERT INTO ttl_demo
SELECT now() - INTERVAL 100 DAY + intDiv(number, 1000), number
FROM numbers(500000);

INSERT INTO ttl_demo
SELECT now() - intDiv(number, 1000), number
FROM numbers(500000);

SELECT count() AS rows, min(ts) AS oldest FROM ttl_demo;

-- リスト 9-18  level = 0 = 一度もマージされていない
SELECT name, level, rows FROM system.parts
WHERE table = 'ttl_demo' AND active
ORDER BY name;

-- リスト 9-19  マージを再開して強制すると消える
SYSTEM START MERGES ttl_demo;
OPTIMIZE TABLE ttl_demo FINAL;

SELECT count() AS rows, min(ts) AS oldest FROM ttl_demo;

-- ============================================================
-- 9-5 ディスクの確認
-- ============================================================

-- リスト 9-20
SELECT
    name,
    formatReadableSize(free_space)  AS free,
    formatReadableSize(total_space) AS total,
    round((1 - free_space / total_space) * 100, 1) AS used_pct
FROM system.disks;

-- リスト 9-21
SELECT
    table,
    formatReadableSize(sum(bytes_on_disk)) AS disk,
    sum(rows)                              AS rows,
    count()                                AS parts
FROM system.parts
WHERE active AND database = 'default'
GROUP BY table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 5;

-- リスト 9-22
SELECT
    round(query_duration_ms / 1000, 3) AS sec,
    formatReadableSize(read_bytes)     AS read,
    substringUTF8(replaceRegexpAll(query, '\\s+', ' '), 1, 26) AS q
FROM system.query_log
WHERE type = 'QueryFinish' AND query_duration_ms > 100
ORDER BY query_duration_ms DESC
LIMIT 5;

-- リスト 9-23  既定では TTL 句が無い
-- ※ 2 回目以降の実行では下の 9-24 で付けた TTL が残っているため、
--    本文の出力(TTL 句なし)を再現するには先に次を実行して初期状態へ戻す:
--      ALTER TABLE system.query_log REMOVE TTL;
SELECT engine_full FROM system.tables
WHERE database = 'system' AND table = 'query_log'
FORMAT Vertical;

-- リスト 9-24  保存期間を設定する
-- ※ 稼働中のサーバーでは、調査に使っている記録が消えないか確認してから実行する
ALTER TABLE system.query_log MODIFY TTL event_date + INTERVAL 30 DAY;

SELECT engine_full FROM system.tables
WHERE database = 'system' AND table = 'query_log'
FORMAT Vertical;

-- ============================================================
-- 9-6 事故の範囲を狭める
-- ============================================================

-- リスト 9-25 は失敗する例(Code: 241)。試す場合のみ手で実行する:
--   SELECT count() FROM (SELECT DISTINCT body FROM logs_str)
--   SETTINGS max_memory_usage = 20000000;

-- リスト 9-26
DROP USER IF EXISTS analyst;
CREATE USER analyst IDENTIFIED BY 'secret';
GRANT SELECT ON default.* TO analyst;

-- リスト 9-27 / 9-28 はシェルで実行する:
--   docker exec ch clickhouse-client --user analyst --password secret \
--     --format PrettyCompact --query "SELECT count() FROM trips"
--   docker exec ch clickhouse-client --user analyst --password secret \
--     --query "DROP TABLE logs_str"     -- Code: 497 で拒否される
