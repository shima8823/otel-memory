<!-- Generated Claude Code -->

# OpenTelemetry Collector のメモリ高騰をデバッグする — シナリオで学ぶ実践ガイド

## 1. はじめに

ある朝、Grafana のダッシュボードを開くと、OTel Collector の Heap メモリが右肩上がりに張り付いていました。しばらくすると `memory_limiter` が発火し、スパンが refused され始めます。最終的には OOM Kill でコンテナごと落ちました。——OTel Collector を運用していて、似たような経験をしたことはないでしょうか。

私たちのチームでは、案件で OpenTelemetry Collector を導入する機会が増えてきました。Receiver、Processor、Exporter を組み合わせてパイプラインを定義できる柔軟さは強力ですが、プラグインのパラメータ調整が甘いと、メモリ使用量が静かに膨らんでいきます。問題が顕在化するのは負荷が本番レベルに達したときで、そのときにはすでにデータが欠損しています。メトリクスやトレースの欠損は観測精度の低下で済むかもしれませんが、ログパイプラインで監査ログを扱っている場合、ドロップされたデータは二度と復元できません——**監査ログの欠損はコンプライアンス違反に直結しえます**。

厄介なのは、同じ「メモリ高騰」でも原因構造が一様ではない点です。バッファの保持時間が長すぎるのか、内部状態のカーディナリティが爆発しているのか、キューにデータが滞留しているのか。原因が違えば対処もまったく変わります。闇雲にコンテナのメモリを増やしても根本解決にはなりません。

本記事では、メモリ高騰を引き起こす3つの代表的なシナリオを再現環境で実際に発生させ、Grafana メトリクスと pprof heap profile を使って診断・最適化する過程を追体験します。

- **Tail Sampling**（保持遅延型）: `decision_wait` 中のトレースバッファ蓄積
- **高カーディナリティ**（状態膨張型）: spanmetrics connector の内部マップ膨張
- **Batch x Queue メモリ増幅**（キュー滞留型）: バッファサイズの掛け算効果

対象読者は、OTel Collector を運用中または導入検討中のエンジニアです。「設定は動いているけど、メモリ周りが不安」という方にこそ読んでみてください。

本記事の検証は OpenTelemetry Collector Contrib v0.140.1（2026 年 2 月時点の最新版）、コンテナメモリ制限 512MB の環境で実施しました。バージョンによりデフォルト値やメトリクス名が異なる場合があります。

## 2. デバッグの基本技法

メモリ問題に遭遇したとき、まず何を見るべきでしょうか。コンテナの RSS が上がっている、OOM Kill が発生した——そこまではわかります。しかし「なぜ上がっているのか」を特定するには、適切な計器が必要です。

診断手段は大きく2つあります。**内部メトリクス**（Grafana で可視化）と **pprof**（heap profile）です。

### 主要メトリクス

| メトリクス | 何がわかるか |
|-----------|------------|
| `otelcol_process_runtime_heap_alloc_bytes` | 現在の Heap 使用量。GC 後も下がらなければリーク疑い |
| `otelcol_receiver_refused_spans_total` | `memory_limiter` が拒否したスパン数。データドロップの直接的な信号 |
| `otelcol_exporter_queue_size` | Exporter の送信キュー使用量。100% 張り付きは下流の遅延・停止を示す |

まずはこの3つを押さえてください。メモリ高騰の初動対応はこれで十分回ります。加えて、Processor / Connector 固有のメトリクス（`otelcol_processor_<name>_*`）を Prometheus API で列挙すると、パイプライン内部のどこでデータが滞留しているかを特定できます。

### pprof

pprof は Go の profiling tool で、Collector の `pprof` extension を有効にすると heap profile を取得できます。読み方のポイントは `flat` と `cum` の違いです。

- **flat**: その関数が直接確保したメモリ量
- **cum**: その関数経由で確保された合計量。「保持の原因者」を特定するにはこちらを見る

例えば `tail_sampling` は flat では全体の 7-13% に過ぎませんが、cum では 56% を占めます。flat だけ見ていると原因を見逃します——この違いは後のシナリオで繰り返し重要になるので、覚えておいてください。

### 再現環境

本記事のシナリオは以下の環境で再現できます。

```bash
git clone <リポジトリ URL>
docker compose up -d    # Collector, Prometheus, Jaeger, Grafana
```

pprof extension は Collector 設定で有効化済みです。Grafana は `http://localhost:3000` でアクセスできます。
詳細な環境構築手順は [debug-basics.md](./debug-basics.md) を参照。

### 診断フロー

```
メトリクスで異常検知 → pprof で原因特定 → パラメータ調整 → 再テストで改善確認
```

この4ステップを各シナリオで繰り返します。単純に見えるかもしれませんが、各ステップで「何を見るべきか」がわからないと手が止まります。次章以降のシナリオでは、それぞれのステップで具体的に何を確認し、どう判断したかを詳しく追っていきます。

## 3. シナリオ選定の設計思想

同じ「メモリ高騰」でも、原因構造が違えば対処が変わります。本記事では原因を3つの軸で分類し、それぞれの代表シナリオを選定しました。

| 分類 | 原因の軸 | 代表シナリオ | Heap パターン |
|------|---------|------------|-------------|
| 保持遅延型 | 時間軸 | Tail Sampling | 急騰 → 高止まり → 解放 |
| 状態膨張型 | 空間軸 | 高カーディナリティ（spanmetrics） | 右肩上がり（GC 後も戻らない） |
| キュー滞留型 | 流量軸 | Batch x Queue メモリ増幅 | soft_limit を超過して高止まり |

**Tail Sampling** は `decision_wait` というパラメータ1つの変更で症状が劇的に変わります。単因子性と調整可能性に優れ、診断の型を学ぶ教材として最適です。

**高カーディナリティ** は開発環境では問題なく、本番のトラフィックで突然顕在化します。GC 後もメモリが戻らないという特徴的なシグネチャを持ち、実務頻度が高いシナリオです。

**Batch x Queue メモリ増幅** は `send_batch_size x queue_size` の掛け算がメモリ消費を決定します。本記事の検証環境では `queue_size: 1000`（デフォルト値）を使用しました。掛け算の結果として理論最大が数 GB に達し、コンテナ制限を容易に超過しえます。デフォルト値の危険性という実務的な教訓を含んでいます。

ここで覚えておきたいのは、**Heap パターンの形で原因を鑑別できる** ことです。急騰後に負荷停止で回復するなら保持遅延型、右肩上がりで戻らないなら状態膨張型、soft_limit 付近で高止まりするならキュー滞留型です。Grafana を見慣れてくると、グラフの形だけで原因の見当がつくようになります。少なくとも私たちの検証ではそうでした。このパターン認識が初動の切り分けを速くしてくれます。

## 4. 実践検証 — Tail Sampling

### 再現条件

`tail_sampling` processor を以下の設定で動作させました。

```yaml
tail_sampling:
  decision_wait: 30s
  num_traces: 1000000
  policies:
    - name: always-sample
      type: always_sample
```

負荷条件: telemetrygen 1,500 traces/sec（~9,000 spans/sec 相当）、2分間、コンテナメモリ 512MB。

### 問題の発見（Grafana 観測）

![decision_wait=30s の Heap Memory](./scenario-reports/tail-sampling/captures/non-opt/images/heap_memory.png)

負荷開始から約30秒で Heap が 441 MB に到達し、memory_limiter が持続的に発火しました。`decision_wait: 30s` の間、すべてのトレースがバッファに保持され続けるため、GC による解放が追いつきません。RSS は 641 MB に達しました。

### データドロップの分析

当初、私たちは Receiver の rate メトリクスや loadgen のエラーログで損失を把握しようとしました。memory_limiter の Refused メトリクスを見れば損失規模がわかるだろうと考えていたのです。しかし実際に `increase()` ベースの累計カウントでパイプライン全体のデータフローを定量化すると、損失の実態はまったく違う場所にありました。

| ステージ | 値 |
|---------|-----|
| Loadgen 送信 | 1,598,034 spans |
| Receiver Accepted | 972,883 (60.9%) |
| Receiver Refused | 732 (0.05%) |
| **クライアント側損失** | **624,419 (39.1%)** |
| パイプライン出力 | 841,052 (52.6%) |

ここで注目すべきは、**Receiver Refused（memory_limiter の直接拒否）が 0.05%** に過ぎないことです。これは想定外でした。データ損失の大部分は memory_limiter ではなく、Collector がメモリ圧力で gRPC エラーを返した際の**クライアント側タイムアウト**（`data refused due to high memory usage`）で発生していました。クライアント側で 39.1%（~624,000 spans）が消失したにもかかわらず、loadgen ログでは gRPC エラーはわずか 2 回しか記録されていません。エラーログの回数だけでは、60 万スパンが失われている事実は見えないのです。

### pprof で原因を特定

pdata は OTel Collector の内部データ表現で、受信した Protocol Buffers メッセージを Go の構造体にデシリアライズしたものです。pprof で最も頻出する割当元となります。

| カテゴリ | inuse_space | 割合 |
|---------|-------------|------|
| **pdata（トレースデータ保持）** | 166 MB | 55.9% |
| tail_sampling 管理構造 | 35 MB | 11.9% |
| concurrent map | 13 MB | 4.2% |
| **合計** | **296 MB** | — |

pprof の読み方で重要なのは flat と cum の違いです。

```
tailsamplingprocessor.processTraces — flat 6.8%, cum 55.9%
```

flat では全体の 7% に過ぎませんが、cum では 56% を占めます。flat が小さくても cum が大きい関数は「保持の原因者」です。flat だけ見ていると原因を見逃します。

<!-- 要取得: pprof コールグラフ画像 -->
![pprof コールグラフ — 非最適化](./scenario-reports/tail-sampling/captures/non-opt/images/pprof-graph.png)

### メカニズム

バッファメモリの概算式:

```
バッファ ≈ decision_wait x スパン流量 x 平均スパンサイズ
```

`decision_wait: 30s` の場合、概算バッファ（raw）は ~24 MB ですが、pprof 実測（pdata 層）は 166 MB であり、実測/概算 倍率は **~6.9x** となります。

本テストは telemetrygen のミニマルスパン（カスタム属性なし、raw ~0.1 KB/span）を使用したため、オーバーヘッド倍率が大きく見えます。実運用でカスタム属性が多いスパン（~1 KB/span）の場合、倍率は 2-3x 程度に収束します。いずれにせよ、Go のオブジェクトヘッダ、Protocol Buffers のデシリアライズ構造、スライスの容量拡張により、**概算値の数倍** を安全マージンとして見込む必要があります。

### 最適化

原因は `decision_wait: 30s` の間にバッファが蓄積し続けることでした。そこで `decision_wait` を 10s に短縮します。

```yaml
tail_sampling:
  decision_wait: 10s
```

![decision_wait=10s の Heap Memory](./scenario-reports/tail-sampling/captures/opt/images/heap_memory.png)

Heap ピークは 316 MB に低下し、memory_limiter が**一度も発火しませんでした**。バッファの保持期間が 1/3 になったことで、GC が追いつくようになりました。

パイプラインファネルも劇的に改善しました。Loadgen 送信 1,609,986 spans に対し、Receiver Accepted は ~100%、クライアント側損失は**ゼロ**、パイプライン出力は 1,542,263 spans（95.8%）に達しました。gRPC エラーも発生していません。

pprof では pdata 層が 166 MB → 79 MB（-53%）に削減されました。管理構造はスループット向上に伴い 35 → 42 MB に微増しますが、pdata の削減量に比べると軽微です。cum の占有率は 56% でほぼ一定であり、`decision_wait` を変えても影響割合は変わらず、絶対量のみが変わることが確認できました。

ただし Heap ピーク（316 MB）は `spike_limit_percentage` のソフトリミット（`soft_limit = コンテナメモリ × (limit_percentage − spike_limit_percentage) = 512MB × (80% − 20%) = 307MB`）付近であり、負荷条件によっては再発しえます。マージンを確保するにはメモリ増量、`spike_limit_percentage` の緩和、`num_traces` の適正化、ポリシーの見直しなどが必要になります。

### 最適化の要点

`decision_wait` の短縮は最も即効性が高く、副作用が小さい最適化手段です。

| 指標 | 30s | 10s | 改善 |
|------|-----|-----|------|
| Heap ピーク | 441 MB | 316 MB | **-28%** |
| RSS ピーク | 641 MB | 502 MB | **-22%** |
| パイプライン スループット | 52.6% | 95.8% | **+43.2pt** |
| pdata 消費 | 166 MB | 79 MB | **-53%** |
| クライアント側損失率 | 39.1% | ~0% | **-39.1pt** |
| Refused rate ピーク | 7.29/s | 0/s | **-100%** |
| memory_limiter | 発火あり | **発火なし** | 解消 |

> 詳細: [Tail Sampling 詳細レポート](./scenario-reports/tail-sampling/report.md)

## 5. 実践検証: 高カーディナリティ（状態膨張型）

memory_limiter を設定していれば安全だと思っていました。この検証で、その前提が崩れました。

### 再現条件

`spanmetrics` connector の `dimensions` に 5 属性を指定しました。個々の属性値は妥当（API endpoint 50種、backend host 30台 等）ですが、掛け算で **1,500,000** のユニーク組み合わせが発生します。

```yaml
# 50 × 30 × 20 × 10 × 5 = 1,500,000 組み合わせ
dimensions:
  - name: attr_0    # API endpoint 相当 (50種)
  - name: attr_1    # backend host 相当 (30種)
  - name: attr_2    # deploy version 相当 (20種)
  - name: attr_3    # client region 相当 (10種)
  - name: attr_4    # HTTP method 相当 (5種)
aggregation_temporality: AGGREGATION_TEMPORALITY_CUMULATIVE
```

負荷条件: 1,300 traces/sec（7,800 spans/sec）、300 秒間、コンテナメモリ 512 MB。`memory_limiter` は `limit_percentage: 80`, `spike_limit_percentage: 20`（soft_limit = 307 MB）。

なお、本検証では短時間で OOM Kill を再現するため dimensions を 5 個に設定しました。実務では 1-2 個の高カーディナリティ属性（user_id, http.target 等）でも、長時間運用で同様の問題が発生します。

### 問題の発見（Grafana 観測）

![Heap Memory — 非最適化](./scenario-reports/high-cardinality/captures/non-opt/images/heap_memory.png)

開始から約50秒で Heap が 312 MB に達し、メトリクスが 1 ポイントで途切れました。RSS は 491 MB（limit の 96%）に達し、直後に OOM Kill が発生する速さには正直驚きました。

### OOM Kill の間接証拠

OOM Kill そのものは Prometheus メトリクスに記録されません。しかし「データが取れなくなること自体」が OOM Kill の強い兆候となります。

| 証拠 | 観測値 |
|------|--------|
| pprof 取得数 | 24 本（50 秒で途切れ） |
| メトリクス取得数 | 1 ポイント |
| RSS 最終値 | 491.27 MB（96%） |
| Refused Spans | 2,676（発火するも OOM Kill） |

pprof endpoint が 50 秒で応答不能になり、直後にメトリクスも途絶しています。memory_limiter が発火して Refused Spans を記録している（2,676 spans）にもかかわらず OOM Kill が発生した点が重要です。受信を拒否しても `spanmetrics` の内部マップは縮小しません。本番環境では `dmesg | grep -i oom` や Kubernetes の `kubectl describe pod` で `OOMKilled` ステータスを確認することで最終的な裏付けが取れます。

### pprof で原因を特定

inuse_space は 301.58 MB。spanmetrics 関連関数が累積（cum）で **90%** を占めました。

| 順位 | Flat | 関数 |
|------|------|------|
| 1 | 113.53 MB | `pcommon.Map.EnsureCapacity` |
| 2 | 33.17 MB | `spanmetricsconnector.explicitHistogramMetrics.GetOrCreate` |
| 3 | 29.50 MB | `bytes.(*Buffer).String` |
| 4 | 28.50 MB | `pdata/internal.CopyAnyValue` |

<!-- 要取得: pprof コールグラフ画像 -->
![pprof コールグラフ — 非最適化](./scenario-reports/high-cardinality/captures/non-opt/images/pprof-graph.png)

`Map.EnsureCapacity` が 113 MB で突出しています。これは spanmetrics connector が内部マップに新しい組み合わせを登録するたびに呼ばれる関数であり、1,500,000 のユニーク組み合わせがそのままメモリ消費に直結していることを示しています。

### memory_limiter が効かない理由

ここが Tail Sampling との決定的な違いであり、この検証の核心でもあります。

- **Tail Sampling**: 負荷停止 → `decision_wait` を過ぎたバッファが解放 → Heap 復帰。memory_limiter の受信拒否が効きます
- **高カーディナリティ**: `spanmetrics` の内部マップ（CUMULATIVE temporality）の成長速度が memory_limiter のチェック間隔を上回ります。memory_limiter は発火して 2,676 spans を拒否しましたが、受信を止めても内部マップは縮小しないため OOM Kill を防げませんでした

memory_limiter は「新規データの流入を止める」仕組みであり、既にステートフル processor/connector に蓄積された内部状態には memory_limiter だけでは対処できません。少なくとも本検証の条件（CUMULATIVE temporality、高カーディナリティ属性）では、memory_limiter だけに頼る設計は不十分でした。

### 最適化

変更は `dimensions` から高カーディナリティ属性（attr_0: 50種、attr_1: 30種）を除外するだけです。

```yaml
# 20 × 10 × 5 = 1,000 組み合わせ
dimensions:
  - name: attr_2    # deploy version 相当 (20種)
  - name: attr_3    # client region 相当 (10種)
  - name: attr_4    # HTTP method 相当 (5種)
```

![Heap Memory — 最適化](./scenario-reports/high-cardinality/captures/opt/images/heap_memory.png)

組み合わせ数が 1,500,000 → 1,000 に減少した結果、300 秒間完走し、Heap は 108〜232 MB で GC による正常な鋸歯状振動を示しました。20 ポイントのメトリクスが途切れなく取得できました。pprof でも `Map.EnsureCapacity` が 113 → 29 MB に大幅縮小し、spanmetrics の cum は 270 → 88 MB（-67%）に低下しました。組み合わせ数が有界（1,000）に収まっています。

実務では `user_id`、URL パスパラメータ（`/users/{id}`）、SQL クエリ文字列（`db.statement`）が同じ罠に嵌まりやすいです。`dimensions` に追加する前にカーディナリティの掛け算を確認しておくことをお勧めします。

### 最適化の要点

| 指標 | 非最適化 | 最適化 | 変化 |
|------|---------|--------|------|
| 組み合わせ数 | 1,500,000 | 1,000 | -99.9% |
| Heap 観測値 | 312.10 MB（OOM 直前の1点） | 232.27 MB（ピーク） | — |
| RSS ピーク | 491.27 MB（limit の 96%） | 421.14 MB（82%） | -14% |
| Refused Spans | 2,676（発火するも OOM Kill） | 0 | — |
| pprof spanmetrics cum | 270 MB | 88 MB | **-67%** |
| 生存時間 | 50 秒（OOM Kill） | 300 秒（完走） | — |

> 詳細: [高カーディナリティ詳細レポート](./scenario-reports/high-cardinality/report.md)

## 6. 実践検証: Batch × Queue メモリ増幅（キュー滞留型）

ここで一つ、読者にも計算してみてください。`send_batch_size: 8192`、`queue_size: 1000`。設定値として見れば特別大きくはありません。しかし掛け算してみると話が変わります。

### 再現条件

以下の設定で Batch Processor と Sending Queue を構成しました。Jaeger を `cpus: 0.2` に制限して「バックエンドが遅い」状態を模擬し、4,000 traces/sec × 10 workers を 180 秒間投入しました。

```yaml
batch:
  send_batch_size: 8192
  timeout: 200ms

sending_queue:
  queue_size: 1000    # デフォルト値
```

### 問題の発見（Grafana 観測）

![Heap Memory — 非最適化](./scenario-reports/batch-queue/captures/non-opt/images/heap_memory.png)

Heap が 333 MB に達し、soft_limit（307 MB）を 26 MB 超過しました。memory_limiter が持続的に発火し、約 3,900 spans がドロップしました。Queue 使用率はわずか 5.3%（53/1000）にもかかわらず、この状態です。

### 掛け算の罠

なぜ Queue が 5% しか埋まっていないのに soft_limit を超えるのでしょうか。理論最大を計算してみるとわかります。

```
8,192 × 1,000 × 580 B = 4.75 GB（コンテナの 9 倍）
```

Queue がわずか数 % 埋まっただけで soft_limit を突破する構造になっています。`send_batch_size: 8192` も `queue_size: 1000`（デフォルト値）も、私たちも最初は単体で見て問題ないと判断していました。しかし掛け算すると理論最大 4.75 GB という数字が出てきます。

### pprof で原因を特定

このシナリオでは pprof の top に batch/queue 固有の関数が登場しません。メモリの 94% は pdata（スパンデータのデシリアライズ）が占めます。これは sending_queue に保持されたバッチ内のスパンデータそのものです。

「直接の確保者」（pdata 関数）と「保持の原因者」（sending_queue）が異なるため、pprof の `flat` だけを見ると原因を見落とします。Grafana の Queue Usage メトリクスと組み合わせて初めて、queue 滞留がメモリ肥大化の根本原因であることを特定できます。

最適化後の pprof では、pdata の占有率が 94% から大幅に低下し、queue に保持されるバッチデータ量の削減がそのままメモリ消費の改善に直結していることが確認できました。

### 最適化

メモリ予算から逆算して、安全な設定値を導出します。

```
queue_size × send_batch_size × span_size < soft_limit − オーバーヘッド
```

soft_limit = 307 MB、オーバーヘッド ≈ 150 MB → queue 予算 = 157 MB。この予算に収まるよう `send_batch_size: 2048`、`queue_size: 50` に変更しました。

```yaml
batch:
  send_batch_size: 2048
  timeout: 200ms

sending_queue:
  queue_size: 50
```

![Heap Memory — 最適化](./scenario-reports/batch-queue/captures/opt/images/heap_memory.png)

Heap ピークは 224 MB で soft_limit を 83 MB 下回り、Refused ゼロで完走しました。理論最大は `2,048 × 50 × 580 B = 59 MB`（コンテナの 12%）となり、Queue が **100%** に達しても安全圏内です。

設定を変更する前に、電卓でこの掛け算を一度叩いてみてください。

### 最適化の要点

| 指標 | 非最適化 | 最適化 | 変化 |
|------|---------|--------|------|
| send_batch_size × queue_size | 8,192 × 1,000 | 2,048 × 50 | — |
| 理論最大 | 4.75 GB | 59 MB | -99% |
| Heap ピーク | 333 MB | 224 MB | **-33%** |
| Refused 累計 | 3,900 spans | 0 | -100% |
| Queue 使用率 | 5.3%（53/1000） | 100%（50/50） | — |
| Queue メモリ | 252 MB | 59 MB | -77% |

> 詳細: [Batch × Queue 詳細レポート](./scenario-reports/batch-queue/report.md)

## 7. ベストプラクティス

3 つのシナリオで痛い目を見た結果、行き着いた原則が 3 つあります。

### 原則 1: 制限を先頭に

`memory_limiter` はパイプラインの **最初の processor** に配置します。[OpenTelemetry 公式ドキュメント](https://opentelemetry.io/docs/collector/configuration/#recommended-processors)でも推奨されている配置です。後段に置くと、ステートフル processor がメモリを確保した後でしか発火せず、手遅れになります。ただし高カーディナリティシナリオで見たとおり、memory_limiter は受信拒否しかできません。既にステートフルな内部状態に蓄積されたデータには無力であるため、次の原則 2 が不可欠です。

```yaml
processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 20
```

| パラメータ | 推奨値 | 根拠 |
|-----------|--------|------|
| `check_interval` | `1s` | 1秒間隔で十分。短くしすぎると CPU 消費が増える |
| `limit_percentage` | `80` | 残り 20% を GC とスパイク吸収に確保 |
| `spike_limit_percentage` | `20` | 急増時の余裕。soft_limit = `limit_percentage - spike_limit_percentage` |

### 原則 2: ステートフルを疑う

`tail_sampling`、`spanmetrics`、`groupbyattrs` を導入する際は、内部状態のカーディナリティ上限を事前に確認してください。固定閾値ではなく、以下の予算式で判断します。

```
ユニーク系列数 × 1系列あたり推定メモリ（数百B〜数KB） < コンテナメモリ予算
```

本検証環境では 1,500,000 組み合わせ × 数百 B → 302 MB に達し、512 MB コンテナで OOM Kill に至りました。CUMULATIVE temporality の場合、`UUID`、`request_id`、`session_id` のような高カーディナリティ属性は含めないようにしてください。DELTA temporality であれば TTL で回収されるケースもありますが、安全側に倒すなら除外が無難です。

Tail Sampling の場合は以下の式でメモリを見積もります。

```
メモリ ≈ decision_wait × スループット × 平均スパンサイズ × ~6（Go runtime 倍率）
```

`decision_wait` は必要最小限に設定し（推奨: 10s 以下）、`num_traces` はメモリ予算から逆算します。100% サンプリング（`always_sample`）は検証用であり、実運用では目的に応じたポリシーを使ってください。

### 原則 3: バッファを見積もる

`send_batch_size × queue_size × span_size` を計算してみてください。設定変更前にメモリ予算との突合を行い、理論最大がコンテナ制限の 60% 以下に収まることを確認します。

```yaml
processors:
  batch:
    # セクション6のメモリ予算計算に基づく値:
    # queue_size × send_batch_size × span_size < soft_limit − オーバーヘッド
    # 50 × 2048 × 580B = 59MB（コンテナの 12%）
    send_batch_size: 2048
    timeout: 200ms

exporters:
  otlp:
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 50    # デフォルト 1000 は理論最大 4.75GB に達するため削減
    retry_on_failure:
      enabled: true
```

| パラメータ | トレードオフ |
|-----------|------------|
| `send_batch_size` | 大きくするとスループット向上だがメモリ消費増 |
| `timeout` | 短くするとレイテンシ向上だがバッチ効率低下 |
| `queue_size` | 大きくすると下流障害時のバッファ増だがメモリ消費増 |
| `num_consumers` | 並列送信数。大きくすると下流への負荷増 |

下流が停止すると `queue_size` まで蓄積されるため、最悪ケースのメモリを見積もってください。

```
queue_size × send_batch_size × span_size < soft_limit − オーバーヘッド
```

### 監視アラート

```promql
# Heap 異常上昇（5分間で 50MB 以上の増加）
delta(otelcol_process_runtime_heap_alloc_bytes[5m]) > 50 * 1024 * 1024

# Refused 発生（memory_limiter 発火）
rate(otelcol_receiver_refused_spans_total[5m]) > 0

# Queue 飽和（90% 以上）
otelcol_exporter_queue_size / otelcol_exporter_queue_capacity > 0.9

# スループット低下（直近1分が5分前と比べて20%以上低下）
rate(otelcol_receiver_accepted_spans_total[1m])
  <
rate(otelcol_receiver_accepted_spans_total[5m] offset 5m) * 0.8
```

この 4 つのアラートを設定しておけば、メモリ高騰の兆候を早期に検知できます。Heap 上昇で異常を察知し、Refused で実害発生を確認し、Queue 飽和で下流障害の影響を把握し、スループット低下でパイプライン全体の劣化を検知します。

### 安全なベースライン設定

以下は本検証で使用したベースライン設定です。ステートフル processor を含まず、メモリ制約のあるコンテナ環境で安定稼働する構成です。

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
    send_batch_size: 2048    # メモリ予算から逆算（セクション6参照）
    timeout: 200ms

exporters:
  otlp:
    endpoint: backend:4317
    tls:
      insecure: true
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 50    # 理論最大 59MB（コンテナの 12%）に収まる値
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
- `sending_queue` + `retry_on_failure` でキュー制御

## 8. まとめ

ここまでの検証結果を振り返りましょう。

| シナリオ | 変更内容 | Heap 削減 | データドロップ |
|---------|---------|----------|-------------|
| Tail Sampling | `decision_wait`: 30s → 10s | -28% (Heap) / -33% (pprof) | 39.1% → ~0%（損失率） |
| 高カーディナリティ | `dimensions`: 5個→3個（組み合わせ 1.5M→1K） | -49% (pprof) | OOM → 完走 |
| Batch × Queue | batch × queue: 40 倍削減 | -33% | 3,900 → 0 spans |

振り返ってみると、いずれも「デフォルト値のまま」あるいは「なんとなく大きめに設定した」状態が原因であり、設定パラメータの意味とメモリへの影響を理解した上で調整すれば劇的に改善します。

3 つのシナリオに共通して得られた教訓をまとめます。

1. **デフォルト値は安全とは限りません。** OTel Collector のデフォルト設定はスループット優先の傾向があり、メモリ制約を考慮していません。コンテナ環境では必ずメモリ予算に合わせた調整が必要です
2. **Grafana + pprof の組み合わせが診断の基本です。** Grafana でマクロな挙動（Heap 推移、Queue 使用率、Refused 発生）を把握し、pprof でミクロな原因（どの関数がメモリを確保・保持しているか）を特定します。どちらか一方では不十分です
3. **設定変更前にメモリ予算を計算してください。** `batch_size × queue_size × span_size` や `decision_wait × 流量 × span_size` を計算し、soft_limit 以下に収まることを確認してからデプロイしてください

ここまで読んでくださった方にお勧めしたいのは、今すぐ自環境の OTel Collector 設定ファイルを開いて、この記事で紹介した掛け算を計算してみることです。もしその数字がコンテナのメモリ制限を超えていたら、この記事が役に立つはずです。pprof extension を有効にして、負荷テストで一度プロファイルを取ってみてください。問題は本番で顕在化する前に、テスト段階で見つけられます。
