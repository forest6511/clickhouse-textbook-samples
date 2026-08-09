# ClickHouse の教科書 — サンプルコード

書籍『ClickHouse の教科書』の実行環境とサンプルです。
ClickHouse と PostgreSQL を並べて立ち上げ、**同じデータに同じクエリ**を投げて違いを実測します。

## 必要なもの

- Docker Desktop（Windows / macOS）または Docker Engine（Linux）
- ディスクの空き 1GB 程度

Apple Silicon (M1〜) でもそのまま動きます（arm64 イメージが公式に提供されています）。

## 使い方

```bash
git clone https://github.com/forest6511/clickhouse-textbook-samples.git
cd clickhouse-textbook-samples

docker compose up -d          # 初回はイメージ取得で数分かかります

# サンプルデータ投入（著者環境で合計 8 秒ほど。大半は PostgreSQL 側）
docker exec -i ch clickhouse-client < sql/01_clickhouse_setup.sql
docker exec -i pg psql -U ch -d chbench < sql/02_postgres_setup.sql

./bench.sh                    # 実測
```

## 章ごとのサンプル

各章の本文に出てくる SQL は `sql/` に章別でまとめてあります。
上の初期セットアップを済ませたあと、読んでいる章のファイルを流すと本文と同じ出力が得られます。

**第6章だけは先に準備が要ります。** ファイルの取り込みを扱う章で、
ClickHouse の `file()` 関数はサーバ内の `user_files` ディレクトリしか読まないため、
手元のファイルをコンテナへ渡しておく必要があります。

```bash
# 壊れた行を含む CSV（リスト 6-15）をサーバへ渡す
docker cp data/bad.csv ch:/var/lib/clickhouse/user_files/

# 本文の trips_sample.csv / .parquet は trips から書き出して作る
docker exec ch clickhouse-client --query "
INSERT INTO FUNCTION file('trips_sample.csv', CSVWithNames)
SELECT * FROM trips LIMIT 100000
SETTINGS engine_file_truncate_on_insert=1"

docker exec ch clickhouse-client --query "
INSERT INTO FUNCTION file('trips_sample.parquet', Parquet)
SELECT * FROM trips LIMIT 100000
SETTINGS engine_file_truncate_on_insert=1"
```

準備ができたら各章のスクリプトを流します。

```bash
docker exec -i ch clickhouse-client --multiquery < sql/06_loading_data_and_types.sql
docker exec -i ch clickhouse-client --multiquery < sql/07_materialized_views.sql
docker exec -i ch clickhouse-client --multiquery < sql/08_logs_and_json_types.sql
docker exec -i ch clickhouse-client --multiquery < sql/09_operations_backup_ttl.sql
```

第9章のスクリプトは第8章で作るテーブルを使うので、08 → 09 の順に実行してください。
第9章を **2 回以上流すときは、先にバックアップの実体を消します**。テーブルはスクリプトの
先頭で消えますが、バックアップは同じ名前で作れず `Code: 598` で止まるためです。

```bash
docker exec -u root ch sh -c 'rm -rf /var/lib/clickhouse/backups/*'
```

第8章のスクリプトは、型が混在する JSON を SQL の `INSERT` で投入します。
同じデータを JSONEachRow 形式のファイルからも入れられます（`data/ev_mixed.jsonl`）。

```bash
docker exec -i ch clickhouse-client \
  --query "INSERT INTO ev_mixed FORMAT JSONEachRow" < data/ev_mixed.jsonl
```

第11章・第12章も同じ単一ノード環境で実行します。

```bash
docker exec -i ch clickhouse-client --multiquery < sql/11_choosing_the_right_tool.sql
docker exec -i ch clickhouse-client --multiquery < sql/12_building_a_log_analytics_stack.sql
```

第11章は PostgreSQL 側の `trips` を参照するので、先に `sql/02_postgres_setup.sql` を流しておいてください。

**第10章だけは別のクラスタ環境**（ClickHouse 2 ノード + Keeper）を使います。

```bash
docker compose -f docker-compose.cluster.yml up -d
docker exec -i ch1 clickhouse-client < sql/10_replication_and_sharding.sql
```

ノードを止めて挙動を見る実験（本文リスト 10-10 〜 10-13）は `docker` のコマンドが必要なため、
このスクリプトには含めていません。本文を見ながら手で実行してください。

クラスタを使い終えたら `docker compose -f docker-compose.cluster.yml down -v` で片付けます。

> ⚠️ 各章のスクリプトは、その章専用のテーブルだけを作り書きします。
> 第1〜3章が基準にしている `trips`（500 万行）には書き込みません。
> `trips` を自分で書き換えた場合は `sql/01_clickhouse_setup.sql` を流し直すと元に戻ります。

## ブラウザで試す

ClickHouse は **サーバに Web UI が同梱**されています。追加インストールは不要です。

<http://localhost:8123/play>

クエリを実行すると、読み込んだ行数と秒間処理行数がその場で表示されます。
CLI を使いたい場合は `docker exec -it ch clickhouse-client` で、同じことができます。
**どちらか一方だけでも本書は読み進められます。**

## 実測例

著者環境（Docker Desktop / Apple Silicon / 12 コア）での結果です。

- **500万行の集計** — ClickHouse 26.7: 約 0.011 秒 / PostgreSQL 17.10: 約 0.18 秒
- **ディスク使用量** — ClickHouse: 55.66 MiB / PostgreSQL: 287 MB

同じ行数・同じクエリで、集計は十数倍速く、保存容量は約 5 分の 1 でした。

**秒数は環境によって変わります**（主因は CPU コア数。ClickHouse は既定で使えるコアを
並列に使うため、`SELECT getSetting('max_threads')` で自分の並列度を確認できます）。
一方、ディスク使用量・圧縮率・読み込み行数は環境が変わっても同じ結果になります。

なぜこうなるのかは本文（列指向・MergeTree・スパース主キーインデックス）で解説します。

## うまくいかないとき

**ポートが使用中というエラーが出る**

`8123`（HTTP）・`9000`（ネイティブ）・`55432`（PostgreSQL）を使います。
とくに `9000` は MinIO や Portainer など他のツールとぶつかりやすいポートです。
`docker-compose.yml` の左側の数字を変えてください（例 `"18123:8123"`）。
変更したら接続先も合わせて読み替えます。

**`docker exec` で "No such container" と出る**

`docker compose up -d` が完了しているか `docker compose ps` で確認してください。

## 後片付け

```bash
docker compose down -v        # -v でデータも削除します
```
