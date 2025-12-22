# 診断レポート: シナリオ1 - 下流（バックエンド）の停止

## 1. 概要
Jaeger 等の下流サービスが完全に停止した際の OTel Collector の挙動を検証。データがエクスポートできずメモリ上の Queue に滞留し、最終的にメモリ制限（memory_limiter）が発火するまでのプロセスを記録した。

## 2. 再現条件
- **設定**: `sending_queue.queue_size: 500` (バッチ単位)
- **負荷**: `loadgen` による秒間約 6,000 スパンの送信
- **アクション**: `docker compose stop jaeger` による強制停止

## 3. 観測されたシグネチャ（メトリクス）

| メトリクス | 挙動 | 意味 |
|-----------|------|------|
| `otelcol_exporter_queue_size` | **0% → 100%** | エクスポート待ちデータが Queue を埋め尽くした状態。 |
| `otelcol_process_runtime_heap_alloc_bytes` | **急増 → 急落 → 高止まり** | Queue 蓄積によるメモリ消費。リミッター発火による強制 GC とその後の拒否。 |
| `otelcol_receiver_refused_spans_total` | **増加開始** | Processor が受け入れを拒否した結果、Receiver 側でカウントされる拒否数。 |
| `otelcol_processor_accepted_spans_total` | **急減** | Collector 内部のパイプラインに流れるデータが遮断されたことを示す。 |

## 4. 詳細分析

### メモリの「急落」と「高止まり」
メモリグラフで見られた急激な下落は、`memory_limiter` が設定値（limit）に達した際に、Go ランタイムに対して **Force GC** を発行したことによるもの。これにより、不要なオブジェクトが清掃されるが、Queue が満杯のままであるため、メモリは解放されきらずにリミット付近で高止まりする。

### データ拒否のメカニズム
本環境（v0.140.1）では、`otelcol_processor_refused_*` ではなく、**`otelcol_receiver_refused_spans_total`** が拒否の主指標となる。これは、パイプライン上の Processor（memory_limiter）が受け入れを拒否した際に、その上流である Receiver が送信元に対して拒否（gRPC エラー等）を返すためである。

## 5. 結論と教訓
- **Queue は「メモリ爆弾」になる**: 下流停止時、巨大すぎる Queue 設定は Collector の OOM クラッシュを招く。
- **memory_limiter は最後の砦**: リミッターが適切に設定されていれば、メモリを使い切る前に強制 GC と拒否が走り、Collector のプロセス自体は守られる。
- **診断のポイント**: Queue Usage が 100% で、かつ `receiver_refused` が出ている場合は、真っ先に下流のヘルスチェックを行うべきである。

