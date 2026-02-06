## 1. 概要

`tail_sampling` は、判定までトレースを保持するため、`decision_wait` と流量の組み合わせでメモリ使用量が増える。
このレポートは、再現手順・観測・pprof 解析・最適化方針を最短で示す。

## 2. 再現手順

### 2.1 Collector 設定（問題設定）

```yaml
processors:
  tail_sampling:
    decision_wait: 30s
    num_traces: 1000000
    expected_new_traces_per_sec: 10000
    policies:
      - name: always-sample
        type: always_sample
```

ポイント:
- `decision_wait` が長い
- `num_traces` が大きすぎる
- `always_sample` で保持量が増えやすい

### 2.2 負荷実行

```bash
make scenario-tail-sampling
```

必要に応じて pprof 取得を同時実行:

```bash
make pprof-capture-bg
make scenario-tail-sampling
make pprof-capture-stop
```

## 3. Grafana での観測

観測する指標:
- `otelcol_process_runtime_heap_alloc_bytes`
- `otelcol_process_memory_rss`
- `otelcol_receiver_accepted_spans_total`
- `otelcol_receiver_refused_spans_total`

期待するパターン:
- 実行開始後に Heap が上昇
- GC で一時的に低下するが再上昇
- 設定が厳しい場合は Refused が増える

### 3.1 スクリーンショット（Grafana）

貼付対象:
- 立ち上がり〜ピークの Heap/RSS
- Refused が増えた区間
- 最適化前後の比較パネル

```md
![Grafana Heap/RSS](./images/grafana-heap-rss.png)
![Grafana Refused](./images/grafana-refused.png)
![Grafana Before/After](./images/grafana-before-after.png)
```

## 4. pprof での原因特定

### 4.1 解析手順

```bash
# 保存先を確認
cat pprof/last_capture.txt

# 差分を見る
make pprof-diff-auto DIR=$(cat pprof/last_capture.txt)
```

### 4.2 見るべき関数

- `tailsamplingprocessor.(*tailSamplingSpanProcessor).processTraces`
- `tailsamplingprocessor.(*tailSamplingSpanProcessor).samplingPolicyOnTick`
- `pdata/internal.*`（Span/Attribute の保持・コピー）

### 4.3 スクリーンショット（pprof）

貼付対象:
- Top（inuse_space 上位関数）
- Flame Graph（Tail Sampling 周辺）
- diff 結果（baseline vs peak）

```md
![pprof Top](./images/pprof-top-inuse-space.png)
![pprof Flame Graph](./images/pprof-flamegraph.png)
![pprof Diff](./images/pprof-diff-baseline-peak.png)
```

## 5. メモリ肥大化のメカニズム

Tail Sampling は「全スパンが揃うまで判定を待つ」ため、
`decision_wait` 中のトレースがバッファに残る。

概算式:

```text
必要メモリ ≈ decision_wait × トレース流量 × 平均トレースサイズ
```

この保持量が大きいと、GC 負荷が上がり、処理遅延や拒否が発生する。

## 6. パラメータ最適化

### 6.1 変更方針

- `decision_wait` を短縮（例: 30s -> 10s）
- `num_traces` をメモリ予算から逆算
- `policies` を見直し、不要トレース保持を減らす

### 6.2 最適化後の例

```yaml
processors:
  tail_sampling:
    decision_wait: 10s
    num_traces: 50000
    expected_new_traces_per_sec: 5000
    policies:
      - name: error-policy
        type: status_code
        status_code:
          status_codes: [ERROR]
      - name: probabilistic-policy
        type: probabilistic
        probabilistic:
          sampling_percentage: 10
```

### 6.3 比較で確認すること

- Heap ピークが下がったか
- Refused が減ったか
- pprof で tail_sampling 関連の割合が下がったか

## 7. 監視ポイント

- Heap/RSS の継続上昇
- Refused の発生
- Tail Sampling の drop/sampled 系メトリクス

アラート例:

```promql
rate(otelcol_receiver_refused_spans_total[5m]) > 0
```

## 8. まとめ

- Tail Sampling は有効だが、保持設計を誤るとメモリ高騰を招く。
- Grafana で症状を捉え、pprof で保持構造を特定する。
- `decision_wait` と `num_traces` の調整で改善を確認する。
