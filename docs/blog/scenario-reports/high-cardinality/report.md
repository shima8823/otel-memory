## 1. 概要

`spanmetrics` connector は、トレースからメトリクス（レイテンシヒストグラムやスループットカウンタ）を自動生成する。
`dimensions` に高カーディナリティ属性（UUID など）を含めると、ユニーク組み合わせごとに時系列が生成され、内部マップが無限膨張する。

このレポートでは、`dimensions` に UUID 属性を含む設定（非最適化）と `dimensions: []`（最適化）の2条件で同一負荷を与え、
メモリ挙動の違いを Grafana メトリクスと pprof で観測・比較する。

**核心**: `memory_limiter` は新規データの受信を拒否するだけで、`spanmetrics` の内部マップに既に蓄積されたエントリは解放できない。
そのため、memory_limiter があっても OOM Kill を防げない。

## 2. 再現手順

### 2.1 Collector 設定（非最適化 — 問題設定）

```yaml
connectors:
  spanmetrics:
    histogram:
      explicit:
        buckets: [1ms, 5ms, 10ms, 50ms, 100ms, 500ms, 1s, 5s]
    dimensions:
      - name: attr_0
      - name: attr_1
      - name: attr_2
      - name: attr_3
      - name: attr_4
      - name: attr_5
      - name: attr_6
      - name: attr_7
    dimensions_cache_size: 10000000
    aggregation_temporality: AGGREGATION_TEMPORALITY_CUMULATIVE

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 20

  batch:
    send_batch_size: 2000
    send_batch_max_size: 4000
    timeout: 200ms
```

ポイント:
- `dimensions` に `attr_0`〜`attr_7` を指定。loadgen がこれらに UUID を付与して送信する
- `dimensions_cache_size: 10000000` により、事実上無制限にキャッシュを保持
- `AGGREGATION_TEMPORALITY_CUMULATIVE` により、全ユニーク組み合わせを永久保持
- Exporter は `debug` のみ。Jaeger/Prometheus を除外し、spanmetrics の内部マップが唯一のメモリ消費源となるよう単因子性を確保

### 2.2 Collector 設定（最適化）

```yaml
connectors:
  spanmetrics:
    histogram:
      explicit:
        buckets: [1ms, 5ms, 10ms, 50ms, 100ms, 500ms, 1s, 5s]
    dimensions: []     # 高カーディナリティ属性を除外
    aggregation_temporality: AGGREGATION_TEMPORALITY_CUMULATIVE
```

`dimensions` のみを変更し、他のパラメータ（`memory_limiter`, `batch`, パイプライン構成）は同一条件に保つ。
デフォルトキー（`service.name`, `span.name`, `span.kind`, `status.code`）のみで集計するため、
ユニーク組み合わせ数が有界になる。

### 2.3 負荷条件

両シナリオ共通:

```
Loadgen:          pyloadgen (Python + OTel SDK)
Rate:             1,300 traces/sec
Duration:         300s（5分）
Workers:          10
Attributes:       8（attr_0〜attr_7 に UUID）
Span Depth:       5（1トレース = 6スパン → 7,800 spans/sec）
Container Memory: 512 MB
```

実行コマンド:

```bash
# 非最適化（dimensions に UUID 属性を含む）
make run-scenario-spanmetrics

# 最適化（dimensions: [] — デフォルトキーのみ）
make run-scenario-spanmetrics-optimized
```

## 3. Grafana での観測

### 3.1 Heap Memory の挙動

#### 非最適化（dimensions に UUID 属性を含む）

![Heap Memory — 非最適化](./images/non-opt-heap-memory.png)

| タイムスタンプ | Heap | 説明 |
|--------------|------|------|
| 11:56:19 | 257.69 MB | 最初のメトリクス取得ポイント |
| 11:56:34 | 317.88 MB | **最後のメトリクスポイント（+60 MB / 15秒）** |
| 11:56:49〜 | (データ消失) | Collector が OOM Kill され、メトリクス取得不能 |

特徴: メトリクスが **2ポイントのみ** で途切れる。15秒間で 60 MB の増加率は、
そのまま続けば数十秒で Docker の memory limit（512 MB）に到達する勢い。

#### 最適化（dimensions: []）

![Heap Memory — 最適化](./images/opt-heap-memory.png)

| フェーズ | 時間帯 | Heap 範囲 | 説明 |
|---------|--------|----------|------|
| 負荷前 | 12:12:17 | 30.76 MB | アイドル状態 |
| 負荷中 | 12:12:32-12:16:02 | 19.77-41.49 MB | **GC による正常な振動** |
| 負荷後 | 12:16:17-12:17:17 | 20.96-21.80 MB | アイドルに復帰 |

特徴: 5分間の全テスト期間を通じて **21ポイント** のメトリクスが取得でき、Heap は 20-41 MB で安定振動。
GC が正常に動作し、メモリが解放されている。

#### 比較

| 指標 | 非最適化 | 最適化 | 変化 |
|------|---------|--------|------|
| Heap ピーク | 317.88 MB | 41.49 MB | **-87%** |
| Heap 最小 | 257.69 MB | 19.77 MB | -92% |
| メトリクス取得数 | 2ポイント | 21ポイント | 観測可能性の確保 |
| GC 動作 | 追いつかない | 正常に振動 | |

### 3.2 RSS Memory

#### 非最適化

![RSS Memory — 非最適化](./images/non-opt-rss-memory.png)

| タイムスタンプ | RSS | 説明 |
|--------------|-----|------|
| 11:56:19 | 430.11 MB | Docker limit 512 MB の 84% |
| 11:56:34 | 490.75 MB | Docker limit の **96%**（+60 MB / 15秒） |
| 11:56:49〜 | (データ消失) | OOM Kill |

#### 最適化

![RSS Memory — 最適化](./images/opt-rss-memory.png)

| フェーズ | RSS 範囲 | 説明 |
|---------|----------|------|
| 全期間 | 193.19-200.87 MB | Docker limit の **37-39%** で安定 |

#### 比較

| 指標 | 非最適化 | 最適化 | 変化 |
|------|---------|--------|------|
| RSS ピーク | 490.75 MB | 200.87 MB | **-59%** |
| Docker limit 使用率 | 96% | 39% | -57pt |
| 増加傾向 | +60 MB / 15秒 | ±7 MB（安定） | |

### 3.3 Receiver メトリクスの挙動

#### 非最適化

![Receiver Spans — 非最適化](./images/non-opt-receiver-spans.png)

![Receiver Drop Rate — 非最適化](./images/non-opt-receiver-drop-rate.png)

Loadgen のログから算出したスループット:
- 開始〜50秒: **2,100-2,200 spans/sec**（正常）
- 50秒目: **最初の UNAVAILABLE エラー**（memory_limiter 発火）
- 50秒以降: **500-650 spans/sec** に急落し、エラーが継続

| 指標 | 値 |
|------|-----|
| Refused Spans Total | 1,920 |
| UNAVAILABLE エラー | 多数（50秒目〜300秒まで継続） |
| Loadgen 総送信数 | 269,676 |

#### 最適化

![Receiver Spans — 最適化](./images/opt-receiver-spans.png)

![Receiver Drop Rate — 最適化](./images/opt-receiver-drop-rate.png)

- 全期間: **480-575 spans/sec** で安定（back-pressure はあるがエラーなし）
- Refused Spans Total: **0**（全期間ゼロ）
- UNAVAILABLE エラー: **0件**
- Loadgen 総送信数: 252,366

#### 比較

| 指標 | 非最適化 | 最適化 | 変化 |
|------|---------|--------|------|
| Refused Spans Total | 1,920 | **0** | **-100%** |
| UNAVAILABLE エラー | 多数（50秒目〜継続） | **0件** | 完全解消 |
| CPU ピーク | 10.31% | 3.91% | **-62%** |
| Loadgen 総送信数 | 269,676 | 252,366 | -6.4% |

> 注: 最適化版の方が総送信数がわずかに少ないのは、back-pressure による自然な抑制のため。
> 非最適化版は UNAVAILABLE エラーのリトライで見かけ上のスループットが膨らんでいる。

### 3.4 OOM Kill の証拠

非最適化版で Collector が OOM Kill されたことを示す複数の間接証拠:

| 証拠 | 非最適化 | 最適化 | 解釈 |
|------|---------|--------|------|
| **pprof 取得数** | 19本（93秒で途切れ） | 69本（351秒、全期間カバー） | pprof endpoint が応答不能に |
| **メトリクス取得数** | 2ポイント | 21ポイント | Prometheus scrape が失敗 |
| **RSS 最終値** | 490.75 MB（limit の 96%） | 200.87 MB（limit の 39%） | OOM Kill 直前の状態 |
| **UNAVAILABLE エラー** | 50秒目から継続 | 0件 | gRPC endpoint が応答不能 |

pprof プロファイルが 93秒で途切れ、直後からメトリクスも取得できなくなっている。
**「データが取れなくなること自体が OOM Kill の証拠」** である。

## 4. pprof での原因特定

### 4.1 解析手順

```bash
# 非最適化: peak プロファイルを Web UI で表示
make pprof-ui FILE=captures/02-26/115501-spanmetrics/pprof/heap_115634.pprof

# 最適化: 終盤のプロファイルを確認
make pprof-ui FILE=captures/02-26/121123-spanmetrics-opt/pprof/heap_121714.pprof
```

### 4.2 非最適化 — inuse_space total: 265.67 MB

| 順位 | Flat | Flat% | 関数 | 役割 |
|------|------|-------|------|------|
| 1 | 71.53 MB | 26.92% | `pcommon.Map.EnsureCapacity` | spanmetrics 内部マップの容量確保 |
| 2 | 71.53 MB | 26.92% | `bytes.(*Buffer).String` | dimension 値の文字列化（UUID） |
| 3 | 33.00 MB | 12.42% | `pdata/internal.(*AnyValue).UnmarshalProto` | スパン属性のデシリアライズ |
| 4 | 24.05 MB | 9.05% | `spanmetricsconnector.explicitHistogramMetrics.GetOrCreate` | ヒストグラム時系列の生成 |
| 5 | 18.50 MB | 6.96% | `pdata/internal.CopyAnyValue` | 属性値のコピー |
| 6 | 6.51 MB | 2.45% | `spanmetricsconnector.SumMetrics.GetOrCreate` | カウンタ時系列の生成 |

**累積（cum）で見た支配的関数**:

```
spanmetricsconnector.(*connectorImp).aggregateMetrics — cum 210.62 MB (79.28%)
spanmetricsconnector.(*connectorImp).ConsumeTraces    — cum 210.62 MB (79.28%)
```

メモリの **79%** が spanmetrics connector の `aggregateMetrics` 経由で確保されている。
`GetOrCreate` が呼ばれるたびに新しい dimension 組み合わせのエントリが内部マップに追加され、
CUMULATIVE temporality のため一度作られたエントリは削除されない。

### 4.3 最適化 — inuse_space total: 19.90 MB

| 順位 | Flat | Flat% | 関数 | 役割 |
|------|------|-------|------|------|
| 1 | 2.51 MB | 12.60% | `regexp/syntax.(*compiler).inst` | 正規表現の初期化（静的） |
| 2 | 1.50 MB | 7.54% | `go.uber.org/zap/zapcore.newCounters` | ロガー初期化（静的） |
| 3 | 1.00 MB | 5.02% | `pdata/internal.(*Span).UnmarshalProto` | スパンのデシリアライズ |
| 4 | 1.00 MB | 5.02% | `aws/endpoints.init` | AWS SDK 初期化（静的） |
| 5 | 1.00 MB | 5.02% | `pdata/internal.(*AnyValue).UnmarshalProto` | 属性のデシリアライズ |

**spanmetrics connector の関数が top に一切登場しない**。
dimensions が空のため、ユニーク組み合わせがサービス × オペレーション × ステータスの数種類に限定され、
内部マップのメモリ消費が無視できるレベルになっている。

### 4.4 比較

| カテゴリ | 非最適化 | 最適化 | 変化 |
|---------|---------|--------|------|
| **spanmetrics 関連（cum）** | 210.62 MB (79%) | ≈ 0 MB | **-100%** |
| **pdata（デシリアライズ）** | 33.00 MB (12%) | 1.00 MB (5%) | **-97%** |
| **静的初期化・ランタイム** | 22.05 MB (8%) | 18.90 MB (95%) | -14% |
| **合計** | **265.67 MB** | **19.90 MB** | **-92%** |

## 5. メモリ肥大化のメカニズム

### 5.1 spanmetrics の内部マップ

`spanmetrics` connector は dimension 値のユニーク組み合わせごとにメトリクス時系列を生成する。

```
時系列数 = ユニーク(dim_0) × ユニーク(dim_1) × ... × ユニーク(dim_N)
```

本シナリオでは:
- 1,300 traces/sec × 6 spans/trace = 7,800 spans/sec
- 各 span に 8 個の UUID 属性 → **毎秒 7,800 の新規ユニーク組み合わせ**
- CUMULATIVE temporality: 一度作られた組み合わせは永久保持

50秒後には約 390,000 エントリが内部マップに蓄積される。
各エントリはヒストグラム（8 buckets）とカウンタを保持するため、
エントリあたり数百バイト〜数 KB のメモリを消費し、pprof 実測値（265 MB）と概ね一致する。

### 5.2 memory_limiter が効かない理由

```
[受信] → memory_limiter → batch → [spanmetrics connector] → 内部マップ
               ↑                           ↓
         Heap 監視                  GetOrCreate でエントリ追加
               ↑                           ↓
         受信を拒否 ←――――――  しかしマップは縮小しない
```

1. `memory_limiter` が Heap 使用量を検知し、新規スパンの受信を拒否する
2. しかし、既に `spanmetrics` の内部マップに蓄積されたエントリは **解放されない**
3. CUMULATIVE temporality では、マップエントリは次のメトリクスエクスポート時にも必要なため保持される
4. 受信を止めても Heap は下がらない → OOM Kill

これが Tail Sampling との決定的な違いである。Tail Sampling は `decision_wait` を過ぎたトレースを解放するため、
受信を止めれば徐々にメモリが回復する。spanmetrics の内部マップは **一方向にしか成長しない**。

## 6. パラメータ最適化

### 6.1 変更点

唯一の変更: `dimensions` から高カーディナリティ属性を除外。

```yaml
# 非最適化
dimensions:
  - name: attr_0
  - name: attr_1
  # ... attr_7 まで

# 最適化
dimensions: []   # デフォルトキーのみ（service.name, span.name, span.kind, status.code）
```

### 6.2 結果比較

| 指標 | 非最適化 | 最適化 | 変化 |
|------|---------|--------|------|
| Heap ピーク | 317.88 MB | 41.49 MB | **-87%** |
| RSS ピーク | 490.75 MB | 200.87 MB | **-59%** |
| pprof inuse_space | 265.67 MB | 19.90 MB | **-92%** |
| Refused Spans Total | 1,920 | **0** | **-100%** |
| OOM Kill | 発生（93秒で停止） | なし（300秒完走） | 解消 |
| CPU ピーク | 10.31% | 3.91% | **-62%** |
| pprof 取得数 | 19（途切れ） | 69（完走） | 観測可能性も改善 |
| UNAVAILABLE エラー | 多数（50秒目〜） | 0件 | 完全解消 |

### 6.3 なぜこれほど効果が大きいか

`dimensions: []` により:
- ユニーク組み合わせ数: **毎秒 7,800 増加** → **数種類で固定**（service × operation × status）
- 内部マップのサイズ: **無限膨張** → **有界**
- GC の負荷: **マップ走査に比例して増大** → **一定**

## 7. 監視ポイント

### 7.1 Heap 右肩上がりの検知

spanmetrics による膨張は GC 後もメモリが戻らないのが特徴。

```promql
# GC サイクルを経ても Heap が下がらない
# （5分間の最小値が閾値を超える = GC 後も高いまま）
min_over_time(otelcol_process_runtime_heap_alloc_bytes{job="otel-collector-self"}[5m]) > 200e6
```

### 7.2 Refused 発生の検知

```promql
# memory_limiter によるスパン拒否が発生
rate(otelcol_receiver_refused_spans_total{job="otel-collector-self"}[5m]) > 0
```

### 7.3 OOM Kill の間接検知

OOM Kill そのものはメトリクスに記録されない。「データが取れなくなる」ことで検知する。

```promql
# Collector からのメトリクスが途絶えた（scrape 失敗）
up{job="otel-collector-self"} == 0

# Heap メトリクスが一定時間取得できない
absent_over_time(otelcol_process_runtime_heap_alloc_bytes{job="otel-collector-self"}[2m])
```

## 8. 実務での発生パターン

### パターン A: ユーザー ID / セッション ID を dimensions に含む

```yaml
# 危険: user_id は高カーディナリティ
dimensions:
  - name: user_id
```

ユーザー数が多いサービスでは、user_id のユニーク数がそのまま時系列数に直結する。
10万ユーザーが同時にアクセスする場合、10万 × オペレーション数の時系列が生成される。

### パターン B: URL パスパラメータ

```yaml
# 危険: /users/123, /users/456 ... がそれぞれ別の dimension 値
dimensions:
  - name: http.route
```

RESTful API で `/users/{id}` のようなパスパラメータが `http.route` に含まれる場合、
ID ごとに別の時系列が生成される。`http.route` を正規化（`/users/:id`）してから使用すべき。

### パターン C: SQL クエリ文字列

```yaml
# 危険: WHERE 句のパラメータが異なるたびに新しい dimension 値
dimensions:
  - name: db.statement
```

`SELECT * FROM users WHERE id = 123` と `... WHERE id = 456` が別の dimension 値として扱われる。
`db.operation`（`SELECT`）や `db.sql.table`（`users`）を使用すべき。

## 9. まとめ

- `spanmetrics` の `dimensions` に高カーディナリティ属性を含めるだけで、**93秒で OOM Kill** に至る
- `memory_limiter` はステートフルな connector/processor の内部状態には無力。受信を拒否しても内部マップは縮小しない
- `dimensions: []` に変更するだけで、同一負荷でも Heap **-87%**、Refused **-100%** で完全に解消
- pprof の `cum` を見ると、メモリの **79% が spanmetrics の `aggregateMetrics`** 経由で確保されていることがわかる
- **「データが取れなくなること自体が OOM Kill の証拠」** — メトリクスの途絶に注意する
