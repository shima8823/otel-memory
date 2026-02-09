# ベストプラクティス: OTel Collector のメモリ管理

## 1. 設計原則

メモリ高騰を防ぐための 3 つの原則:

1. **制限を先頭に置く**: `memory_limiter` は常にパイプラインの最初の processor
2. **ステートフルを疑う**: 内部状態を持つ processor/connector は必ずカーディナリティを確認
3. **バッファを見積もる**: 時間軸の保持（`decision_wait`, `timeout`）はメモリ消費に直結

## 2. Memory Limiter

### 推奨設定

```yaml
processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 20
```

### パラメータ解説

| パラメータ | 推奨値 | 根拠 |
| --- | --- | --- |
| `check_interval` | `1s` | 1秒間隔で十分。短くしすぎると CPU 消費が増える |
| `limit_percentage` | `80` | 残り 20% を GC とスパイク吸収に確保。公式推奨 |
| `spike_limit_percentage` | `20` | `limit_percentage` と合わせて 100% にはしない。急増時の余裕 |

### 配置ルール

- パイプラインの **最初の processor** に置く
- ステートフル processor（`tail_sampling`, `groupbyattrs` 等）の **前** に置く
- `memory_limiter` は受信拒否で流量を制御するため、後段に置くと効果が薄い

参照: <https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md>

## 3. Batch Processor

### 推奨設定

```yaml
processors:
  batch:
    send_batch_size: 8192
    timeout: 200ms
```

### パラメータ解説

| パラメータ | 推奨値 | トレードオフ |
| --- | --- | --- |
| `send_batch_size` | `8192` | 大きくするとスループット向上だがメモリ消費増。小さくするとオーバーヘッド増 |
| `send_batch_max_size` | `0`（無制限）または `send_batch_size * 2` | 上限を設けるとバッファ制御可能だが、分割処理のコスト発生 |
| `timeout` | `200ms` | 短くするとレイテンシ向上だがバッチ効率低下。長くするとメモリ保持時間増 |

### メモリへの影響

- `batch` は `timeout` の間にデータをバッファする
- `send_batch_size × 平均データサイズ` がバッチ 1 つあたりのメモリ消費
- メモリ制約が厳しい場合は `send_batch_max_size` で上限を設ける

参照: <https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/batchprocessor>

## 4. Sending Queue (Exporter)

### 推奨設定

```yaml
exporters:
  otlp:
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 1000
    retry_on_failure:
      enabled: true
```

### パラメータ解説

| パラメータ | 推奨値 | トレードオフ |
| --- | --- | --- |
| `queue_size` | `1000` | 大きくすると下流障害時のバッファ増だがメモリ消費増。小さくするとドロップ早発 |
| `num_consumers` | `10` | 並列送信数。大きくすると下流への負荷増。小さくするとキュー滞留 |

### メモリ見積もり

```text
Queue メモリ ≈ queue_size × 平均バッチサイズ
```

下流が停止すると `queue_size` まで蓄積されるため、最悪ケースのメモリを見積もること。

参照: <https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md>

## 5. ステートフル Processor の注意事項

### Tail Sampling

```text
メモリ ≈ decision_wait × スループット × 平均スパンサイズ × ~6（Go runtime 倍率）
```

- `decision_wait` は必要最小限に設定（推奨: `10s` 以下）
- `num_traces` はメモリ予算から逆算
- 100% サンプリング（`always_sample`）は避け、目的に応じたポリシーを使う

### groupbyattrs / spanmetrics

- `keys` / `dimensions` に指定する属性のカーディナリティを事前確認
- 目安: 1時間で 1,000 種類以下 = 安全、10,000 以上 = 危険
- `UUID`, `request_id`, `session_id` などは絶対に含めない
- `dimensions_cache_size` を適切に設定してメモリ上限を制御

参照:
- <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor>
- <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/groupbyattrsprocessor>
- <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/spanmetricsconnector>

## 6. 監視アラート設定テンプレート

### Heap メモリ異常上昇

```promql
# Heap が5分間で継続的に上昇している場合
increase(otelcol_process_runtime_heap_alloc_bytes[5m]) > 50 * 1024 * 1024
```

### Receiver 拒否の発生

```promql
# Refused が発生したらアラート
rate(otelcol_receiver_refused_spans_total[5m]) > 0
```

### スループット低下

```promql
# 直近1分の受信レートが5分前と比べて20%以上低下
rate(otelcol_receiver_accepted_spans_total[1m])
  <
rate(otelcol_receiver_accepted_spans_total[5m] offset 5m) * 0.8
```

### Queue 飽和

```promql
# Queue usage が 90% 以上
otelcol_exporter_queue_size / otelcol_exporter_queue_capacity > 0.9
```

## 7. 安全なベースライン設定テンプレート

以下は本プロジェクトで検証済みのベースライン設定。
メモリ制限 256MB のコンテナで安定稼働する構成。

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 20
  batch:
    send_batch_size: 8192
    timeout: 200ms

exporters:
  otlp:
    endpoint: backend:4317
    tls:
      insecure: true
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 1000
    retry_on_failure:
      enabled: true

extensions:
  pprof:
    endpoint: 0.0.0.0:1777

service:
  extensions: [pprof]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp]
```

ポイント:

- `memory_limiter` が最初の processor
- ステートフル processor なし（安全なベースライン）
- `pprof` extension を有効化（本番でも有効にしておくと障害時に助かる）
- `sending_queue` でキュー制御
