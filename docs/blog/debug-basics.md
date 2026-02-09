# デバッグの基本技法と環境準備

## 1. このセクションの目的

このセクションは、OpenTelemetry Collector のメモリ高騰を「見える化」し、同じ症状を再現できる状態を作るための前提を整理する。

- 観測手段は `internal metrics`、`pprof`、`zpages` の3つを使う
- ローカルと GCP の再現環境を用意し、同じ手順で比較できるようにする

## 2. 観測手段

### 2.1 OTel Collector 内部メトリクス（Grafana で可視化）

まずは `otelcol_*` の内部メトリクスを Grafana で確認する。症状検知の初動はここが最速。

| Metric | 何を見るか | 異常時の読み方 |
| --- | --- | --- |
| `otelcol_process_runtime_heap_alloc_bytes` | 現在の Heap allocation | GC 後も下がりにくい場合はリーク疑い |
| `otelcol_process_memory_rss` | OS から見た実メモリ使用量（RSS） | Heap と乖離して上昇し続ける場合は要調査 |
| `otelcol_receiver_accepted_spans_total` / `otelcol_receiver_refused_spans_total` | Receiver の受信/拒否スパン数 | `refused` 増加は `memory_limiter` 発火のサイン |
| `otelcol_exporter_queue_size` / `otelcol_exporter_queue_capacity` | Exporter queue 使用率 | 100% 張り付きは下流遅延や停止の疑い |
| `otelcol_processor_batch_batch_send_size` | Batch processor の送信バッチサイズ | 異常に大きい/変動が激しい場合は `batch` 設定を見直す |

注意:
- Collector のバージョンによってはメトリクス名に `_bytes` などの suffix が付く。実際の値は `make metrics` で列挙して確認する。
- 内部メトリクス仕様は変更される可能性があるため、最終的には公式ドキュメントを参照する。

```bash
make metrics
```

### 2.2 pprof（heap profile）

`pprof` は Go の profiling tool。Collector では `pprof` extension を有効化して `heap profile` を取得できる。

取得方法:

```bash
# 単発で確認（Web UI）
make pprof-heap

# 継続キャプチャ開始/停止
make pprof-capture-bg
make pprof-capture-stop

# 直近キャプチャの差分分析（baseline と peak の比較）
make pprof-diff-auto DIR=$(cat pprof/last_capture.txt)
```

読み方:
- `inuse_space`: 現在使用中のメモリ。原因調査では最優先
- `alloc_space`: 累積 allocation。短時間で急増するかを見る
- `top`: どの関数がメモリを多く使っているか
- `flame graph`: call stack 全体でどこにメモリが滞留しているか

### 2.3 zpages（概要のみ）

`zpages` は Collector の内部状態を HTTP で確認する extension。pipeline の状態や span サンプルを素早く確認できる。

本記事では、メモリ高騰の一次診断に集中するため、主に `internal metrics` と `pprof` を使う。`zpages` の詳細はシナリオレポート側で必要に応じて扱う。

## 3. 負荷生成ツール

### 3.1 loadgen（本プロジェクトのカスタムツール）

`loadgen` は Go 製の負荷生成ツール。再現性を保つため、まずはこのツールを標準で使う。

- 対応シナリオ: `burst`, `sustained`, `spike`, `rampup`
- ビルド:

```bash
make build
```

- 主要オプション:
  - `-endpoint`: 送信先（default: `localhost:4317`）
  - `-scenario`: シナリオ種別
  - `-duration`: 実行時間
  - `-rate`: 目標 spans/sec
  - `-workers`: worker 数
  - `-high-cardinality`: 高カーディナリティ属性を有効化

実行例:

```bash
./loadgen/loadgen \
  -endpoint localhost:4317 \
  -scenario sustained \
  -duration 120s \
  -rate 10000 \
  -workers 20 \
  -high-cardinality
```

### 3.2 telemetrygen（公式ツール）

`telemetrygen` は OpenTelemetry Collector Contrib が提供する公式の負荷生成ツール。Docker image で手軽に使える。

このリポジトリでは `make` ターゲットから実行できる。

```bash
make tgen-traces
make tgen-metrics
```

## 4. 環境構築

### 4.1 ローカル環境

```bash
docker compose up -d
```

構成:
- OTel Collector (contrib, memory limit 256MB)
- Prometheus
- Jaeger
- Grafana

URL:
- Grafana: `http://localhost:3000`
- Prometheus: `http://localhost:9090`
- Jaeger: `http://localhost:16686`
- pprof: `http://localhost:1777/debug/pprof/`

### 4.2 GCP 環境（概要）

- `terraform/` で GCE instance を構築する
- VM 上でローカルと同じ Docker Compose 構成を動かす
- `make pprof-scenario-full` で、シナリオ実行から pprof 差分確認まで自動化できる

```bash
export PROJECT_ID=$(gcloud config get-value project)
make pprof-scenario-full
```

## 5. 診断の基本フロー（まとめ）

1. 環境起動
2. 負荷実行
3. Grafana でメトリクス確認
4. 異常を検知
5. pprof で heap 解析
6. 原因特定
7. パラメータ調整
8. 再実行して改善確認
