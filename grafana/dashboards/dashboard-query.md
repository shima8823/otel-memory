# Grafana ダッシュボード クエリドキュメント

このドキュメントは、`otel-collector-memory.json` ダッシュボードの各パネルで使用されているPrometheusクエリと、そのクエリが何を表示しているかを説明します。

## 目次

1. [Collector Memory Overview](#collector-memory-overview)
2. [Receiver (受信)](#receiver-受信)
3. [Processor (処理)](#processor-処理)
4. [Exporter (送信)](#exporter-送信)
5. [GC & Runtime Metrics](#gc--runtime-metrics)

---

## Collector Memory Overview

### 1. Collector Heap Memory (ID: 1)

**表示内容**: Collectorのヒープメモリ使用量の推移

**クエリ**:
- `otelcol_process_runtime_heap_alloc_bytes{job="otel-collector-self"}`
  - **説明**: Goランタイムが現在割り当てているヒープメモリのバイト数（瞬時値）
  - **単位**: bytes
  - **重要度**: メモリ高騰の主要指標。`memory_limiter`の`limit_mib`と比較して監視

- `otelcol_process_runtime_total_alloc_bytes_total{job="otel-collector-self"}`
  - **説明**: Collector起動時からの累積ヒープ割り当てバイト数（カウンター）
  - **単位**: bytes
  - **重要度**: メモリ割り当ての総量を把握。右肩上がりが続く場合はメモリリークの可能性

**シナリオでの使用**:
- **シナリオ3**: `limit_mib`付近に張り付く
- **シナリオ4**: 一定で変化なし（RSSと乖離が開く場合はメモリリーク）
- **シナリオ10**: ノコギリ波状に大きく変動（バッチ処理の影響）

---

### 2. Collector Sys / RSS Memory (ID: 2)

**表示内容**: OSから割り当てられたメモリと物理メモリ使用量

**クエリ**:
- `otelcol_process_runtime_total_sys_memory_bytes{job="otel-collector-self"}`
  - **説明**: OSから取得した総メモリバイト数（Goランタイムが管理するメモリ領域）
  - **単位**: bytes
  - **重要度**: Goランタイムのメモリ管理領域のサイズ

- `otelcol_process_memory_rss_bytes{job="otel-collector-self"}`
  - **説明**: 物理メモリ（Resident Set Size）のバイト数
  - **単位**: bytes
  - **重要度**: **メモリリーク検出の最重要指標**。Heapと乖離が開く場合はメモリリークの可能性

**シナリオでの使用**:
- **シナリオ4**: RSSが右肩上がりに増加（Heapは一定）→ メモリリークのシグネチャ

---

### 3. Current Heap Alloc (ID: 3)

**表示内容**: 現在のヒープ割り当て量（Statパネル）

**クエリ**:
- `otelcol_process_runtime_heap_alloc_bytes{job="otel-collector-self"}`

**閾値**:
- 🟢 Green: < 128MB
- 🟡 Yellow: ≥ 128MB
- 🟠 Orange: ≥ 256MB
- 🔴 Red: ≥ 512MB

---

### 4. Current RSS Memory (ID: 4)

**表示内容**: 現在のRSSメモリ使用量（Statパネル）

**クエリ**:
- `otelcol_process_memory_rss_bytes{job="otel-collector-self"}`

**閾値**:
- 🟢 Green: < 256MB
- 🟡 Yellow: ≥ 256MB
- 🟠 Orange: ≥ 512MB
- 🔴 Red: ≥ 1GB

---

### 5. Uptime (ID: 5)

**表示内容**: Collectorの稼働時間

**クエリ**:
- `otelcol_process_uptime_seconds_total{job="otel-collector-self"}`

**用途**: メモリリーク検出時に、どのくらいの時間稼働しているかを確認

---

### 6. CPU Usage Rate (ID: 6)

**表示内容**: CPU使用率（0.0-1.0の範囲）

**クエリ**:
- `rate(otelcol_process_cpu_seconds_total{job="otel-collector-self"}[1m])`
  - **説明**: 1分間のCPU使用時間のレート（CPU使用率）
  - **単位**: percentunit (0.0 = 0%, 1.0 = 100%)

**閾値**:
- 🟢 Green: < 50%
- 🟡 Yellow: ≥ 50%
- 🟠 Orange: ≥ 80%
- 🔴 Red: ≥ 100%

**シナリオでの使用**:
- **シナリオ8**: CPU制限下で100%に張り付く

---

## Receiver (受信)

Receiverセクションでは、Collectorが受信したデータのスループットと、メモリ制限により拒否されたデータの割合を表示します。

### 7. Receiver: Spans Rate (ID: 7)

**表示内容**: Receiverが受け入れた/拒否したスパンのレート（絶対値）

**役割**: **メモリへの影響を評価するため、絶対値で表示**

**クエリ**:
- `rate(otelcol_receiver_accepted_spans_total{job="otel-collector-self"}[1m])`
  - **説明**: 1分間でパイプラインに受け入れられたスパン数/秒
  - **単位**: ops/sec

- `rate(otelcol_receiver_refused_spans_total{job="otel-collector-self"}[1m])`
  - **説明**: 1分間でパイプラインに拒否されたスパン数/秒（memory_limiter発火時）
  - **単位**: ops/sec

**なぜ絶対値が必要か**:
- **メモリへの影響を直接評価**: 例: 10,000 spans/sec が refused なら、その分のメモリが解放されていない可能性がある
- **トレンドの変化が視覚的に分かる**: accepted が減り、refused が増える様子が明確
- **ゼロサムの関係が明確**: `accepted + refused = 正常に受信できた総数`（`failed` は別カテゴリ）

**補完関係**: ID: 14（Receiver: Drop Rate）と**補完関係**。ID: 14は割合を表示し、相対的な影響度を評価する。メモリデバッグでは両方の視点が必要。

**シナリオでの使用**:
- **シナリオ1**: Refusedが急増（下流停止時）
- **シナリオ3**: Refusedが常に0より大きい（キャパシティ不足）

---

### 8. Receiver: Metric Points Rate (ID: 8)

**表示内容**: Receiverが受け入れた/拒否したメトリクスポイントのレート（絶対値）

**役割**: **メモリへの影響を評価するため、絶対値で表示**

**クエリ**:
- `rate(otelcol_receiver_accepted_metric_points_total{job="otel-collector-self"}[1m])`
- `rate(otelcol_receiver_refused_metric_points_total{job="otel-collector-self"}[1m])`

**補完関係**: ID: 14（Receiver: Drop Rate）と**補完関係**。ID: 14は割合を表示し、相対的な影響度を評価する。メモリデバッグでは両方の視点が必要。

---

### 14. Receiver: Drop Rate (ID: 14)

**表示内容**: Receiverがデータを拒否した割合（0.0-1.0）

**役割**: **相対的な影響度を評価するため、割合で表示**

**クエリ**:
- Spans: `rate(otelcol_receiver_refused_spans_total{job="otel-collector-self"}[1m]) / (rate(otelcol_receiver_accepted_spans_total{job="otel-collector-self"}[1m]) + rate(otelcol_receiver_refused_spans_total{job="otel-collector-self"}[1m]))`
- Metrics: `rate(otelcol_receiver_refused_metric_points_total{job="otel-collector-self"}[1m]) / (rate(otelcol_receiver_accepted_metric_points_total{job="otel-collector-self"}[1m]) + rate(otelcol_receiver_refused_metric_points_total{job="otel-collector-self"}[1m]))`

**注意**: ログ関連のメトリクスは利用できません

**説明**: 受け入れられたデータと拒否されたデータの合計に対する拒否率。**ゼロサムゲーム**: `accepted + refused = 正常に受信できた総数`（`failed` は受信処理自体が失敗したものなので別カテゴリ）。**`refused`されたデータはドロップされ、失われます**（キューに入れられることも、次のバッチに回されることもありません）。

**なぜ割合が必要か**:
- **相対的な影響度が分かる**: 10%拒否されている、など
- **閾値設定がしやすい**: 1%以上で警告、など
- **メモリ制限の影響を直感的に理解**: システムのキャパシティ不足を示す

**補完関係**: ID: 7（Receiver: Spans Rate）と**補完関係**。ID: 7は絶対値を表示し、メモリへの影響を直接評価する。メモリデバッグでは両方の視点が必要:
- **絶対値が大きい** → メモリへの影響が大きい
- **割合が大きい** → システムのキャパシティ不足を示す

**閾値**:
- 🟢 Green: < 1%
- 🟡 Yellow: ≥ 1%
- 🟠 Orange: ≥ 5%
- 🔴 Red: ≥ 10%

**シナリオでの使用**:
- **シナリオ1**: memory_limiterがバックプレッシャーをかけると上昇
- **シナリオ3**: キャパシティ不足で常に高い値

---

## Processor (処理)

Processorセクションでは、Processorが処理したデータのスループット、バッチ処理の状態、およびメモリ制限により拒否されたデータの割合を表示します。

### 13. Processor: Refused (ID: 13)

**表示内容**: Processorが拒否したアイテムのレート（絶対値）

**役割**: **メモリへの影響を評価するため、絶対値で表示**

**クエリ**:
- `rate(otelcol_processor_refused_spans_total{job="otel-collector-self"}[1m])`
  - **説明**: memory_limiterが拒否したスパン数/秒

- `rate(otelcol_processor_refused_metric_points_total{job="otel-collector-self"}[1m])`
  - **説明**: memory_limiterが拒否したメトリクスポイント数/秒

**重要度**: **memory_limiter発火時の最重要指標**

**注意**: 
- `otelcol_processor_dropped_*`メトリクスは現在のCollector設定では利用できません
- ログ関連のメトリクス（`otelcol_processor_refused_log_records_total`など）も利用できません
- **`refused`されたデータはドロップされ、失われます**（キューに入れられることも、次のバッチに回されることもありません）

**シナリオでの使用**:
- **シナリオ3**: Refusedが常に0より大きい（キャパシティ不足）

---

### 19. Processor: Incoming vs Outgoing Items (ID: 19)

**表示内容**: Processorへの入力と出力のレート（絶対値）

**役割**: **メモリへの影響を評価するため、絶対値で表示**

**クエリ**:
- `rate(otelcol_processor_incoming_items_total{job="otel-collector-self"}[1m])`
  - **説明**: Processorに入力されたアイテム数/秒

- `rate(otelcol_processor_outgoing_items_total{job="otel-collector-self"}[1m])`
  - **説明**: Processorから出力されたアイテム数/秒

**重要度**: **シナリオ3, 5, 6で重要**

**説明**: 入力と出力の差分が大きいほど、Processorでドロップされている。`otel.signal`ラベル（Grafanaでは`{{otel_signal}}`として表示）でtraces/metrics/logsを区別可能。

**補完関係**: ID: 15（Processor: Drop Rate）と**補完関係**。ID: 15は割合を表示し、相対的な影響度を評価する。メモリデバッグでは両方の視点が必要。

**シナリオでの使用**:
- **シナリオ3**: 入力が出力を常に上回る（キャパシティ不足）
- **シナリオ5**: 低スループットで高メモリ（巨大ペイロード）
- **シナリオ6**: 徐々に差が開く（高カーディナリティ）

---

### 12. Batch Processor: Triggers & Cardinality (ID: 12)

**表示内容**: Exporterのキューサイズと容量

**クエリ**:
- `otelcol_exporter_queue_size{job="otel-collector-self"}`
  - **説明**: 現在のキューサイズ（バッチ数）
  - **重要度**: **シナリオ1, 7の最重要指標**。上限に張り付くとメモリ高騰

- `otelcol_exporter_queue_capacity{job="otel-collector-self"}`
  - **説明**: キューの最大容量（設定値）

---

### 15. Processor: Drop Rate (ID: 15)

**表示内容**: Processorが処理中にドロップした割合（0.0-1.0）

**役割**: **相対的な影響度を評価するため、割合で表示**

**クエリ**:
- `(rate(otelcol_processor_incoming_items_total{job="otel-collector-self"}[1m]) - rate(otelcol_processor_outgoing_items_total{job="otel-collector-self"}[1m])) / rate(otelcol_processor_incoming_items_total{job="otel-collector-self"}[1m])`

**説明**: Processorへの入力レートと出力レートの差分からドロップ率を計算。`incoming - outgoing = ドロップされたアイテム数`。

**補完関係**: ID: 19（Processor: Incoming vs Outgoing Items）と**補完関係**。ID: 19は絶対値を表示し、メモリへの影響を直接評価する。メモリデバッグでは両方の視点が必要:
- **絶対値の差分が大きい** → メモリへの影響が大きい（Processor内で滞留）
- **割合が大きい** → Processorのキャパシティ不足を示す

**閾値**: Receiver: Drop Rateと同じ

**シナリオでの使用**:
- **シナリオ3**: memory_limiter発火時に上昇

---

## Exporter (送信)

Exporterセクションでは、Collectorが下流に送信したデータのスループット、キューサイズ、および送信失敗の割合を表示します。

### 9. Exporter: Spans Rate (ID: 9)

**表示内容**: Exporterが送信した/失敗したスパンのレート（絶対値）

**役割**: **メモリへの影響を評価するため、絶対値で表示**

**クエリ**:
- `rate(otelcol_exporter_sent_spans_total{job="otel-collector-self"}[1m])`
  - **説明**: 1分間で下流に正常に送信されたスパン数/秒

- `rate(otelcol_exporter_send_failed_spans_total{job="otel-collector-self"}[1m])`
  - **説明**: 1分間で送信に失敗したスパン数/秒（下流の障害時）

**補完関係**: ID: 16（Exporter: Failure Rate）と**補完関係**。ID: 16は割合を表示し、相対的な影響度を評価する。メモリデバッグでは両方の視点が必要。

**シナリオでの使用**:
- **シナリオ1**: Failedが100%になる（Jaeger停止時）
- **シナリオ7**: Failedが断続的に発生（ネットワーク不安定）

---

### 10. Exporter: Metric Points Rate (ID: 10)

**表示内容**: Exporterが送信した/失敗したメトリクスポイントのレート（絶対値）

**役割**: **メモリへの影響を評価するため、絶対値で表示**

**クエリ**:
- `rate(otelcol_exporter_sent_metric_points_total{job="otel-collector-self"}[1m])`
- `rate(otelcol_exporter_send_failed_metric_points_total{job="otel-collector-self"}[1m])`

**補完関係**: ID: 16（Exporter: Failure Rate）と**補完関係**。ID: 16は割合を表示し、相対的な影響度を評価する。メモリデバッグでは両方の視点が必要。

---

### 11. Exporter Queue Size / Capacity (ID: 11)

**表示内容**: Exporterのキューサイズと容量

**クエリ**:
- `otelcol_exporter_queue_size{job="otel-collector-self"}`
  - **説明**: 現在のキューサイズ（バッチ数）
  - **重要度**: **シナリオ1, 7の最重要指標**。上限に張り付くとメモリ高騰

- `otelcol_exporter_queue_capacity{job="otel-collector-self"}`
  - **説明**: キューの最大容量（設定値）

**シナリオでの使用**:
- **シナリオ1**: Queue Sizeが急激に上昇し、Capacity上限に張り付く
- **シナリオ7**: Queue Sizeがノコギリ波状になる（pause/unpauseの影響）

---

### 16. Exporter: Failure Rate (ID: 16)

**表示内容**: Exporterが送信に失敗した割合（0.0-1.0）

**役割**: **相対的な影響度を評価するため、割合で表示**

**クエリ**:
- Spans: `rate(otelcol_exporter_send_failed_spans_total{job="otel-collector-self"}[1m]) / (rate(otelcol_exporter_sent_spans_total{job="otel-collector-self"}[1m]) + rate(otelcol_exporter_send_failed_spans_total{job="otel-collector-self"}[1m]))`
- Metrics: `rate(otelcol_exporter_send_failed_metric_points_total{job="otel-collector-self"}[1m]) / (rate(otelcol_exporter_sent_metric_points_total{job="otel-collector-self"}[1m]) + rate(otelcol_exporter_send_failed_metric_points_total{job="otel-collector-self"}[1m]))`
- Logs: `rate(otelcol_exporter_send_failed_log_records_total{job="otel-collector-self"}[1m]) / (rate(otelcol_exporter_sent_log_records_total{job="otel-collector-self"}[1m]) + rate(otelcol_exporter_send_failed_log_records_total{job="otel-collector-self"}[1m]))`

**説明**: 送信成功と失敗の合計に対する失敗率。**ゼロサムゲーム**: `sent + failed = 送信を試みた総数`。

**補完関係**: ID: 9（Exporter: Spans Rate）、ID: 10（Exporter: Metric Points Rate）と**補完関係**。ID: 9/10は絶対値を表示し、メモリへの影響を直接評価する。メモリデバッグでは両方の視点が必要:
- **絶対値が大きい** → メモリへの影響が大きい（キューに滞留）
- **割合が大きい** → 下流の障害やネットワーク問題を示す

**閾値**: Receiver: Drop Rateと同じ

**シナリオでの使用**:
- **シナリオ1**: 下流（Jaeger等）が詰まると上昇
- **シナリオ7**: ネットワーク不安定時に断続的に上昇

**注意**: ログ関連のメトリクス（`otelcol_receiver_accepted_log_records_total`、`otelcol_exporter_sent_log_records_total`など）は、現在のCollector設定では利用できません。ログパイプラインは設定されていますが、これらのメトリクスはPrometheusにエクスポートされていません。

---

## Exporter (送信)

Exporterセクションでは、Collectorが下流に送信したデータのスループット、キューサイズ、および送信失敗の割合を表示します。

### 9. Exporter: Spans Rate (ID: 9)

**表示内容**: Exporterが送信に失敗した割合（0.0-1.0）

**役割**: **相対的な影響度を評価するため、割合で表示**

**クエリ**:
- Spans: `rate(otelcol_exporter_send_failed_spans_total{job="otel-collector-self"}[1m]) / (rate(otelcol_exporter_sent_spans_total{job="otel-collector-self"}[1m]) + rate(otelcol_exporter_send_failed_spans_total{job="otel-collector-self"}[1m]))`
- Metrics: `rate(otelcol_exporter_send_failed_metric_points_total{job="otel-collector-self"}[1m]) / (rate(otelcol_exporter_sent_metric_points_total{job="otel-collector-self"}[1m]) + rate(otelcol_exporter_send_failed_metric_points_total{job="otel-collector-self"}[1m]))`
- Logs: `rate(otelcol_exporter_send_failed_log_records_total{job="otel-collector-self"}[1m]) / (rate(otelcol_exporter_sent_log_records_total{job="otel-collector-self"}[1m]) + rate(otelcol_exporter_send_failed_log_records_total{job="otel-collector-self"}[1m]))`

**説明**: 送信成功と失敗の合計に対する失敗率。**ゼロサムゲーム**: `sent + failed = 送信を試みた総数`。

**補完関係**: ID: 9（Exporter: Spans Rate）、ID: 10（Exporter: Metric Points Rate）と**補完関係**。ID: 9/10は絶対値を表示し、メモリへの影響を直接評価する。メモリデバッグでは両方の視点が必要:
- **絶対値が大きい** → メモリへの影響が大きい（キューに滞留）
- **割合が大きい** → 下流の障害やネットワーク問題を示す

**閾値**: Receiver: Drop Rateと同じ

**シナリオでの使用**:
- **シナリオ1**: 下流（Jaeger等）が詰まると上昇
- **シナリオ7**: ネットワーク不安定時に断続的に上昇

**注意**: ログ関連のメトリクス（`otelcol_receiver_accepted_log_records_total`、`otelcol_exporter_sent_log_records_total`など）は、現在のCollector設定では利用できません。ログパイプラインは設定されていますが、これらのメトリクスはPrometheusにエクスポートされていません。

---

## GC & Runtime Metrics

### 20. GC Count Rate (ID: 20)

**表示内容**: GC（ガベージコレクション）の実行回数/秒

**クエリ**:
- `rate(go_memstats_gc_count_total{job="otel-collector-self"}[1m])`
  - **説明**: 1分間で実行されたGC回数のレート
  - **単位**: ops/sec

**重要度**: **シナリオ2（スパイク）で重要**

**説明**: GC回数が急増すると、メモリ確保と解放が頻発していることを示す。

**シナリオでの使用**:
- **シナリオ2**: スパイク時に急増する（メモリ確保と解放が頻発）

**注意**: このメトリクスはGoランタイムのメトリクスエンドポイントが公開されている場合のみ利用可能です。データが存在しない場合はパネルにエラーが表示されます。

---

### 21. GC CPU Fraction (ID: 21)

**表示内容**: GCに費やされたCPU時間の割合

**クエリ**:
- `rate(go_memstats_gc_cpu_fraction{job="otel-collector-self"}[1m])`
  - **説明**: GC処理に使われたCPU時間の割合（0.0-1.0）
  - **単位**: percentunit

**閾値**:
- 🟢 Green: < 10%
- 🟡 Yellow: ≥ 10%
- 🟠 Orange: ≥ 20%
- 🔴 Red: ≥ 30%

**説明**: 高いほどGC負荷が大きく、アプリケーション処理に使えるCPU時間が少ない。

**注意**: このメトリクスはGoランタイムのメトリクスエンドポイントが公開されている場合のみ利用可能です。

---

## クエリの共通パターン

### レート計算
多くのクエリで `rate(...[1m])` を使用しています。これは1分間の移動平均レートを計算します。

### ラベル
- `job="otel-collector-self"`: Collectorのセルフテレメトリメトリクスを指定
- `{{receiver}}`, `{{exporter}}`, `{{processor}}`: 各コンポーネント名が動的に展開される
- `{{data_type}}`: `traces`, `metrics`, `logs` のいずれか（Exporter Queue関連）
- `{{otel_signal}}`: `traces`, `metrics` のいずれか（Processor関連。Prometheusでは`otel.signal`として保存されるが、Grafanaでは`{{otel_signal}}`として参照可能）

**注意**: ログ関連のメトリクスは現在のCollector設定では利用できません。ログパイプラインは設定されていますが、receiver/exporterのメトリクスはエクスポートされていません。

### メトリクス名の命名規則
- `otelcol_receiver_*`: Receiver関連
- `otelcol_processor_*`: Processor関連
- `otelcol_exporter_*`: Exporter関連
- `otelcol_process_*`: プロセス全体のメトリクス
- `go_memstats_*`: Goランタイムのメトリクス（利用可能な場合）

---

## シナリオ別の主要メトリクス

各シナリオで特に注目すべきメトリクスをまとめます。

| シナリオ | 主要メトリクス | パネルID |
|---------|--------------|---------|
| 1. 下流停止 | Queue Size, Failure Rate | 11, 16 |
| 2. スパイク | Heap上下動, GC Count | 1, 20 |
| 3. キャパシティ不足 | Heap上限張り付き, Refused Spans | 1, 13 |
| 4. メモリリーク | RSS右肩上がり, Heap一定 | 2, 4 |
| 5. 巨大ペイロード | 低スループットで高メモリ | 1, 19 |
| 6. 高カーディナリティ | Heap徐々に増加 | 1, 19 |
| 7. ネットワーク不安定 | Queueノコギリ波 | 11 |
| 8. CPU制限 | CPU 100% | 6 |
| 9. ログ大量送信 | Queue Size (logs) | 11 |
| 10. 設定ミス | Heapノコギリ波, Batch Size | 1, 12 |

---

## 実際に利用可能なメトリクス一覧

現在のPrometheusで実際に利用可能なメトリクス（2024年12月時点）:

### Process Metrics
- `otelcol_process_cpu_seconds_total`
- `otelcol_process_memory_rss_bytes`
- `otelcol_process_runtime_heap_alloc_bytes`
- `otelcol_process_runtime_total_alloc_bytes_total`
- `otelcol_process_runtime_total_sys_memory_bytes`
- `otelcol_process_uptime_seconds_total`

### Receiver Metrics
- `otelcol_receiver_accepted_spans_total`
- `otelcol_receiver_accepted_metric_points_total`
- `otelcol_receiver_refused_spans_total`
- `otelcol_receiver_refused_metric_points_total`
- `otelcol_receiver_failed_spans_total`
- `otelcol_receiver_failed_metric_points_total`

### Processor Metrics
- `otelcol_processor_accepted_spans_total`
- `otelcol_processor_accepted_metric_points_total`
- `otelcol_processor_refused_spans_total`
- `otelcol_processor_refused_metric_points_total`
- `otelcol_processor_incoming_items_total`
- `otelcol_processor_outgoing_items_total`
- `otelcol_processor_batch_batch_size_trigger_send_total`
- `otelcol_processor_batch_timeout_trigger_send_total`
- `otelcol_processor_batch_metadata_cardinality`
- `otelcol_processor_batch_batch_send_size_sum` (ヒストグラム)
- `otelcol_processor_batch_batch_send_size_count` (ヒストグラム)

### Exporter Metrics
- `otelcol_exporter_sent_spans_total`
- `otelcol_exporter_sent_metric_points_total`
- `otelcol_exporter_send_failed_spans_total`
- `otelcol_exporter_send_failed_metric_points_total`
- `otelcol_exporter_queue_size`
- `otelcol_exporter_queue_capacity`
- `otelcol_exporter_queue_batch_send_size_sum` (ヒストグラム)
- `otelcol_exporter_queue_batch_send_size_count` (ヒストグラム)

### 利用できないメトリクス
以下のメトリクスは現在のCollector設定では利用できません:
- `otelcol_receiver_accepted_log_records_total`
- `otelcol_receiver_refused_log_records_total`
- `otelcol_exporter_sent_log_records_total`
- `otelcol_exporter_send_failed_log_records_total`
- `otelcol_processor_refused_log_records_total`
- `otelcol_processor_dropped_*` (すべてのデータタイプ)
- `go_memstats_*` (Goランタイムメトリクス)

---

## 参考リンク

- [OpenTelemetry Collector Internal Telemetry](https://opentelemetry.io/docs/collector/internal-telemetry/)
- [Prometheus Query Language (PromQL)](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [scenario.md](../scenario.md) - 各シナリオの詳細説明
