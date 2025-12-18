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
  - **重要**: **`refused`されたデータはドロップされ、失われます**（キューに入れられることも、次のバッチに回されることもありません）

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

### 17. Receiver: Log Records Rate (ID: 17)

**表示内容**: Receiverが受け入れた/拒否したログレコードのレート（絶対値）

**役割**: **メモリへの影響を評価するため、絶対値で表示**

**クエリ**:
- `rate(otelcol_receiver_accepted_log_records_total{job="otel-collector-self"}[1m])`
  - **説明**: 1分間でパイプラインに受け入れられたログレコード数/秒
  - **単位**: ops/sec

- `rate(otelcol_receiver_refused_log_records_total{job="otel-collector-self"}[1m])`
  - **説明**: 1分間でパイプラインに拒否されたログレコード数/秒（memory_limiter発火時）
  - **単位**: ops/sec
  - **重要**: **`refused`されたログはドロップされ、失われます**。監査ログなど重要な情報が欠損する可能性があります。

**補完関係**: ID: 14（Receiver: Drop Rate）と**補完関係**。ID: 14は割合を表示し、相対的な影響度を評価する。メモリデバッグでは両方の視点が必要。

**シナリオでの使用**:
- **シナリオ3**: Refusedが常に0より大きい（キャパシティ不足）
- **シナリオ9**: ログ大量送信時のメモリ影響を確認

---

### 14. Receiver: Drop Rate (ID: 14)

**表示内容**: Receiverがデータを拒否した割合（0.0-1.0）

**役割**: **相対的な影響度を評価するため、割合で表示**

**クエリ**:
- Spans: `rate(otelcol_receiver_refused_spans_total{job="otel-collector-self"}[1m]) / (rate(otelcol_receiver_accepted_spans_total{job="otel-collector-self"}[1m]) + rate(otelcol_receiver_refused_spans_total{job="otel-collector-self"}[1m]))`
- Metrics: `rate(otelcol_receiver_refused_metric_points_total{job="otel-collector-self"}[1m]) / (rate(otelcol_receiver_accepted_metric_points_total{job="otel-collector-self"}[1m]) + rate(otelcol_receiver_refused_metric_points_total{job="otel-collector-self"}[1m]))`
- Logs: `rate(otelcol_receiver_refused_log_records_total{job="otel-collector-self"}[1m]) / (rate(otelcol_receiver_accepted_log_records_total{job="otel-collector-self"}[1m]) + rate(otelcol_receiver_refused_log_records_total{job="otel-collector-self"}[1m]))`

**注意**: ログ関連のメトリクスは、実際にログを送信してから生成されます。

**説明**: 受け入れられたデータと拒否されたデータの合計に対する拒否率。**ゼロサムゲーム**: `accepted + refused = 正常に受信できた総数`（`failed` は受信処理自体が失敗したものなので別カテゴリ）。**`refused`されたデータはドロップされ、失われます**（キューに入れられることも、次のバッチに回されることもありません）。

**なぜ割合が必要か**:
- **相対的な影響度が分かる**: 10%拒否されている、など
- **閾値設定がしやすい**: 1%以上で警告、など
- **メモリ制限の影響を直感的に理解**: システムのキャパシティ不足を示す

**補完関係**: ID: 7（Receiver: Spans Rate）、ID: 8（Receiver: Metric Points Rate）、ID: 17（Receiver: Log Records Rate）と**補完関係**。ID: 7/8/17は絶対値を表示し、メモリへの影響を直接評価する。メモリデバッグでは両方の視点が必要:
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
- **シナリオ9**: ログ大量送信時のドロップ率を確認

---

## Processor (処理)

Processorセクションでは、Processorが処理したデータのスループット、バッチ処理の状態、およびメモリ制限により拒否されたデータの割合を表示します。

**重要**: メモリ高騰デバッグでは、**`accepted/refused`系メトリクスを主要指標として使用**し、`incoming/outgoing`系メトリクスは補完的な情報として使用します。

- **`accepted/refused`系**: `memory_limiter`が明示的に拒否したデータを直接追跡。メモリ制限に達した際の直接的な証拠。**主要指標として使用**。
- **`incoming/outgoing`系**: Processor全体の入出力を追跡。`refused`以外の要因（エラー、フィルタリング、バッチ処理の遅延など）も含む。**補完的な情報として使用**（メモリ以外の原因を発見するために）。

### 20. Processor: Spans Rate (ID: 20)

**表示内容**: Processorが受け入れた/拒否したスパンのレート（絶対値）

**役割**: **メモリへの影響を評価するため、絶対値で表示**

**クエリ**:
- `rate(otelcol_processor_accepted_spans_total{job="otel-collector-self"}[1m])`
  - **説明**: 1分間でProcessorが受け入れたスパン数/秒

- `rate(otelcol_processor_refused_spans_total{job="otel-collector-self"}[1m])`
  - **説明**: 1分間でProcessorが拒否したスパン数/秒（memory_limiter発火時）
  - **重要**: **`refused`されたデータはドロップされ、失われます**（キューに入れられることも、次のバッチに回されることもありません）

**補完関係**: ID: 15（Processor: Drop Rate）と**補完関係**。ID: 15は割合を表示し、相対的な影響度を評価する。メモリデバッグでは両方の視点が必要。

**シナリオでの使用**:
- **シナリオ3**: Refusedが常に0より大きい（キャパシティ不足）

---

### 21. Processor: Metric Points Rate (ID: 21)

**表示内容**: Processorが受け入れた/拒否したメトリクスポイントのレート（絶対値）

**役割**: **メモリへの影響を評価するため、絶対値で表示**

**クエリ**:
- `rate(otelcol_processor_accepted_metric_points_total{job="otel-collector-self"}[1m])`
- `rate(otelcol_processor_refused_metric_points_total{job="otel-collector-self"}[1m])`

**補完関係**: ID: 15（Processor: Drop Rate）と**補完関係**。ID: 15は割合を表示し、相対的な影響度を評価する。メモリデバッグでは両方の視点が必要。

---

### 22. Processor: Log Records Rate (ID: 22)

**表示内容**: Processorが受け入れた/拒否したログレコードのレート（絶対値）

**役割**: **メモリへの影響を評価するため、絶対値で表示**

**クエリ**:
- `rate(otelcol_processor_accepted_log_records_total{job="otel-collector-self"}[1m])`
  - **説明**: 1分間でProcessorが受け入れたログレコード数/秒

- `rate(otelcol_processor_refused_log_records_total{job="otel-collector-self"}[1m])`
  - **説明**: 1分間でProcessorが拒否したログレコード数/秒（memory_limiter発火時）
  - **重要**: **`refused`されたログはドロップされ、失われます**

**補完関係**: ID: 15（Processor: Drop Rate）と**補完関係**。ID: 15は割合を表示し、相対的な影響度を評価する。メモリデバッグでは両方の視点が必要。

**シナリオでの使用**:
- **シナリオ3**: Refusedが常に0より大きい（キャパシティ不足）
- **シナリオ9**: ログ大量送信時のRefusedを確認

---

### 15. Processor: Drop Rate (ID: 15)

**表示内容**: Processorがデータを拒否した割合（0.0-1.0）

**役割**: **相対的な影響度を評価するため、割合で表示**

**クエリ**:
- Spans: `rate(otelcol_processor_refused_spans_total{job="otel-collector-self"}[1m]) / (rate(otelcol_processor_accepted_spans_total{job="otel-collector-self"}[1m]) + rate(otelcol_processor_refused_spans_total{job="otel-collector-self"}[1m]))`
- Metrics: `rate(otelcol_processor_refused_metric_points_total{job="otel-collector-self"}[1m]) / (rate(otelcol_processor_accepted_metric_points_total{job="otel-collector-self"}[1m]) + rate(otelcol_processor_refused_metric_points_total{job="otel-collector-self"}[1m]))`
- Logs: `rate(otelcol_processor_refused_log_records_total{job="otel-collector-self"}[1m]) / (rate(otelcol_processor_accepted_log_records_total{job="otel-collector-self"}[1m]) + rate(otelcol_processor_refused_log_records_total{job="otel-collector-self"}[1m]))`

**説明**: 受け入れられたデータと拒否されたデータの合計に対する拒否率。**ゼロサムゲーム**: `accepted + refused = 正常に処理できた総数`。**`refused`されたデータはドロップされ、失われます**。

**補完関係**: ID: 20（Processor: Spans Rate）、ID: 21（Processor: Metric Points Rate）、ID: 22（Processor: Log Records Rate）と**補完関係**。ID: 20/21/22は絶対値を表示し、メモリへの影響を直接評価する。メモリデバッグでは両方の視点が必要:
- **絶対値が大きい** → メモリへの影響が大きい
- **割合が大きい** → システムのキャパシティ不足を示す

**閾値**: Receiver: Drop Rateと同じ

**シナリオでの使用**:
- **シナリオ3**: memory_limiter発火時に上昇

---

### 12. Batch Processor: Triggers & Cardinality (ID: 12)

**表示内容**: Batchプロセッサのトリガーとメタデータカーディナリティ

**クエリ**:
- `rate(otelcol_processor_batch_batch_size_trigger_send_total{job="otel-collector-self"}[1m])`
  - **説明**: バッチサイズが上限に達して送信がトリガーされた回数/秒

- `rate(otelcol_processor_batch_timeout_trigger_send_total{job="otel-collector-self"}[1m])`
  - **説明**: タイムアウトによって送信がトリガーされた回数/秒

- `otelcol_processor_batch_metadata_cardinality{job="otel-collector-self"}`
  - **説明**: バッチプロセッサが処理している異なるメタデータ値の組み合わせ数
  - **重要度**: カーディナリティが高いほど、メモリ使用量が増加する可能性

**シナリオでの使用**:
- **シナリオ10**: バッチサイズトリガーが頻繁に発生する（設定が不適切な場合）

---

### 23. Batch Processor: Average Batch Size (ID: 23)

**表示内容**: 実際に送信されたバッチの平均サイズ

**役割**: **メモリ高騰デバッグの最重要指標**

**クエリ**:
- `rate(otelcol_processor_batch_batch_send_size_sum{job="otel-collector-self"}[1m]) / rate(otelcol_processor_batch_batch_send_size_count{job="otel-collector-self"}[1m])`
  - **説明**: 実際に送信されたバッチの平均サイズ（アイテム数）
  - **単位**: アイテム数

**重要度**: **メモリ高騰デバッグにおいて最重要**

**使用方法**:
- **設定値（`send_batch_size`）と比較**: 平均バッチサイズが設定値に近い → バッチが満たされてから送信（正常）
- **平均バッチサイズが設定値より小さい**: タイムアウトで送信（低スループット、メモリへの影響は小さい）
- **平均バッチサイズが設定値より大きい**: `send_batch_max_size`に達している可能性（メモリ消費が大きい）
- **平均バッチサイズが設定値より大幅に大きい**: 設定ミス（シナリオ10）

**シナリオでの使用**:
- **シナリオ10**: 設定ミスで巨大なバッチサイズがメモリ高騰の原因になっている場合、平均バッチサイズが異常に大きい値を示す

---

### 24. Batch Processor: 95th Percentile Batch Size (ID: 24)

**表示内容**: 実際に送信されたバッチの95パーセンタイルサイズ

**役割**: **スパイク時のメモリ消費を把握**

**クエリ**:
- `histogram_quantile(0.95, rate(otelcol_processor_batch_batch_send_size_bucket{job="otel-collector-self"}[1m]))`
  - **説明**: 実際に送信されたバッチの95パーセンタイルサイズ（アイテム数）
  - **単位**: アイテム数

**重要度**: **平均バッチサイズの補完指標**

**使用方法**:
- **平均は低くても95パーセンタイルが高い場合**: 間欠的なメモリ高騰の原因になる可能性
- **平均と95パーセンタイルの差が大きい**: バッチサイズの変動が大きく、メモリ使用量が不安定

**シナリオでの使用**:
- **シナリオ2**: スパイク時に95パーセンタイルが急上昇する
- **シナリオ10**: 設定ミスで95パーセンタイルが異常に大きい値を示す

---

### 25. Batch Processor: Metadata Cardinality (ID: 25)

**表示内容**: バッチプロセッサが処理している異なるメタデータ値の組み合わせ数

**役割**: **高カーディナリティによるメモリ消費を把握**

**クエリ**:
- `otelcol_processor_batch_metadata_cardinality{job="otel-collector-self"}`
  - **説明**: バッチプロセッサが処理している異なるメタデータ値の組み合わせ数
  - **単位**: 組み合わせ数

**重要度**: **シナリオ6（高カーディナリティ）で重要**

**使用方法**:
- **カーディナリティが高い**: 異なるメタデータの組み合わせが多いほど、バッチが分割され、メモリ使用量が増加する
- **カーディナリティが右肩上がり**: メモリリークの可能性（メタデータが蓄積されている）

**シナリオでの使用**:
- **シナリオ6**: 高カーディナリティでメモリが徐々に増加する場合、カーディナリティが高い値を示す

---

### 26. Batch Processor: Size Trigger vs Timeout Trigger (ID: 26)

**表示内容**: バッチサイズトリガーとタイムアウトトリガーのレート

**役割**: **バッチ送信のトリガー原因を把握**

**クエリ**:
- `rate(otelcol_processor_batch_batch_size_trigger_send_total{job="otel-collector-self"}[1m])`
  - **説明**: バッチサイズが上限に達して送信がトリガーされた回数/秒

- `rate(otelcol_processor_batch_timeout_trigger_send_total{job="otel-collector-self"}[1m])`
  - **説明**: タイムアウトによって送信がトリガーされた回数/秒

**重要度**: **補完的な情報**

**使用方法**:
- **バッチサイズトリガーが多い**: バッチサイズが大きすぎる可能性（メモリ消費が大きい）
- **タイムアウトトリガーが多い**: バッチが満たされる前にタイムアウト（低スループット、メモリへの影響は小さい）
- **両方のトリガーがバランス良く発生**: 正常な動作

**シナリオでの使用**:
- **シナリオ10**: 設定ミスでバッチサイズトリガーが頻繁に発生する

---

### 27. Processor: Out/In Ratio (ID: 27)

**表示内容**: Processorを通過したアイテムの割合（0.0-1.0）

**役割**: **トラフィックが「どこで」詰まっているかを特定する**

**クエリ**:
- `sum by (processor, "otel.signal") (rate(otelcol_processor_outgoing_items_total{job="otel-collector-self"}[1m])) / clamp_min(sum by (processor, "otel.signal") (rate(otelcol_processor_incoming_items_total{job="otel-collector-self"}[1m])), 1)`
  - **説明**: 入力アイテム数に対する出力アイテム数の比率
  - **clamp_min**: トラフィックが0の際のゼロ除算（NaN）を防ぐための処理

**重要度**: **デバッグ時の位置特定に有用**

**見方**:
- **1.0付近**: データが加工されずに素通りしている
- **1.0より大幅に低い**: そのProcessorでデータが「滞留」または「フィルタリング/サンプリング」されている
- **1.0より高い**: Processor内でデータが増幅（複製や分割）されている

**注意**: `filter` や `probabilistic_sampler` などのProcessorは、意図的に1.0未満になるのが正常動作です。

---

### 28. Processor: Net Reduction (ID: 28)

**表示内容**: Processorで失われた/削減されたアイテムの絶対量

**役割**: **滞留・消失による「メモリへのインパクト」を評価する**

**クエリ**:
- `sum by (processor, "otel.signal") (rate(otelcol_processor_incoming_items_total{job="otel-collector-self"}[1m])) - sum by (processor, "otel.signal") (rate(otelcol_processor_outgoing_items_total{job="otel-collector-self"}[1m]))`
  - **説明**: 入力アイテム数と出力アイテム数の差分

**重要度**: **メモリ高騰の規模を把握するために重要**

**見方**:
- **値がプラスに大きい**: そのProcessorで大量のデータが失われているか、内部に溜まっている
- **Ratio(ID:27)と併用**: Ratioが低くてもこの値（絶対量）が小さければ、メモリへの影響は軽微と判断できる

**シナリオでの使用**:
- **シナリオ3**: メモリ制限によりデータが大量にドロップされている場合、ここが大きな正の値を示す
- **シナリオ5**: 巨大なペイロードがProcessorで処理しきれず滞留している場合

---


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

### 18. Exporter: Log Records Rate (ID: 18)

**表示内容**: Exporterが送信した/失敗したログレコードのレート（絶対値）

**役割**: **メモリへの影響を評価するため、絶対値で表示**

**クエリ**:
- `rate(otelcol_exporter_sent_log_records_total{job="otel-collector-self"}[1m])`
  - **説明**: 1分間で下流に正常に送信されたログレコード数/秒

- `rate(otelcol_exporter_send_failed_log_records_total{job="otel-collector-self"}[1m])`
  - **説明**: 1分間で送信に失敗したログレコード数/秒（下流の障害時）

**補完関係**: ID: 16（Exporter: Failure Rate）と**補完関係**。ID: 16は割合を表示し、相対的な影響度を評価する。メモリデバッグでは両方の視点が必要。

**シナリオでの使用**:
- **シナリオ1**: Failedが100%になる（下流停止時）
- **シナリオ7**: Failedが断続的に発生（ネットワーク不安定）
- **シナリオ9**: ログ大量送信時の送信状況を確認

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

**補完関係**: ID: 9（Exporter: Spans Rate）、ID: 10（Exporter: Metric Points Rate）、ID: 18（Exporter: Log Records Rate）と**補完関係**。ID: 9/10/18は絶対値を表示し、メモリへの影響を直接評価する。メモリデバッグでは両方の視点が必要:
- **絶対値が大きい** → メモリへの影響が大きい（キューに滞留）
- **割合が大きい** → 下流の障害やネットワーク問題を示す

**閾値**: Receiver: Drop Rateと同じ

**シナリオでの使用**:
- **シナリオ1**: 下流（Jaeger等）が詰まると上昇
- **シナリオ7**: ネットワーク不安定時に断続的に上昇

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
- `{{otel_signal}}`: `traces`, `metrics`, `logs` のいずれか（Processor関連。Prometheusでは`otel.signal`として保存されるが、Grafanaでは`{{otel_signal}}`として参照可能）

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
| 3. キャパシティ不足 | Heap上限張り付き, Refused Items, Net Reduction | 1, 20-22, 28 |
| 4. メモリリーク | RSS右肩上がり, Heap一定 | 2, 4 |
| 5. 巨大ペイロード | 低スループットで高メモリ, Net Reduction | 1, 28 |
| 6. 高カーディナリティ | Heap徐々に増加, Metadata Cardinality | 1, 25 |
| 7. ネットワーク不安定 | Queueノコギリ波 | 11 |
| 8. CPU制限 | CPU 100% | 6 |
| 9. ログ大量送信 | Log Records Rate, Drop Rate | 17, 14, 16 |
| 10. 設定ミス | Heapノコギリ波, Batch Size, Ratio | 1, 23, 27 |

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
- `otelcol_receiver_accepted_log_records_total` ✅
- `otelcol_receiver_refused_spans_total`
- `otelcol_receiver_refused_metric_points_total`
- `otelcol_receiver_refused_log_records_total` ✅
- `otelcol_receiver_failed_spans_total`
- `otelcol_receiver_failed_metric_points_total`
- `otelcol_receiver_failed_log_records_total` ✅

### Processor Metrics
- `otelcol_processor_accepted_spans_total`
- `otelcol_processor_accepted_metric_points_total`
- `otelcol_processor_accepted_log_records_total` ✅
- `otelcol_processor_refused_spans_total`
- `otelcol_processor_refused_metric_points_total`
- `otelcol_processor_refused_log_records_total` ✅
- `otelcol_processor_incoming_items_total` (Spans、Metrics、Logsを含む)
- `otelcol_processor_outgoing_items_total` (Spans、Metrics、Logsを含む)
- `otelcol_processor_batch_batch_size_trigger_send_total`
- `otelcol_processor_batch_timeout_trigger_send_total`
- `otelcol_processor_batch_metadata_cardinality`
- `otelcol_processor_batch_batch_send_size_sum` (ヒストグラム)
- `otelcol_processor_batch_batch_send_size_count` (ヒストグラム)

### Exporter Metrics
- `otelcol_exporter_sent_spans_total`
- `otelcol_exporter_sent_metric_points_total`
- `otelcol_exporter_sent_log_records_total` ✅
- `otelcol_exporter_send_failed_spans_total`
- `otelcol_exporter_send_failed_metric_points_total`
- `otelcol_exporter_send_failed_log_records_total` ✅
- `otelcol_exporter_queue_size`
- `otelcol_exporter_queue_capacity`
- `otelcol_exporter_queue_batch_send_size_sum` (ヒストグラム)
- `otelcol_exporter_queue_batch_send_size_count` (ヒストグラム)

### 利用できないメトリクス
以下のメトリクスは現在のCollector設定では利用できません:
- `otelcol_processor_dropped_*` (すべてのデータタイプ)
- `go_memstats_*` (Goランタイムメトリクス - 設定により利用可能な場合あり)

---

## 参考リンク

- [OpenTelemetry Collector Internal Telemetry](https://opentelemetry.io/docs/collector/internal-telemetry/)
- [Prometheus Query Language (PromQL)](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [scenario.md](../scenario.md) - 各シナリオの詳細説明
