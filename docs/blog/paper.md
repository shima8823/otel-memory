# OpenTelemetry Collector のメモリ高騰をデバッグする — シナリオで学ぶ実践ガイド

## 1. はじめに

ある朝、Grafana のダッシュボードを開くと、OTel Collector の Heap メモリが右肩上がりに張り付いていた。しばらくすると `memory_limiter` が発火し、スパンが refused され始める。最終的には OOM Kill でコンテナごと落ちた。——OTel Collector を運用していて、似たような経験をしたことはないだろうか。

私たちのチームでは、案件で OpenTelemetry Collector を導入する機会が増えてきた。Receiver、Processor、Exporter を組み合わせてパイプラインを定義できる柔軟さは強力だが、プラグインのパラメータ調整が甘いと、メモリ使用量が静かに膨らんでいく。問題が顕在化するのは負荷が本番レベルに達したときで、そのときにはすでにデータが欠損している。メトリクスやトレースの欠損は観測精度の低下で済むかもしれないが、ログパイプラインで監査ログを扱っている場合、ドロップされたデータは二度と復元できない——**監査ログの欠損はコンプライアンス違反に直結しうる**。

厄介なのは、同じ「メモリ高騰」でも原因構造が一様ではない点だ。バッファの保持時間が長すぎるのか、内部状態のカーディナリティが爆発しているのか、キューにデータが滞留しているのか。原因が違えば対処もまったく変わる。闇雲にコンテナのメモリを増やしても根本解決にはならない。

本記事では、メモリ高騰を引き起こす3つの代表的なシナリオを再現環境で実際に発生させ、Grafana メトリクスと pprof heap profile を使って診断・最適化する過程を追体験する。

- **Tail Sampling**（保持遅延型）: `decision_wait` 中のトレースバッファ蓄積
- **高カーディナリティ**（状態膨張型）: spanmetrics connector の内部マップ膨張
- **Batch x Queue メモリ増幅**（キュー滞留型）: バッファサイズの掛け算効果

対象読者は、OTel Collector を運用中または導入検討中のエンジニアである。「設定は動いているけど、メモリ周りが不安」という方にこそ読んでみてほしい。

本記事の検証は OpenTelemetry Collector Contrib v0.140.1（2026 年 2 月時点の最新版）、コンテナメモリ制限 512MB の環境で実施した。バージョンによりデフォルト値やメトリクス名が異なる場合がある。

## 2. デバッグの基本技法

メモリ問題に遭遇したとき、まず何を見るべきだろうか。コンテナの RSS が上がっている、OOM Kill が発生した——そこまではわかる。しかし「なぜ上がっているのか」を特定するには、適切な計器が必要である。

診断手段は大きく2つある。**内部メトリクス**（Grafana で可視化）と **pprof**（heap profile）だ。

### 主要メトリクス

| メトリクス | 何がわかるか |
|-----------|------------|
| `otelcol_process_runtime_heap_alloc_bytes` | 現在の Heap 使用量。GC 後も下がらなければリーク疑い |
| `otelcol_receiver_refused_spans_total` | `memory_limiter` が拒否したスパン数。データドロップの直接的な信号 |
| `otelcol_exporter_queue_size` | Exporter の送信キュー使用量。100% 張り付きは下流の遅延・停止を示す |

まずはこの3つを押さえてほしい。メモリ高騰の初動対応はこれで十分回る。加えて、Processor / Connector 固有のメトリクス（`otelcol_processor_<name>_*`）を Prometheus API で列挙すると、パイプライン内部のどこでデータが滞留しているかを特定できる。

### pprof

pprof は Go の profiling tool で、Collector の `pprof` extension を有効にすると heap profile を取得できる。読み方のポイントは `flat` と `cum` の違いである。

- **flat**: その関数が直接確保したメモリ量
- **cum**: その関数経由で確保された合計量。「保持の原因者」を特定するにはこちらを見る

例えば `tail_sampling` は flat では全体の 5-8% に過ぎないが、cum では 27-30% を占める。flat だけ見ていると原因を見逃す——この違いは後のシナリオで繰り返し重要になるので、覚えておいてほしい。

### 再現環境

本記事のシナリオは以下の環境で再現できる。

```bash
git clone <リポジトリ URL>
docker compose up -d    # Collector, Prometheus, Jaeger, Grafana
```

pprof extension は Collector 設定で有効化済み。Grafana は `http://localhost:3000` でアクセスできる。
詳細な環境構築手順は [debug-basics.md](./debug-basics.md) を参照。

### 診断フロー

```
メトリクスで異常検知 → pprof で原因特定 → パラメータ調整 → 再テストで改善確認
```

この4ステップを各シナリオで繰り返す。単純に見えるかもしれないが、各ステップで「何を見るべきか」がわからないと手が止まる。次章以降のシナリオでは、それぞれのステップで具体的に何を確認し、どう判断したかを詳しく追っていく。

## 3. シナリオ選定の設計思想

同じ「メモリ高騰」でも、原因構造が違えば対処が変わる。本記事では原因を3つの軸で分類し、それぞれの代表シナリオを選定した。

| 分類 | 原因の軸 | 代表シナリオ | Heap パターン |
|------|---------|------------|-------------|
| 保持遅延型 | 時間軸 | Tail Sampling | 急騰 → 高止まり → 解放 |
| 状態膨張型 | 空間軸 | 高カーディナリティ（spanmetrics） | 右肩上がり（GC 後も戻らない） |
| キュー滞留型 | 流量軸 | Batch x Queue メモリ増幅 | soft_limit 付近で振動 |

**Tail Sampling** は `decision_wait` というパラメータ1つの変更で症状が劇的に変わる。単因子性と調整可能性に優れ、診断の型を学ぶ教材として最適である。

**高カーディナリティ** は開発環境では問題なく、本番のトラフィックで突然顕在化する。GC 後もメモリが戻らないという特徴的なシグネチャを持ち、実務頻度が高い。

**Batch x Queue メモリ増幅** は `send_batch_size x queue_size` の掛け算がメモリ消費を決定する。本記事の検証環境では `queue_size: 500` を使用したが（v0.140.1 時点）、デフォルト値はバージョンにより異なるため注意が必要である。いずれにせよ、掛け算の結果として理論最大が数 GB に達し、コンテナ制限を容易に超過しうる。デフォルト値の危険性という実務的な教訓を含む。

ここで覚えておきたいのは、**Heap パターンの形で原因を鑑別できる** ことだ。急騰後に負荷停止で回復するなら保持遅延型、右肩上がりで戻らないなら状態膨張型、soft_limit 付近で振動するならキュー滞留型。Grafana を見慣れてくると、グラフの形だけで原因の見当がつくようになる。少なくとも私たちの検証ではそうだった。このパターン認識が初動の切り分けを速くしてくれる。

## 4. 実践検証 — Tail Sampling

**`decision_wait: 30s → 10s` の短縮だけで、エンドツーエンドスループットが 44% → 86% に改善する。**

### 再現条件

`tail_sampling` processor の `decision_wait` のみを変更し、他は同一条件で比較した。

```yaml
# 非最適化
tail_sampling:
  decision_wait: 30s
  num_traces: 1000000
  policies:
    - name: always-sample
      type: always_sample

# 最適化（唯一の差分）
tail_sampling:
  decision_wait: 10s
```

負荷条件: sustained モード、5,000 spans/sec、2分間、コンテナメモリ 512MB。

### Grafana 観測

#### Heap Memory

![decision_wait=30s の Heap Memory](./scenario-reports/tail-sampling/images/30s-heap-memory.png)

30s では負荷開始から約30秒で Heap が 344MB に到達し、300MB 超で高止まりする。`decision_wait` 中のトレースバッファが蓄積され、GC による解放が追いつかない。

![decision_wait=10s の Heap Memory](./scenario-reports/tail-sampling/images/10s-heap-memory.png)

10s ではピーク値こそ 332MB と 30s に近いが、バッファ解放が速いため定常中央値は約 250MB に低下する。

| 指標 | 30s | 10s | 変化 |
|------|-----|-----|------|
| Heap ピーク | 344 MB | 332 MB | -4% |
| 定常中央値 | ~320 MB | ~250 MB | -22% |

### パイプラインファネル分析

当初、私たちは Receiver の rate メトリクスや loadgen のエラーログで損失を把握しようとした。memory_limiter の Refused メトリクスを見れば損失規模がわかるだろうと考えていたのである。しかし実際にファネル分析をしてみると、その前提は間違っていた。`increase()` ベースの累計カウントでパイプライン全体のデータフローを定量化すると、損失の実態はまったく違う場所にあった。

| ステージ | 30s | 10s |
|---------|-----|-----|
| Loadgen 送信 | 611,844 spans | 614,628 spans |
| Receiver Accepted | ~340,009 (55.6%) | ~549,457 (89.4%) |
| Receiver Refused | ~359 (0.06%) | ~131 (0.02%) |
| **クライアント側損失** | **~271,476 (44.4%)** | **~65,040 (10.6%)** |
| Exporter Sent | ~270,273 (44.2%) | ~525,376 (85.5%) |

ここで注目すべきは、**Receiver Refused（memory_limiter の直接拒否）が両シナリオとも 0.1% 未満** であることだ。これは想定外だった。データ損失の 99% 以上は memory_limiter ではなく、Collector がメモリ圧力で gRPC エラーを返した際の**クライアント側タイムアウト**（`context deadline exceeded`）で発生していたのである。

- 30s: クライアント側で 44.4%（~271,000 spans）が消失
- 10s: クライアント側で 10.6%（~65,000 spans）が消失

loadgen のエラーログは 4回 vs 1回に過ぎず、この損失規模はファネル分析なしには見えない。

### pprof 解析

pdata は OTel Collector の内部データ表現で、受信した Protocol Buffers メッセージを Go の構造体にデシリアライズしたものである。pprof で最も頻出する割当元となる。

| カテゴリ | 30s | 10s | 変化 |
|---------|-----|-----|------|
| **pdata（トレースデータ保持）** | 238 MB (74.4%) | 121 MB (59.9%) | **-49%** |
| tail_sampling 管理構造 | 15.3 MB (4.8%) | 15.3 MB (7.6%) | 変化なし |
| gRPC バッファ | 12.8 MB (4.0%) | 12.8 MB (6.4%) | 変化なし |
| **合計** | **320 MB** | **201 MB** | **-37%** |

`decision_wait` の短縮で影響を受けるのは **pdata 層のみ** である。管理構造や gRPC バッファは `decision_wait` に依存せず一定。つまり、`decision_wait` の調整はバッファに保持されるトレースデータ量にのみ効く。

pprof の読み方で重要なのは flat と cum の違いである。

```
30s: tailsamplingprocessor.processTraces — flat 5-8%, cum 27.5%
10s: tailsamplingprocessor.processTraces — flat 5-8%, cum 29.8%
```

flat が小さくても cum が大きい関数は「保持の原因者」である。tail_sampling が pdata に保持を指示した結果のメモリ消費は cum に現れる。

![pprof flame graph](./scenario-reports/tail-sampling/images/pprof-flamegraph.png)

### メカニズム

バッファメモリの概算式:

```
バッファ ≈ decision_wait x スパン流量 x 平均スパンサイズ
```

| パラメータ | 30s | 10s |
|-----------|-----|-----|
| 概算バッファ | 75 MB | 37 MB |
| pprof 実測（pdata 層） | 238 MB | 121 MB |
| **実測/概算 倍率** | **3.2x** | **3.3x** |

概算値と3倍も乖離するのかと最初は疑ったが、Go のオブジェクトヘッダ、Protocol Buffers のデシリアライズ構造（`UnmarshalProto` が flat の 40-50%）、スライスの容量拡張、GC の解放タイミングを考えると、この倍率は一貫して再現する。見積もりには **概算値の3倍** を安全マージンとして見込む必要がある。

### 最適化の要点

`decision_wait` の短縮は最も即効性が高く、副作用が小さい最適化手段である。

| 指標 | 30s | 10s | 改善 |
|------|-----|-----|------|
| エンドツーエンド スループット | 44.2% | 85.5% | **+41.3pt** |
| pdata 消費 | 238 MB | 121 MB | **-49%** |
| クライアント側損失率 | 44.4% | 10.6% | **-33.8pt** |
| Refused rate ピーク | 4.65/s | 1.75/s | **-62%** |

ただし 10s でも GC の振動で `spike_limit_percentage` のソフトリミット（`soft_limit = コンテナメモリ × (limit_percentage − spike_limit_percentage) = 512MB × (80% − 20%) = 307MB`）を一時的に超えるため、低頻度ながら memory_limiter の発火が残る。完全な解消にはメモリ増量、`spike_limit_percentage` の緩和、`num_traces` の適正化、ポリシーの見直しなどが必要になる。

> 詳細: [Tail Sampling 詳細レポート](./scenario-reports/tail-sampling/report.md)

## 5. 実践検証: 高カーディナリティ（状態膨張型）

**`dimensions` に UUID を含めると 93 秒で OOM Kill。memory_limiter はステートフルな内部状態には無力である。**

memory_limiter を設定していれば安全だと思っていた。この検証で、その前提が崩れた。

### 再現条件

`spanmetrics` connector の `dimensions` に UUID 属性 8 個（`attr_0`〜`attr_7`）を指定し、1,300 traces/sec（7,800 spans/sec）を 300 秒間投入した。コンテナメモリは 512 MB、`memory_limiter` は `limit_percentage: 80`, `spike_limit_percentage: 20`（soft_limit = 307 MB）。最適化版では `dimensions: []`（デフォルトキーのみ）に変更し、他のパラメータは同一条件とした。

```yaml
# 非最適化
dimensions:
  - name: attr_0
  - name: attr_1
  # ... attr_7 まで
dimensions_cache_size: 10000000  # deprecated: aggregation_cardinality_limit を推奨
aggregation_temporality: AGGREGATION_TEMPORALITY_CUMULATIVE

# 最適化
dimensions: []   # デフォルトキーのみ（service.name, span.name, span.kind, status.code）
```

### Grafana 観測

![Heap Memory — 非最適化](./scenario-reports/high-cardinality/images/non-opt-heap-memory.png)

非最適化版は開始から 15 秒で Heap が 257 → 317 MB に急騰（+60 MB/15 秒）。メトリクスはわずか 2 ポイントで途切れた。93 秒で OOM Kill に至る速さには正直驚いた。

![Heap Memory — 最適化](./scenario-reports/high-cardinality/images/opt-heap-memory.png)

最適化版は 300 秒間完走し、Heap は 20〜41 MB で GC による正常な振動を示した。21 ポイントのメトリクスが途切れなく取得できた。

| 指標 | 非最適化 | 最適化 | 変化 |
|------|---------|--------|------|
| Heap ピーク | 317.88 MB | 41.49 MB | **-87%** |
| RSS ピーク | 490.75 MB（limit の 96%） | 200.87 MB（39%） | -59% |
| Refused Spans | 1,920 | 0 | -100% |

### OOM Kill の間接証拠

OOM Kill そのものは Prometheus メトリクスに記録されない。しかし「データが取れなくなること自体」が OOM Kill の強い兆候となる。

| 証拠 | 非最適化 | 最適化 |
|------|---------|--------|
| pprof 取得数 | 19 本（93 秒で途切れ） | 69 本（全期間） |
| メトリクス取得数 | 2 ポイント | 21 ポイント |
| RSS 最終値 | 490.75 MB（96%） | 200.87 MB（39%） |

pprof endpoint が 93 秒で応答不能になり、直後にメトリクスも途絶している。プロセスが生きていれば scrape は継続するはずであり、この断絶が OOM Kill の強い兆候である。本番環境では `dmesg | grep -i oom` や Kubernetes の `kubectl describe pod` で `OOMKilled` ステータスを確認することで最終的な裏付けが取れる。

### pprof 解析

非最適化の inuse_space は 265.67 MB。累積（cum）で `spanmetricsconnector.aggregateMetrics` が **79%** を占めた。

| 順位 | Flat | 関数 |
|------|------|------|
| 1 | 71.53 MB | `pcommon.Map.EnsureCapacity` |
| 2 | 71.53 MB | `bytes.(*Buffer).String` |
| 3 | 33.00 MB | `pdata/internal.(*AnyValue).UnmarshalProto` |
| 4 | 24.05 MB | `spanmetricsconnector.explicitHistogramMetrics.GetOrCreate` |

最適化版は inuse_space が 19.90 MB。top 5 に **spanmetrics 関連の関数が一切登場しない**。`dimensions: []` により内部マップのエントリ数がサービス × オペレーション × ステータスの数種類に限定され、メモリ消費が無視できるレベルになった。

### memory_limiter が効かない理由

ここが Tail Sampling との決定的な違いであり、この検証の核心でもある。

- **Tail Sampling**: 負荷停止 → `decision_wait` を過ぎたバッファが解放 → Heap 復帰。memory_limiter の受信拒否が効く
- **高カーディナリティ**: 受信を拒否しても `spanmetrics` の内部マップ（CUMULATIVE temporality）は縮小しない → Heap は下がらない → OOM Kill

memory_limiter は「新規データの流入を止める」仕組みであり、既にステートフル processor/connector に蓄積された内部状態には memory_limiter だけでは対処できない。少なくとも本検証の条件（CUMULATIVE temporality、高カーディナリティ属性）では、memory_limiter だけに頼る設計は不十分だった。

### 最適化

変更は `dimensions` から高カーディナリティ属性を除外するだけ。設定1行の変更で Heap **-87%**、OOM Kill が完全解消した。実務では `user_id`、URL パスパラメータ（`/users/{id}`）、SQL クエリ文字列（`db.statement`）が同じ罠に嵌まりやすい。`dimensions` に追加する前にカーディナリティを確認しておくことをお勧めする。

> 詳細: [高カーディナリティ詳細レポート](./scenario-reports/high-cardinality/report.md)

## 6. 実践検証: Batch × Queue メモリ増幅（キュー滞留型）

**`send_batch_size × queue_size` の掛け算の罠 — 個別に妥当でも、掛け算がメモリ予算を超過する。**

ここで一つ、読者にも計算してみてほしい。8192 も 500 も、設定値として見れば特別大きくはない。だが掛け算してみると話が変わる。

### 再現条件

非最適化（batch=8192, queue=500）と最適化（batch=2048, queue=50）の 2 条件で比較した。Jaeger を `cpus: 0.2` に制限して「バックエンドが遅い」状態を模擬し、4,000 traces/sec × 10 workers を 180 秒間投入した。

### Grafana 観測

![Heap Memory — 非最適化](./scenario-reports/batch-queue/images/heap-non-optimized.png)

非最適化版は Heap が 344 MB に達し、soft_limit（307 MB）を 37 MB 超過。memory_limiter が持続的に発火し、180 秒で約 2,400 spans がドロップした。

![Heap Memory — 最適化](./scenario-reports/batch-queue/images/heap-optimized.png)

最適化版は Heap ピーク 224 MB で soft_limit を 83 MB 下回り、Refused ゼロで完走した。

| 指標 | 非最適化 | 最適化 | 変化 |
|------|---------|--------|------|
| Heap ピーク | 344 MB | 224 MB | **-35%** |
| Refused 累計 | 2,400 spans | 0 | -100% |
| Queue 使用率 | 9%（46/500） | 100%（50/50） | — |
| Queue メモリ | 213 MB | 59 MB | -72% |

### 掛け算の罠

| 設定 | 計算 | 理論最大 |
|------|------|---------|
| 非最適化 | 8,192 × 500 × 580 B | **2.4 GB**（コンテナの 5 倍） |
| 最適化 | 2,048 × 50 × 580 B | **59 MB**（コンテナの 12%） |

`send_batch_size: 8192` も `queue_size: 500` も、私たちも最初は単体で見て問題ないと判断していた。しかし掛け算すると理論最大 2.4 GB となり、Queue が **わずか 9%** 埋まっただけで soft_limit を突破する。最適化版は Queue が **100%** に達しても 59 MB で安全圏内である。

### pprof の特徴

このシナリオでは pprof の top に batch/queue 固有の関数が登場しない。メモリの 81% は pdata（スパンデータのデシリアライズ）が占める。これは sending_queue に保持されたバッチ内のスパンデータそのものである。

「直接の確保者」（pdata 関数）と「保持の原因者」（sending_queue）が異なるため、pprof の `flat` だけを見ると原因を見落とす。Grafana の Queue Usage メトリクスと組み合わせて初めて、queue 滞留がメモリ肥大化の根本原因であることを特定できる。

### メモリ予算からの逆算

設定を変更する前に、電卓でこの掛け算を一度叩いてみてほしい。

```
queue_size × send_batch_size × span_size < soft_limit − オーバーヘッド
```

本シナリオ: soft_limit = 307 MB、オーバーヘッド ≈ 150 MB → queue 予算 = 157 MB。非最適化の 2.4 GB は論外であり、最適化の 59 MB は余裕で収まる。

> 詳細: [Batch × Queue 詳細レポート](./scenario-reports/batch-queue/report.md)

## 7. ベストプラクティス

3 つのシナリオで痛い目を見た結果、行き着いた原則が 3 つある。

### 原則 1: 制限を先頭に

`memory_limiter` はパイプラインの **最初の processor** に配置する。[OpenTelemetry 公式ドキュメント](https://opentelemetry.io/docs/collector/configuration/#recommended-processors)でも推奨されている配置である。後段に置くと、ステートフル processor がメモリを確保した後でしか発火せず、手遅れになる。ただし高カーディナリティシナリオで見たとおり、memory_limiter は受信拒否しかできない。既にステートフルな内部状態に蓄積されたデータには無力であるため、次の原則 2 が不可欠である。

### 原則 2: ステートフルを疑う

`tail_sampling`、`spanmetrics`、`groupbyattrs` を導入する際は、内部状態のカーディナリティ上限を事前に確認する。固定閾値ではなく、以下の予算式で判断する。

```
ユニーク系列数 × 1系列あたり推定メモリ（数百B〜数KB） < コンテナメモリ予算
```

本検証環境では 390,000 エントリ × 数百 B → 265 MB に達し、512 MB コンテナで OOM Kill に至った。CUMULATIVE temporality の場合、`UUID`、`request_id`、`session_id` のような高カーディナリティ属性は含めない方がよい。DELTA temporality であれば TTL で回収されるケースもあるが、安全側に倒すなら除外が無難だ。

### 原則 3: バッファを見積もる

`send_batch_size × queue_size × span_size` を計算してみてほしい。Tail Sampling なら `decision_wait × 流量 × スパンサイズ`。設定変更前にメモリ予算との突合を行い、理論最大がコンテナ制限の 60% 以下に収まることを確認する。

### 監視アラート

```promql
# Heap 異常上昇（5分間で 50MB 以上の増加）
delta(otelcol_process_runtime_heap_alloc_bytes[5m]) > 50 * 1024 * 1024

# Refused 発生（memory_limiter 発火）
rate(otelcol_receiver_refused_spans_total[5m]) > 0

# Queue 飽和（90% 以上）
otelcol_exporter_queue_size / otelcol_exporter_queue_capacity > 0.9
```

この 3 つのアラートを設定しておけば、メモリ高騰の兆候を早期に検知できる。Heap 上昇で異常を察知し、Refused で実害発生を確認し、Queue 飽和で下流障害の影響を把握する。

> 詳細: [ベストプラクティス](./best-practices.md)

## 8. まとめ

ここまでの検証結果を振り返ろう。

| シナリオ | 変更内容 | Heap 削減 | データドロップ |
|---------|---------|----------|-------------|
| Tail Sampling | `decision_wait`: 30s → 10s | -37% | 44.4% → 10.6%（損失率） |
| 高カーディナリティ | `dimensions` から UUID 除外 | -87% | OOM → 0% |
| Batch × Queue | batch × queue: 40 倍削減 | -35% | 2,400 → 0 spans |

振り返ってみると、いずれも「デフォルト値のまま」あるいは「なんとなく大きめに設定した」状態が原因であり、設定パラメータの意味とメモリへの影響を理解した上で調整すれば劇的に改善する。

3 つのシナリオに共通して得られた教訓をまとめる。

1. **デフォルト値は安全とは限らない。** OTel Collector のデフォルト設定はスループット優先の傾向があり、メモリ制約を考慮していない。コンテナ環境では必ずメモリ予算に合わせた調整が必要である
2. **Grafana + pprof の組み合わせが診断の基本。** Grafana でマクロな挙動（Heap 推移、Queue 使用率、Refused 発生）を把握し、pprof でミクロな原因（どの関数がメモリを確保・保持しているか）を特定する。どちらか一方では不十分である
3. **設定変更前にメモリ予算を計算する。** `batch_size × queue_size × span_size` や `decision_wait × 流量 × span_size` を計算し、soft_limit 以下に収まることを確認してからデプロイする

ここまで読んでくださった方にお勧めしたいのは、今すぐ自環境の OTel Collector 設定ファイルを開いて、この記事で紹介した掛け算を計算してみることだ。もしその数字がコンテナのメモリ制限を超えていたら、この記事が役に立つはずだ。pprof extension を有効にして、負荷テストで一度プロファイルを取ってみてほしい。問題は本番で顕在化する前に、テスト段階で見つけられる。
