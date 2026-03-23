# キャプチャデータの読み方

検証データは、各シナリオの `captures/` ディレクトリに格納されています。
ここでは、ディレクトリ構成とファイルの見方を説明します。

## ディレクトリ構成

```
scenario-reports/
└── tail-sampling/captures/
    ├── non-opt/          # 修正前（decision_wait: 30s）
    └── opt/              # 修正後（decision_wait: 5s）
```

`non-opt/`（修正前）と `opt/`（修正後）の対で構成されています。

## 各キャプチャの中身

```
non-opt/ または opt/
├── docker-stats-capture.log # docker stats 取得処理の実行ログ
├── docker-stats.log         # 各コンテナの CPU / メモリ使用量の記録
├── scenario.log             # シナリオ実行ログ
├── pprof/                # heap profile（5秒間隔で取得）
│   ├── heap_HHMMSS.pprof
│   └── ...
├── metrics/              # Prometheus メトリクスのスナップショット
│   ├── _SUMMARY.md       # エクスポートしたメトリクスの一覧と説明
│   ├── Heap_Alloc_bytes.txt
│   ├── Receiver_Accepted_Spans_Rate.txt
│   └── ...
└── images/               # Grafana スクリーンショット
    ├── heap_memory.png
    ├── receiver_spans.png
    ├── pprof-graph.png
    └── ...
```

`pprof/`、`metrics/`、`images/` が主要な分析対象で、ルート直下の `*.log` は「どの条件で取得したデータか」を補う補助ログです。

### pprof/

Go の heap profile です。ファイル名の `HHMMSS` は取得時刻（UTC）を表します。

```bash
# 特定のファイルを分析
go tool pprof -inuse_space pprof/heap_xxxxx.pprof

# Heap 使用量が最大のファイル（＝ピーク）を特定（Makefile を使用）
make pprof-list DIR=docs/blog/scenario-reports/tail-sampling/captures/non-opt
```

`make pprof-list` は各 `.pprof` ファイルの `inuse_space`（Heap 上の使用中メモリ）を一覧表示し、最大値のファイルに `PEAK` マークを付けます。この Heap 使用量ピーク時の profile を見ることで、メモリ高騰時にどの関数がメモリを消費していたかがわかります。

### metrics/

Prometheus からエクスポートしたメトリクスの時系列データです。

```
# Heap_Alloc_bytes.txt の例
1742139124 256901120
1742139139 268435456
1742139154 312475648
```

`_SUMMARY.md` にエクスポートしたメトリクスの一覧と各メトリクスの説明があります。

### images/

Grafana ダッシュボードのスクリーンショットです。主なファイルとその内容：

| ファイル名 | 内容 |
|-----------|------|
| `heap_memory.png` | Heap 使用量の時系列（soft_limit 線付き） |
| `rss_memory.png` | RSS（物理メモリ）使用量 |
| `receiver_spans.png` | Receiver の受信レート（Accepted / Refused） |
| `exporter_spans.png` | Exporter の送信レート（Sent / Failed） |
| `exporter_queue_usage.png` | Exporter キューの使用率 |
| `pprof-graph.png` | pprof のコールグラフ（Heap 使用量ピーク時） |

### docker-stats.log

`docker stats` を一定間隔で採取したログです。Collector だけでなく、Prometheus、Grafana など同じ VM 上の他コンテナも含めた CPU / メモリ使用量を確認できます。

```text
NAME                           CPU %     MEM USAGE / LIMIT     MEM %
otel-memory-otel-collector-1   46.00%    63.84MiB / 512MiB     12.47%
```

Grafana の内部メトリクスは Collector 自身の観測が中心ですが、`docker-stats.log` は「コンテナ全体としてどこまでメモリ制限に近づいていたか」や「Collector 以外のプロセスが影響していないか」を横断的に確認するために使います。

### docker-stats-capture.log

`docker-stats.log` を取得する補助スクリプトの実行ログです。主に、収集が開始・停止できたか、最終的にどのパスへ保存されたかを確認するために使います。

```text
=== Start docker stats capture ===
✅ docker stats capture started
=== Stop docker stats capture ===
✅ docker stats log saved to /Users/shima/Project/otel-memory/captures/03-23/124249/docker-stats.log
```

分析の主役ではありませんが、`docker-stats.log` の欠落や取得失敗を切り分けるときに参照します。

### scenario.log

シナリオ実行全体のログです。Collector へ適用した設定、負荷投入開始、`telemetrygen` の生成量、後処理の待機や設定戻しまでが時系列で記録されます。

```text
=== Scenario: Tail Sampling Buffered Optimized ===
1. Applying tail-sampling-optimized.yaml config to Collector VM...
2. Starting load command on Loadgen VM...
2026-03-23T03:53:33.203Z INFO traces/worker.go:180 traces generated {"worker": 5, "traces": 54344}
3. Waiting 90s for tail_sampling buffer to drain...
```

本文中で引用している「負荷条件」「実際の生成量」「後処理で待機した時間」は、この `scenario.log` をもとに確認できます。

## ブログ本文との対応

| ブログのセクション | キャプチャの場所 |
|------------------|----------------|
| 実践検証: Tail Sampling — 問題の発見 | `tail-sampling/captures/non-opt/` |
| 実践検証: Tail Sampling — 最適化 | `tail-sampling/captures/opt/` |

## 手元で分析を再現する

```bash
# リポジトリをクローン
git clone https://github.com/shima8823/otel-memory.git
cd otel-memory

# Heap 使用量が最大の pprof ファイルを特定
make pprof-list DIR=docs/blog/scenario-reports/tail-sampling/captures/non-opt

# Heap ピーク時の profile を分析
go tool pprof -inuse_space docs/blog/scenario-reports/tail-sampling/captures/non-opt/pprof/heap_xxxxxx.pprof

```
