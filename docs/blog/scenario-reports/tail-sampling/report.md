# 診断レポート: Tail Sampling

## 1. 概要

`tail_sampling` processor の `decision_wait` パラメータが長すぎる場合のメモリ肥大化を検証するシナリオ。高スループット環境で decision_wait × スループット のトレースがメモリに保持され、OOM に至る過程を記録する。

**メカニズムの本質**: 時間軸のバッファリング問題。「いつまで保持するか」の設計ミスがメモリ爆発を引き起こす。

---

## 2. Tail Sampling とは

### 2.1 動作原理

Tail Sampling は、トレースの**全スパンが揃ってから**サンプリング判定を行う手法。

```
通常のサンプリング（Head Sampling）:
  スパン到着 → 即座に判定 → 送信 or 破棄

Tail Sampling:
  スパン到着 → バッファに保持 → 全スパン揃う → 判定 → 送信 or 破棄
                ↑
                decision_wait の間、メモリに保持
```

### 2.2 なぜ Tail Sampling が必要か

- **エラートレースを確実にキャプチャ**: 最後のスパンでエラーが発生した場合も取得可能
- **レイテンシベースのサンプリング**: トレース全体の処理時間で判定
- **複雑なポリシー**: 複数スパンの属性を組み合わせた判定

### 2.3 メモリ消費の数学

```
必要メモリ = decision_wait × スループット × 平均トレースサイズ

例:
  decision_wait = 30秒
  スループット = 1,000 トレース/秒
  平均トレースサイズ = 10KB（5スパン × 2KB）

  必要メモリ = 30 × 1,000 × 10KB = 300MB

  → スループットが 10,000 トレース/秒 になると 3GB 必要
```

---

## 3. 再現条件

### 3.1 Collector 設定

```yaml
processors:
  tail_sampling:
    decision_wait: 30s          # 意図的に長く設定（通常は 3-10秒）
    num_traces: 1000000         # 上限を実質無制限に
    expected_new_traces_per_sec: 10000
    policies:
      - name: always-sample
        type: always_sample     # 100% サンプリング（最悪ケース）
```

**問題のある設定ポイント**:

| パラメータ | 設定値 | 問題点 |
|-----------|--------|--------|
| `decision_wait` | 30s | 通常の3-10倍。30秒分のトレースがメモリに滞留 |
| `num_traces` | 1000000 | 上限が実質なし。メモリ保護が機能しない |
| `policies` | always_sample | 全トレースを保持。破棄されるものがない |

### 3.2 負荷設定（loadgen）

```bash
make scenario-tail-sampling

# 内部で実行されるコマンド:
./loadgen/loadgen \
  -endpoint localhost:4317 \
  -scenario sustained \
  -duration 180s \
  -rate 10000 \
  -workers 10 \
  -depth 5 \
  -attr-size 128 \
  -attr-count 8
```

**負荷の特徴**:
- 10,000 spans/sec（depth=5 なので約 2,000 トレース/sec）
- 各トレースは 5 スパンで構成
- 属性サイズ: 128 bytes × 8 = 1KB/span

### 3.3 期待されるメモリ消費

```
トレース数/秒: 2,000
decision_wait: 30秒
バッファ内トレース数: 2,000 × 30 = 60,000 トレース

1トレースのサイズ: 5スパン × 1KB = 5KB
バッファ合計: 60,000 × 5KB = 300MB

+ Go のオーバーヘッド（Map, GC）: 約 1.5倍
→ 推定 Heap: 450MB
```

**実測値との比較**:
- 理論値: 300-450MB
- 実測値: **ピーク 166.69MB**（理論値の約37-55%）

実測値が理論値より低い理由:
1. GC が積極的に発動し、不要なオブジェクトを解放
2. `num_traces` の上限に達する前にトレースが処理完了
3. 実際のスループットが設定値より低かった可能性

---

## 4. 実測タイムライン（2026-02-05）

### 4.1 メモリ変化の時系列

| 経過時間 | 時刻 | Heap Memory | 変化 | 備考 |
|---------|------|-------------|------|------|
| 0秒 | 14:32:10 | **9.78MB** | - | 初期状態 |
| 15秒 | 14:32:25 | 12.31MB | +2.5MB | バッファ蓄積開始 |
| 21秒 | 14:32:31 | 29.60MB | +17.3MB | 急増開始 |
| 26秒 | 14:32:36 | 78.26MB | +48.7MB | decision_wait 到達前 |
| **31秒** | 14:32:41 | **150.77MB** | +72.5MB | **decision_wait (30s) 到達** |
| 52秒 | 14:33:02 | 155.20MB | - | 定常状態に近づく |
| 62秒 | 14:33:12 | 49.27MB | -105.9MB | **GC 発動** |
| 78秒 | 14:33:28 | 141.87MB | +92.6MB | 再蓄積 |
| **98秒** | 14:33:48 | **166.69MB** | +24.8MB | **ピーク** |
| 109秒 | 14:33:59 | 52.21MB | -114.5MB | GC 発動 |
| 180秒 | 14:35:31 | 82.58MB | - | テスト終了 |

### 4.2 観測されたパターン

```
Start: 9.78MB → Peak: 166.69MB → End: 82.58MB
Growth: +156.91MB (+1605.1%)
```

**特徴的な挙動**:
1. **decision_wait (30s) で急増**: 開始30秒で 9.78MB → 150.77MB（約15倍）
2. **のこぎり波パターン**: GC で一時的に下がるが、すぐに再蓄積
3. **定常状態には達しない**: GC と蓄積の繰り返しで 50MB〜167MB を変動
4. **OOM には至らず**: 今回の設定ではメモリ制限内で収まった

**重要**: `num_traces` が適切に設定されていれば、バッファは上限で制限される。本シナリオでは意図的に上限を高くしているが、実際のメモリ消費は設定より控えめだった。

---

## 5. pprof で確認すべき箇所

### 5.1 ヒープの主要な肥大化箇所

```
# 以下の関数がヒープの上位に現れる場合、Tail Sampling が原因

1. tailsamplingprocessor.(*tailSamplingSpanProcessor).processTraces
   → トレースバッファへの追加処理

2. tailsamplingprocessor.(*tailSamplingSpanProcessor).samplingPolicyOnTick
   → サンプリング判定のためのトレース保持

3. pdata.Traces / pdata.Span
   → 実際のトレースデータ

4. runtime.mallocgc
   → Map のエントリ追加による GC 負荷
```

### 5.2 pprof 解析手順

```bash
# 1. pprof キャプチャ開始（バックグラウンド）
make pprof-capture-bg

# 2. シナリオ実行
make scenario-tail-sampling

# 3. キャプチャ停止
make pprof-capture-stop

# 4. ベースライン vs ピークの差分表示
make pprof-diff-auto DIR=$(cat pprof/last_capture.txt)
```

### 5.3 実測 pprof 出力（2026-02-05）

#### ピーク時の絶対値（heap_143348.pprof）

```
File: otelcol-contrib
Type: inuse_space
Time: Feb 5, 2026 at 2:33pm (JST)
Showing nodes accounting for 157.41MB, 94.43% of 166.69MB total

      flat  flat%   sum%        cum   cum%
   73.51MB 44.10% 44.10%    73.51MB 44.10%  pdata/internal.(*AnyValue).UnmarshalProto
   15.27MB  9.16% 53.26%    15.27MB  9.16%  tailsamplingprocessor/internal/tracelimiter.NewDropOldTracesLimiter
   12.80MB  7.68% 60.93%    12.80MB  7.68%  google.golang.org/grpc/mem.NewTieredBufferPool
   11.50MB  6.90% 67.83%       20MB 12.00%  pdata/internal.CopyKeyValueSlice
      11MB  6.60% 74.44%       11MB  6.60%  pdata/internal.NewSpan
    8.50MB  5.10% 79.53%     8.50MB  5.10%  pdata/internal.CopyAnyValue
    4.50MB  2.70% 82.23%    41.01MB 24.60%  tailsamplingprocessor.(*tailSamplingSpanProcessor).processTraces
```

#### ベースライン → ピークの差分

```bash
go tool pprof --diff_base heap_143210.pprof heap_143348.pprof
```

| 関数 | 増加量 | 割合 | 説明 |
|------|--------|------|------|
| `pdata/internal.(*AnyValue).UnmarshalProto` | **+73.5MB** | 44% | スパン属性のデシリアライズ |
| `tailsamplingprocessor.NewDropOldTracesLimiter` | **+15.6MB** | 9% | **Tail Samplingのトレースリミッター** |
| `grpc/mem.NewTieredBufferPool` | **+13.1MB** | 8% | gRPC受信バッファ |
| `pdata/internal.CopyKeyValueSlice` | **+11.8MB** | 7% | 属性値のコピー |
| `pdata/internal.NewSpan` | **+11.3MB** | 7% | **スパンオブジェクトの作成** |
| `tailsamplingprocessor.processTraces` | **+42MB (累積)** | - | **Tail Samplingのメイン処理** |

#### 解釈

1. **Tail Sampling が原因**: `tailsamplingprocessor` 関連の関数がヒープの上位を占める
2. **トレースバッファの肥大化**: `decision_wait=30s` の間、スパンデータがメモリに蓄積
3. **pdata構造の保持**: `NewSpan`, `CopyKeyValueSlice` などでトレースデータがコピー・保持
4. **累積メモリ増加**: ベースライン 10MB → ピーク 167MB（約 **157MB 増加**）

---

## 6. パラメータ最適化

### 6.1 decision_wait の設計

| ユースケース | 推奨値 | 根拠 |
|-------------|--------|------|
| 単純なサービス | 3秒 | 99% のトレースは 3秒以内に完了 |
| マイクロサービス（5-10 hop） | 10秒 | 複数サービス間の伝播時間 |
| 非同期処理あり | 30秒 | キューイング遅延を考慮 |
| バッチ処理 | 60秒+ | ただし num_traces を厳格に制限 |

**トレードオフ**:
```
decision_wait 長い → サンプリング精度 UP / メモリ消費 UP
decision_wait 短い → サンプリング精度 DOWN / メモリ消費 DOWN
```

### 6.2 num_traces の設計

```yaml
# メモリ予算から逆算
#
# 許容メモリ: 500MB
# 1トレースサイズ: 5KB
# オーバーヘッド: 1.5倍
#
# num_traces = 500MB / (5KB × 1.5) = 66,666
# → 安全マージンを取って 50,000 に設定

tail_sampling:
  num_traces: 50000
```

### 6.3 最適化後の設定例

```yaml
processors:
  tail_sampling:
    decision_wait: 10s           # 適切な待機時間
    num_traces: 50000            # メモリ予算に基づく上限
    expected_new_traces_per_sec: 5000
    policies:
      # エラートレースのみ 100% サンプリング
      - name: error-policy
        type: status_code
        status_code:
          status_codes: [ERROR]
      # 正常トレースは 10% サンプリング
      - name: probabilistic-policy
        type: probabilistic
        probabilistic:
          sampling_percentage: 10
```

---

## 7. 監視ポイント

### 7.1 主要メトリクス

| メトリクス | 正常値 | 異常値 | 意味 |
|-----------|--------|--------|------|
| `otelcol_processor_tail_sampling_count_traces_sampled` | 増加 | 0 | サンプリングされたトレース数 |
| `otelcol_processor_tail_sampling_count_traces_dropped` | 低い | 急増 | num_traces 上限によるドロップ |
| `otelcol_process_runtime_heap_alloc_bytes` | 安定 | 右肩上がり | メモリ肥大化 |
| `otelcol_processor_tail_sampling_sampling_decision_latency` | 低い | 増加 | 判定処理の遅延 |

### 7.2 アラート設定例

```yaml
# Prometheus アラートルール

groups:
  - name: tail-sampling-alerts
    rules:
      # トレースドロップが発生
      - alert: TailSamplingTraceDropped
        expr: rate(otelcol_processor_tail_sampling_count_traces_dropped[5m]) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Tail sampling is dropping traces due to num_traces limit"

      # メモリが継続的に増加
      - alert: TailSamplingMemoryGrowth
        expr: |
          deriv(otelcol_process_runtime_heap_alloc_bytes[5m]) > 1000000
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Heap memory is continuously growing (tail sampling buffer?)"
```

---

## 8. 同じメカニズムの他の例（応用）

Tail Sampling と同じ「時間軸のバッファリング」問題は、以下のコンポーネントでも発生する：

### 8.1 Batch Processor

```yaml
batch:
  timeout: 200ms      # この間、スパンをメモリに保持
  send_batch_size: 8192
```

**違い**: timeout は通常ミリ秒単位なので、影響は限定的。ただし send_batch_size が大きすぎると問題になる。

### 8.2 Exporter リトライキュー

```yaml
exporters:
  otlp:
    sending_queue:
      queue_size: 5000      # 送信失敗時にこの数までバッファ
    retry_on_failure:
      max_elapsed_time: 300s  # 5分間リトライ
```

**関連**: 下流が停止すると、queue_size × max_elapsed_time の間データがメモリに滞留。

### 8.3 groupbytrace Processor

```yaml
groupbytrace:
  wait_duration: 10s    # tail_sampling と同様の問題
  num_traces: 10000
```

---

## 9. 診断フローチャート

```
スループットが徐々に低下している
           ↓
  Heap Memory は増加しているか？
           ↓
    ┌──────┴──────┐
    ↓             ↓
  増加している    安定している
    ↓             ↓
GC後も戻らないか？  → 他の原因を調査
    ↓
  ┌─┴─┐
  ↓   ↓
 戻る  戻らない
  ↓    ↓
一時的  時間軸の問題（Tail Sampling等）
バースト     or
       空間軸の問題（高カーディナリティ）
              ↓
        pprof で特定
              ↓
    ┌─────────┴─────────┐
    ↓                   ↓
tailsamplingprocessor   spanmetrics/groupbyattrs
    ↓                   ↓
decision_wait を短縮    高カーディナリティ属性を削除
num_traces を制限
```
 
---

## 10. 結論と教訓

### 10.1 Tail Sampling は強力だが危険

- **利点**: 完全なトレースに基づく高精度サンプリング
- **リスク**: decision_wait × スループット のメモリが必要
- **対策**: num_traces で上限を必ず設定

### 10.2 時間軸の問題の普遍的な診断方法

1. **Heap が右肩上がり** → 何かがバッファに蓄積している
2. **GC 後も戻らない** → 「生きている」データが増え続けている
3. **pprof で確認** → どのコンポーネントがメモリを消費しているか特定
4. **時間系パラメータを調整** → decision_wait, timeout, max_elapsed_time など

### 10.3 本番投入チェックリスト

- [ ] `decision_wait` はトレースの99パーセンタイル完了時間に基づいているか
- [ ] `num_traces` はメモリ予算から逆算して設定したか
- [ ] `policies` で不要なトレースを破棄しているか（always_sample は避ける）
- [ ] Heap メモリの監視アラートを設定したか
- [ ] トレースドロップのアラートを設定したか
- [ ] 本番相当のスループットで負荷テストを実施したか

---

## 11. 参考情報

### 関連ドキュメント

- [tail_sampling processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor)
- [memory_limiter processor](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md)
- [docs/scenarios.md](../scenarios.md) - シナリオ一覧

### 実行コマンド

```bash
# シナリオ実行
make scenario-tail-sampling

# pprof 解析付きで実行
make pprof-capture-bg && make scenario-tail-sampling && make pprof-capture-stop
make pprof-diff-auto DIR=$(cat pprof/last_capture.txt)
```
