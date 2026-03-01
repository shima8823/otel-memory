## 1. 概要

Exporter の `sending_queue` は batch 単位でエントリを保持するため、`send_batch_size × queue_size × スパンサイズ` の掛け算がメモリ上限を決定する。
このレポートでは、大きな batch/queue 設定（非最適化）と適切なサイズに縮小した設定（最適化）の2条件で、同一の下流遅延を与え、メモリ挙動の違いを Grafana メトリクスで観測・比較する。

**核心**: `send_batch_size` と `queue_size` は個別には妥当に見えても、掛け算の結果がコンテナのメモリ予算を超過する「掛け算の罠」がある。

## 2. 再現手順

### 2.1 Collector 設定（非最適化 — 問題設定）

```yaml
processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 20

  batch:
    send_batch_size: 8192
    timeout: 5s

exporters:
  otlp:
    sending_queue:
      num_consumers: 10
      queue_size: 500
    retry_on_failure:
      enabled: true
```

ポイント:
- `send_batch_size: 8192` は OTel デフォルト値。バッチサイズ自体は問題ない
- `queue_size: 500` は「余裕を持たせた」設定だが、batch_size との掛け算を考慮していない
- 理論最大メモリ: `8192 × 500 × ~580B ≈ 2.4GB`（コンテナ制限 512MB の約5倍）
- `timeout: 5s` はバッチを満杯にするための効率重視の設定

### 2.2 Collector 設定（最適化）

```yaml
processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 20

  batch:
    send_batch_size: 2048
    send_batch_max_size: 4096
    timeout: 200ms

exporters:
  otlp:
    sending_queue:
      num_consumers: 10
      queue_size: 50
    retry_on_failure:
      enabled: true
```

最適化のポイント:
- `send_batch_size: 8192 → 2048`（4倍削減）
- `queue_size: 500 → 50`（10倍削減）
- 理論最大メモリ: `2048 × 50 × ~580B ≈ 59MB`（コンテナに余裕で収まる）
- `send_batch_max_size: 4096` で oversized batch を防止
- `timeout: 200ms`（OTel デフォルト値に戻す）

### 2.3 下流障害の模擬

Jaeger の CPU を制限して「バックエンドが動いているが遅い」状態を作る（`docker-compose.batch-queue.yaml`）:

```yaml
services:
  jaeger:
    command: ["--memory.max-traces=50000"]
    deploy:
      resources:
        limits:
          cpus: '0.2'
          memory: 2G
```

- `--memory.max-traces=50000`: Jaeger がメモリを固定し完全停止を防ぐ
- `cpus: 0.2`: CPU 制限で処理速度を低下させ、queue 滞留を促進
- 本番でよくある状況: Kubernetes の CPU throttle、Noisy Neighbor、ストレージ I/O 待ち

### 2.4 負荷条件

両シナリオ共通:

```
Rate:             4,000 traces/sec/worker
Workers:          10
Child Spans:      3（1トレース = 4スパン）
Duration:         180s
Span Size:        ~580B（padding属性で本番サイズを模倣）
Container Memory: 512 MB
```

実行コマンド:

```bash
# 非最適化（batch=8192, queue=500）
make run-batch-queue

# 最適化（batch=2048, queue=50）
make run-batch-queue-optimized
```

## 3. Grafana での観測

### 3.1 Heap Memory の挙動

#### 非最適化（batch=8192, queue=500）

![Heap Memory — 非最適化](./images/heap-non-optimized.png)

負荷開始後、Heap が急騰し soft_limit（307MB）を超過。GC サイクルによる振動を繰り返すが、常時 soft_limit 付近に張り付く。

| フェーズ | 時間 | Heap | 説明 |
|---------|------|------|------|
| アイドル | 16:33-16:34 | 19-22 MB | 正常動作 |
| 負荷開始直後 | 16:35:06 | 287 MB | 20 MB から約14倍に急騰 |
| ピーク | 16:37:51 | 344 MB | soft_limit 307MB を 37MB 超過 |
| 負荷中定常 | 16:35:21-16:38:06 | 232-344 MB | GC 振動。soft_limit を頻繁に超過 |
| 負荷終了後 | 16:38:21 | 25 MB | queue が drain されベースラインに復帰 |

特徴: Heap が 230-344MB で振動し、soft_limit（307MB）を繰り返し超過する。

#### 最適化（batch=2048, queue=50）

![Heap Memory — 最適化](./images/heap-optimized.png)

Heap は上昇するが soft_limit 以下に収まり、memory_limiter が発火しない。

| フェーズ | 時間 | Heap | 説明 |
|---------|------|------|------|
| アイドル | 17:10-17:11 | 19-22 MB | 正常動作 |
| 負荷開始直後 | 17:12:21 | 130 MB | 急騰するが非最適化の半分以下 |
| ピーク | 17:13:51 | 224 MB | soft_limit 307MB 以下 |
| 負荷中定常 | 17:12:36-17:15:21 | 80-224 MB | GC 振動あるが soft_limit を超えない |
| 負荷終了後 | 17:15:36 | 25 MB | ベースラインに復帰 |

特徴: Heap ピーク 224MB で soft_limit 307MB を **83MB 下回る**。安全圏内。

#### 比較

| 指標 | 非最適化 | 最適化 | 変化 |
|------|---------|--------|------|
| Heap ピーク | 344 MB | 224 MB | **-35%** |
| soft_limit 超過 | あり（37MB 超過） | なし（83MB 余裕） | — |
| 定常範囲 | 232-344 MB | 80-224 MB | 大幅改善 |
| 負荷終了後の復帰 | 25 MB | 25 MB | 同一 |

### 3.2 Receiver メトリクスの挙動

#### 拒否レート（memory_limiter 発火）

| 指標 | 非最適化 | 最適化 | 変化 |
|------|---------|--------|------|
| Refused rate ピーク | 16.47/s | 0 | **-100%** |
| Refused 累計 | ~2,400 spans | 0 | **-100%** |

非最適化では memory_limiter が持続的に発火し、180 秒のテスト中に約 2,400 spans がドロップ。
最適化では Refused が完全にゼロ。memory_limiter は一度も発火しない。

### 3.3 Queue Usage の挙動

| 指標 | 非最適化 | 最適化 | 説明 |
|------|---------|--------|------|
| Queue 最大 | 9.2%（46/500 batches） | 100%（50/50 batches） | 最適化は queue_size が小さいため満杯になる |
| Queue メモリ | 46 × 8192 × 580B ≈ **213MB** | 50 × 2048 × 580B ≈ **59MB** | **3.6倍の差** |

重要: 最適化版の Queue が 100% に達しているが、これはメモリの問題ではない。
`queue_size: 50` × `batch_size: 2048` の掛け算が 59MB に収まっているため、queue が満杯でもメモリは安全圏内。
Queue 溢れ分は `block_on_overflow: false`（デフォルト）によりサイレントドロップされるが、memory_limiter は発火しない。

### 3.4 RSS Memory

| 指標 | 非最適化 | 最適化 |
|------|---------|--------|
| RSS ピーク | 532 MB（コンテナ上限付近） | 537 MB |
| RSS 定常 | 488-532 MB | 482-537 MB |

RSS は Go ランタイムが OS に返却しないメモリページを含むため、両バージョンとも同水準。
Heap Alloc の方がメモリ状態の実態を正確に反映する。

## 4. pprof での原因特定

### 4.1 解析手順

```bash
# 非最適化: peak プロファイルを Web UI で表示
make pprof-ui FILE=captures/02-27/163423/pprof/heap_163751.pprof

# 最適化: peak プロファイルを Web UI で表示
make pprof-ui FILE=captures/02-27/171141/pprof/heap_171351.pprof
```

### 4.2 非最適化 — inuse_space total: 203.83 MB

| 順位 | Flat | Flat% | 関数 | 役割 |
|------|------|-------|------|------|
| 1 | 80.52 MB | 39.50% | `pdata/internal.(*AnyValue).UnmarshalProto` | スパン属性のデシリアライズ・保持 |
| 2 | 48.01 MB | 23.55% | `pdata/internal.NewSpan` | Span オブジェクトの生成 |
| 3 | 28.50 MB | 13.98% | `pdata/internal.(*Span).UnmarshalProto` | Span のデシリアライズ |
| 4 | 12.00 MB | 5.89% | `grpc/mem.NewTieredBufferPool` | gRPC 受信バッファプール |
| 5 | 8.50 MB | 4.17% | `pdata/internal.(*KeyValue).UnmarshalProto` | 属性キー値のデシリアライズ |
| 6 | 6.01 MB | 2.95% | `grpc/mem.(*writer).Write` | gRPC 書き込みバッファ |

**累積（cum）で見た支配的関数**:

```
pdata/internal.(*ScopeSpans).UnmarshalProto — cum 169.03 MB (82.93%)
pdata/internal.(*Span).UnmarshalProto       — cum 117.52 MB (57.66%)
pdata/internal.(*KeyValue).UnmarshalProto   — cum  89.02 MB (43.67%)
exporter send chain (queue consumers)       — cum  20.40 MB (10.01%)
```

他の2シナリオ（tail-sampling では `tailsamplingprocessor`、high-cardinality では `spanmetricsconnector`）と異なり、pprof の top に **batch/queue 固有の関数が登場しない**。
メモリの大半は pdata（トレースデータのデシリアライズ）が占めている。
これは sending_queue に保持されているバッチ内のスパンデータそのものである。

### 4.3 最適化 — inuse_space total: 110.39 MB

| 順位 | Flat | Flat% | 関数 | 役割 |
|------|------|-------|------|------|
| 1 | 42.51 MB | 38.51% | `pdata/internal.(*AnyValue).UnmarshalProto` | スパン属性のデシリアライズ・保持 |
| 2 | 22.00 MB | 19.93% | `pdata/internal.NewSpan` | Span オブジェクトの生成 |
| 3 | 9.00 MB | 8.15% | `pdata/internal.(*Span).UnmarshalProto` | Span のデシリアライズ |
| 4 | 6.44 MB | 5.83% | `grpc/mem.NewTieredBufferPool` | gRPC 受信バッファプール |
| 5 | 3.00 MB | 2.72% | `zap/zapcore.newCounters` | ロガー初期化（静的） |
| 6 | 3.00 MB | 2.72% | `pdata/internal.(*KeyValue).UnmarshalProto` | 属性キー値のデシリアライズ |

**累積（cum）で見た支配的関数**:

```
pdata/internal.(*ScopeSpans).UnmarshalProto — cum 77.51 MB (70.22%)
pdata/internal.(*Span).UnmarshalProto       — cum 54.51 MB (49.38%)
exporter send chain (queue consumers)       — cum  8.48 MB  (7.68%)
```

最適化版でも top の関数構成は同じだが、pdata 層のメモリ消費が約半分に縮小している。
`queue_size × send_batch_size` の掛け算が 40 分の 1 に削減されたことで、queue に保持されるスパンデータ量が大幅に減少した結果である。

### 4.4 比較

| カテゴリ | 非最適化 | 最適化 | 変化 |
|---------|---------|--------|------|
| **pdata（トレースデータ保持）** | 165.53 MB (81.2%) | 73.51 MB (66.6%) | **-56%** |
| **gRPC バッファ** | 18.01 MB (8.8%) | 6.44 MB (5.8%) | -64% |
| **静的初期化・ランタイム** | 20.29 MB (10.0%) | 30.44 MB (27.6%) | +50% |
| **合計** | **203.83 MB** | **110.39 MB** | **-46%** |

### 4.5 直接の確保者 vs 保持の原因者

pprof の `flat` 値で見ると、`exporterhelper`（sending_queue）や `batchprocessor` が直接確保するメモリは top に登場しない。
しかし、queue がバッチを保持し続けるため、バッチ内のスパンデータ（pdata）が GC で回収されない。

これは tail-sampling の「保持の原因者」パターンと同じ構造である:

| シナリオ | 直接の確保者（flat） | 保持の原因者 |
|---------|-------------------|------------|
| Tail Sampling | pdata (74%) | `tailsamplingprocessor` — decision_wait 中のバッファ |
| 高カーディナリティ | `spanmetricsconnector` (79%) | `spanmetricsconnector` — 内部マップ |
| **Batch/Queue** | **pdata (81%)** | **sending_queue — queue に保持されたバッチ** |

Batch/Queue シナリオでは「保持の原因者」が pprof から直接見えないため、`flat` だけを見ると原因を見落としやすい。
Grafana の Queue Usage メトリクス（セクション 3.3）と組み合わせることで、queue 滞留がメモリ肥大化の根本原因であることを特定できる。

## 5. メモリ肥大化のメカニズム

### 5.1 掛け算の罠

Exporter の sending_queue は batch 単位でエントリを保持する。
1つの queue エントリ = 1つの batch = `send_batch_size` 個のスパン。

```text
理論最大メモリ = send_batch_size × queue_size × 平均スパンサイズ
```

| 設定 | 計算 | 結果 |
|------|------|------|
| 非最適化 | 8192 × 500 × 580B | **2.4GB** |
| 最適化 | 2048 × 50 × 580B | **59MB** |

非最適化の理論最大メモリ 2.4GB は、コンテナ制限 512MB の約5倍、soft_limit 307MB の約8倍。
Queue が全体の 13%（65 batches）埋まっただけで soft_limit に達する。

### 5.2 memory_limiter の閾値

`limit_percentage: 80`, `spike_limit_percentage: 20` の場合、memory_limiter は Linux cgroup のメモリ制限を基準に計算する（`internal/memorylimiter/iruntime/total_memory_linux.go`）:

```text
soft_limit = コンテナメモリ × (limit_percentage - spike_limit_percentage) = 512MB × 60% = 307MB
hard_limit = コンテナメモリ × limit_percentage = 512MB × 80% = 410MB
```

Heap が soft_limit（307MB）を超えると memory_limiter が新規データの受信を拒否し始める。

### 5.3 なぜ非最適化版で memory_limiter が発火するか

1. Jaeger（cpus:0.2）の処理が追いつかず、queue にバッチが蓄積
2. Queue の 9%（46 batches）で queue データだけで 213MB
3. パイプラインオーバーヘッド（gRPC バッファ、batch processor、Go ランタイム）が +130MB
4. 合計 343MB > soft_limit 307MB → memory_limiter 発火
5. 発火中は新規スパンを拒否 → **データドロップ**

### 5.4 なぜ最適化版では発火しないか

1. 同じ Jaeger 条件で queue にバッチが蓄積（queue 100%）
2. Queue データ: 50 × 2048 × 580B = 59MB（非最適化の 1/3.6）
3. オーバーヘッド込みでも Heap ピーク 224MB < soft_limit 307MB
4. memory_limiter 発火なし → **データドロップなし**

## 6. パラメータ最適化

### 6.1 最適化の要点

掛け算の結果がメモリ予算内に収まるよう、`send_batch_size` と `queue_size` の両方を削減する。

| パラメータ | 非最適化 | 最適化 | 削減率 |
|-----------|---------|--------|-------|
| send_batch_size | 8192 | 2048 | 4倍 |
| queue_size | 500 | 50 | 10倍 |
| **掛け算 (batch × queue)** | **4,096,000** | **102,400** | **40倍** |
| 理論最大メモリ | 2.4GB | 59MB | 40倍 |

### 6.2 最適化の効果

| 指標 | 非最適化 | 最適化 | 改善 |
|------|---------|--------|------|
| Heap ピーク | 344 MB | 224 MB | **-35%** |
| Refused Total | 2,400 spans | 0 | **-100%** |
| データドロップ | あり | なし | **解消** |

### 6.3 メモリ予算からの逆算

最適化の設計指針: 掛け算の結果をメモリ予算内に収める。

```text
queue_size × send_batch_size × span_size < soft_limit − オーバーヘッド
```

本シナリオの場合:
```text
soft_limit = 307MB
オーバーヘッド ≈ 150MB（Go ランタイム、gRPC、batch processor）
queue 予算 = 307 − 150 = 157MB

非最適化: 8192 × 500 × 580B = 2.4GB >> 157MB（超過）
最適化:   2048 × 50  × 580B = 59MB  <  157MB（収まる）
```

### 6.4 queue_size=100, 200 が失敗した経緯

最適化版の `timeout: 200ms` は高スループットを生み、パイプラインオーバーヘッドが非最適化版より大きくなる。
`queue_size: 200`（Heap 347MB）、`queue_size: 100`（Heap 330MB）ではいずれも soft_limit を超過した。
`queue_size: 50` で queue データを 59MB まで下げることで、オーバーヘッド込みでも 224MB に収めた。

## 7. 監視ポイント

### 7.1 Queue Usage の監視

```promql
# Queue 使用率が 50% を超えたら警告
otelcol_exporter_queue_size{job="otel-collector-self"} / otelcol_exporter_queue_capacity{job="otel-collector-self"} > 0.5
```

### 7.2 memory_limiter 発火の検知

```promql
# memory_limiter によるスパン拒否が発生
rate(otelcol_receiver_refused_spans_total{job="otel-collector-self"}[5m]) > 0
```

### 7.3 メモリ予算の事前チェック

設定変更時に掛け算を確認する習慣をつける:

```text
send_batch_size × queue_size × 想定スパンサイズ < コンテナメモリ × 60% − 150MB
```

## 8. まとめ

- `send_batch_size × queue_size` の掛け算が Collector のメモリ消費上限を決定する。個別の値が妥当でも、掛け算の結果がコンテナのメモリ予算を超過する「掛け算の罠」がある
- 非最適化（8192 × 500）では理論最大 2.4GB に対し、Queue がわずか 9% 埋まっただけで soft_limit 307MB を超過し、memory_limiter が発火。テスト全体で **約 2,400 spans がドロップ**
- 最適化（2048 × 50）では理論最大 59MB となり、Queue が 100% に達しても Heap 224MB で soft_limit 以下。**データドロップはゼロ**
- 設定変更時は `send_batch_size × queue_size × スパンサイズ` を計算し、`コンテナメモリ × 60% − 150MB` 以下に収めることを確認すべき
- 下流障害（バックエンドの一時的な遅延）は本番で頻繁に起こる。そのときに batch/queue の掛け算が大きすぎると、メモリ高騰→データドロップの連鎖が発生する
