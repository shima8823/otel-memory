# デバッグの基本技法と環境準備

## 1. このセクションの目的

このセクションは、OpenTelemetry Collector のメモリ高騰を「見える化」し、同じ症状を再現できる状態を作るための前提を整理する。

- 観測手段は `internal metrics`、`pprof` の2つを使う
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

#### Processor / Connector 固有メトリクスを探す

上の表のような receiver/exporter レベルの汎用メトリクスだけでは、パイプライン内部のどこでデータが滞留・消失しているかを特定しづらい。  
たとえば `otelcol_receiver_refused_spans_total` が少量でも、Processor 内部で大量にメモリ保持しているケースはあり得る。

多くの Processor / Connector は、`otelcol_processor_<name>_*` や `otelcol_connector_<name>_*` 形式の固有メトリクスを公開している。  
デフォルトで公開されていても、標準ダッシュボードに含まれていないことが多いため、まず列挙して存在を確認する。

```bash
# Prometheus API で tail_sampling 固有メトリクスを列挙
curl -s http://localhost:9090/api/v1/label/__name__/values | \
  jq -r '.data[]' | grep tail_sampling
```

出力例:

```text
otelcol_processor_tail_sampling_count_spans_sampled
otelcol_processor_tail_sampling_count_traces_sampled
otelcol_processor_tail_sampling_sampling_decision_latency
otelcol_processor_tail_sampling_sampling_decision_timer_latency
otelcol_processor_tail_sampling_sampling_traces_on_memory
```

| Processor | メトリクス | 用途 |
| --- | --- | --- |
| `tail_sampling` | `sampling_traces_on_memory` | 現在メモリに保持中のトレース数。`decision_wait` × スループットの妥当性を検証 |
| `tail_sampling` | `count_spans_sampled{sampled="true/false"}` | サンプリング判定結果のスパン数。受信数との差分で内部ドロップを検知 |
| `batch` | `batch_send_size` | バッチサイズ分布。設定値と実際の乖離を確認 |
| `spanmetrics` | （connector 固有） | 内部マップのカーディナリティに関する情報 |

メモリ問題の調査では、最初に `curl ... | grep <processor名>` で対象 Processor の固有メトリクスを列挙し、ダッシュボードへ追加してから負荷試験を再実行すると切り分けが早い。

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
make pprof-diff-auto DIR=$(cat captures/last_capture.txt)
```

読み方:
- `inuse_space`: 現在使用中のメモリ。原因調査では最優先
- `alloc_space`: 累積 allocation。短時間で急増するかを見る
- `top`: どの関数がメモリを多く使っているか
- `flame graph`: call stack 全体でどこにメモリが滞留しているか

本記事では、メモリ高騰の一次診断に集中するため、主に `internal metrics` と `pprof` を使う。

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
- OTel Collector (contrib, memory limit 512MB)
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
- `make run-scenario` で、シナリオ実行から pprof 差分確認まで自動化できる

```bash
export PROJECT_ID=$(gcloud config get-value project)
make run-scenario
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
