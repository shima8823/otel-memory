# OpenTelemetry Collector のメモリ高騰をデバッグする — シナリオで学ぶ実践ガイド

## 1. はじめに

## 2. デバッグの基本技法

観測手段は次の2つです。

- internal metrics（Grafana）
- pprof

## 3. シナリオ選定の設計思想

<!-- ハイカーディナリティ && 後一つ -->

同じ「メモリ高騰」でも、原因構造が違えば対処は変わります。まず原因分類で切り分けます。

| 分類 | 原因 | 代表シナリオ | Heap パターン |
|------|------|------------|--------------|
| 保持遅延型（時間軸） | decision_wait 中のバッファ | Tail Sampling | 急騰→高止まり→解放 |

Tail Sampling を選んだ理由は、メモリ高騰に遭遇しやすく広く使われているプロセッサであり、かつパラメータ調整で改善幅が大きいためです。
時間軸（待ち時間）を押さえると、他の保持遅延系シナリオにも診断手順を転用できます。

## 4. 実践検証: Tail Sampling（保持遅延型）

再現条件は `decision_wait: 30s` と `10s` の比較、負荷は 5000 spans/sec を2分です。  
まず Grafana で Heap Memory を比較すると、30s は 300MB 超に張り付き GC が追いつかず、10s はバッファ解放が速く定常的な高止まりが緩和されました。

![decision_wait=30s の Heap Memory](./scenario-reports/tail-sampling/images/30s-heap-memory.png)
![decision_wait=10s の Heap Memory](./scenario-reports/tail-sampling/images/10s-heap-memory.png)

最重要は、エンドツーエンドでどこで失われたかを示すパイプラインファネル分析です。

| ステージ | 30s | 10s |
|---------|-----|-----|
| Loadgen 送信 | 611,844 spans | 614,628 spans |
| Receiver Accepted | ~340,009 (55.6%) | ~549,457 (89.4%) |
| クライアント側損失 | ~271,476 (44.4%) | ~65,040 (10.6%) |
| Exporter Sent | ~270,273 (44.2%) | ~525,376 (85.5%) |

loadgen のエラーログ回数は 30s で4回、10s で1回でしたが、この件数だけでは損失規模は見えません。  
パイプラインファネル分析で初めて、実損失率が 44.4% と 10.6% まで開いていることが可視化されます。  
Receiver Refused は 0.1% 未満で、損失の主経路はクライアント側タイムアウトでした。  
Tail Sampling 固有メトリクスでは `traces_on_memory` が 30s=55,020、10s=89,801 で、10s の方が受入量増加により高くなりました。  
判定バックログは 30s=20.5%、10s=4.4% で、長い `decision_wait` の滞留影響が明確です。

pprof の `top` を上位6件で比較すると、pdata 系の割当が大きく減っています。

| 順位 | 関数 | 30s (flat) | 10s (flat) |
|------|------|-----------|-----------|
| 1 | `pdata/internal.(*AnyValue).UnmarshalProto` | 161.53 MB | 84.01 MB |
| 2 | `pdata/internal.CopyKeyValueSlice` | 35.51 MB | 18.00 MB |
| 3 | `pdata/internal.NewSpan` | 25.51 MB | 14.00 MB |
| 4 | `pdata/internal.CopyAnyValue` | 15.50 MB | — |
| 5 | `tailsamplingprocessor.NewDropOldTracesLimiter` | 15.27 MB | 15.27 MB |
| 6 | `grpc/mem.NewTieredBufferPool` | 12.80 MB | 12.80 MB |

- [ ] TODO: pprofのソースを表示

<!-- pdata 層全体でも 238MB → 121MB（49%削減）でした。`flat` では tail_sampling 本体は 5-8% 程度ですが、`cum` では `tailsamplingprocessor.processTraces` が 27-30% を占め、保持の原因者であることが分かります。 -->

- [ ] TODO: 下の画像(画像はここでは例)でtail_samplingprocessorが大元の原因であることを示す

![pprof の flame graph。`tailsamplingprocessor.processTraces` → pdata 層の呼び出しツリーがメモリ保持の主要経路](./scenario-reports/tail-sampling/images/pprof-flamegraph.png)

メカニズムは `バッファ ≈ decision_wait × 流量 × スパンサイズ` で説明でき、実測は概算の約3倍です。  
最終的に `decision_wait: 30s→10s` でエンドツーエンドのスループットは 44% から 86% へ改善しました。

> 詳細: [Tail Sampling 詳細レポート](./scenario-reports/tail-sampling/report.md)

## 5. ベストプラクティス

## 6. まとめ
