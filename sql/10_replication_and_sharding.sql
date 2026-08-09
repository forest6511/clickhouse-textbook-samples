-- 第10章 レプリケーションとシャーディング
--
-- 🔴 このファイルは「クラスタ環境」で実行する。第1〜9章の単一ノード（ch / pg）ではない。
--
--   docker compose -f docker-compose.cluster.yml up -d
--   docker exec -i ch1 clickhouse-client < sql/10_replication_and_sharding.sql
--
-- 🔴 障害の実験（ch2 / keeper を止める）は docker のコマンドが要るため
--    このファイルには含まれない。本文リスト 10-10 〜 10-13 を手で実行すること。
--
-- 🔴 基準テーブル trips には一切触らない（別コンテナなので汚染の心配もない）。

-- ---------------------------------------------------------------------------
-- 10-3 クラスタの構成を確認する（リスト 10-3 / 10-16）
-- ---------------------------------------------------------------------------
SELECT cluster, shard_num, replica_num, host_name
FROM system.clusters
WHERE cluster = 'demo'
ORDER BY shard_num, replica_num;

SELECT cluster, shard_num, replica_num, host_name
FROM system.clusters
WHERE cluster = 'demo_shards'
ORDER BY shard_num, replica_num;

-- ---------------------------------------------------------------------------
-- 10-4 複製テーブルを作る（リスト 10-4 / 10-5）
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS events ON CLUSTER demo SYNC;

CREATE TABLE events ON CLUSTER demo
(
    ts      DateTime,
    user_id UInt32,
    action  LowCardinality(String)
)
ENGINE = ReplicatedMergeTree
ORDER BY (ts, user_id);

-- 省略した引数が {uuid} で補完されることを確認する
SHOW CREATE TABLE events;

-- ---------------------------------------------------------------------------
-- 10-5 複製されていることを確かめる（リスト 10-6 〜 10-9）
-- ---------------------------------------------------------------------------
INSERT INTO events SETTINGS async_insert = 0
SELECT
    toDateTime('2026-08-01 00:00:00') + number,
    number % 1000,
    ['view', 'click', 'purchase'][number % 3 + 1]
FROM numbers(100000);

SELECT count() FROM events;

SELECT count() AS parts, sum(rows) AS rows
FROM system.parts WHERE table = 'events' AND active;

SELECT is_readonly, absolute_delay, total_replicas, active_replicas, queue_size
FROM system.replicas WHERE table = 'events';

-- ---------------------------------------------------------------------------
-- 10-8 同じ INSERT を 2 回投げる（リスト 10-14 / 10-15）
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS dedup_demo ON CLUSTER demo SYNC;
DROP TABLE IF EXISTS dedup_plain SYNC;

CREATE TABLE dedup_demo ON CLUSTER demo (id UInt32)
ENGINE = ReplicatedMergeTree ORDER BY id;

CREATE TABLE dedup_plain (id UInt32)
ENGINE = MergeTree ORDER BY id;

-- 複製テーブル: 2 回目は捨てられる
INSERT INTO dedup_demo SETTINGS async_insert = 0 VALUES (1), (2), (3);
INSERT INTO dedup_demo SETTINGS async_insert = 0 VALUES (1), (2), (3);

-- 複製していないテーブル: そのまま重複する
INSERT INTO dedup_plain SETTINGS async_insert = 0 VALUES (1), (2), (3);
INSERT INTO dedup_plain SETTINGS async_insert = 0 VALUES (1), (2), (3);

SELECT 'dedup_demo (Replicated)' AS t, count() AS rows FROM dedup_demo
UNION ALL
SELECT 'dedup_plain (MergeTree)' AS t, count() AS rows FROM dedup_plain
ORDER BY t;

SELECT name, value FROM system.merge_tree_settings
WHERE name IN ('replicated_deduplication_window',
               'non_replicated_deduplication_window');

-- ---------------------------------------------------------------------------
-- 10-9 データを分けて置く（リスト 10-17 / 10-18）
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS hits ON CLUSTER demo_shards SYNC;
DROP TABLE IF EXISTS hits_local ON CLUSTER demo_shards SYNC;

CREATE TABLE hits_local ON CLUSTER demo_shards
(
    ts      DateTime,
    user_id UInt32,
    amount  Float64
)
ENGINE = MergeTree
ORDER BY ts;

CREATE TABLE hits ON CLUSTER demo_shards AS hits_local
ENGINE = Distributed(demo_shards, default, hits_local, intHash64(user_id));

INSERT INTO hits SETTINGS distributed_foreground_insert = 1
SELECT toDateTime('2026-08-01') + number, number % 10000, number % 100
FROM numbers(100000);

SELECT count() FROM hits;          -- 全体
SELECT count() FROM hits_local;    -- このノードだけ

SELECT _shard_num, count() FROM hits GROUP BY _shard_num ORDER BY _shard_num;

-- ---------------------------------------------------------------------------
-- 10-10 偏るシャーディングキーの失敗（リスト 10-19）
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS skew ON CLUSTER demo_shards SYNC;
DROP TABLE IF EXISTS skew_local ON CLUSTER demo_shards SYNC;

CREATE TABLE skew_local ON CLUSTER demo_shards
(
    ts     DateTime,
    plan   UInt8,
    amount Float64
)
ENGINE = MergeTree
ORDER BY ts;

-- plan は 0 か 1 の 2 種類しかなく、9 割が 0 に寄っている
CREATE TABLE skew ON CLUSTER demo_shards AS skew_local
ENGINE = Distributed(demo_shards, default, skew_local, plan);

INSERT INTO skew SETTINGS distributed_foreground_insert = 1
SELECT toDateTime('2026-08-01') + number,
       if(number % 10 = 0, 1, 0),
       number % 100
FROM numbers(100000);

SELECT _shard_num, count() FROM skew GROUP BY _shard_num ORDER BY _shard_num;

-- ---------------------------------------------------------------------------
-- 10-11 分散環境の JOIN（リスト 10-20 〜 10-23）
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS users ON CLUSTER demo_shards SYNC;
DROP TABLE IF EXISTS users_local ON CLUSTER demo_shards SYNC;

CREATE TABLE users_local ON CLUSTER demo_shards (user_id UInt32, name String)
ENGINE = MergeTree ORDER BY user_id;

-- hits は intHash64(user_id) で分けたが、users は rand() で分ける。
-- 結合キーが同じノードに揃っていない状況を意図的に作る。
CREATE TABLE users ON CLUSTER demo_shards AS users_local
ENGINE = Distributed(demo_shards, default, users_local, rand());

INSERT INTO users SETTINGS distributed_foreground_insert = 1
SELECT number, concat('user_', toString(number)) FROM numbers(10000);

-- 既定（deny）では Code: 288 で拒否される
-- SELECT count() FROM hits AS h INNER JOIN users AS u ON h.user_id = u.user_id;

-- local に変えるとエラーは出ないが 50000（誤答）になる
SELECT count() AS wrong_answer
FROM hits AS h INNER JOIN users AS u ON h.user_id = u.user_id
SETTINGS distributed_product_mode = 'local';

-- GLOBAL JOIN なら 100000（正）
SELECT count() AS correct_answer
FROM hits AS h GLOBAL INNER JOIN users AS u ON h.user_id = u.user_id;

-- なぜ 50000 になるか: 各シャードが自分の users としか突き合わせていない
SELECT count() AS local_only
FROM hits_local AS h INNER JOIN users_local AS u ON h.user_id = u.user_id;
