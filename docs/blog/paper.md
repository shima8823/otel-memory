# OpenTelemetry Collector のメモリ高騰を Grafana と pprof でデバッグする

## はじめに

OpenTelemetry Collector は Receiver・Processor・Exporter を組み合わせてパイプラインを構成できる柔軟なコンポーネントです。しかし、Processor の設定パラメータがメモリ使用量にどう影響するかは、設定ファイルからは読み取りにくいものです。問題が表面化するのは負荷が上がったときで、そのときにはデータの欠損が始まっています。

原因を特定しないままコンテナのメモリを増やしても、負荷が増えれば再発します。必要なのは、メモリを圧迫している箇所を特定し、設定パラメータを根拠を持って調整することです。

本記事では、Tail Sampling Processor を題材に、Grafana の内部メトリクスと pprof の heap profile を使ってメモリ高騰の原因を特定し、パラメータ変更で改善するまでの過程を追います。

検証環境は OpenTelemetry Collector Contrib v0.140.1、コンテナメモリ制限 512 MB です。バージョンによりデフォルト値やメトリクス名が異なる場合があります。

## デバッグの基本技法と環境準備

メモリが増えていることはコンテナの RSS や OOM Kill で気付けます。しかし「何がメモリを使っているのか」を特定するには、Collector が公開している診断情報を使う必要があります。本記事で使用する診断手段は、内部メトリクス、pprof、memory_limiter の 3 つです。

### 内部メトリクス

OTel Collector は自身の動作状況を Prometheus メトリクスとして公開しています。Grafana で可視化すると、メモリ使用量の推移やデータの受信状況をリアルタイムに確認できます。

本記事で主に参照するメトリクスは以下の 3 つです。

| メトリクス | 何がわかるか |
|-----------|------------|
| `otelcol_process_runtime_heap_alloc_bytes` | Go ランタイムの Heap 使用量。GC 後も下がらなければ、解放されないデータがメモリ上に残っている |
| `otelcol_receiver_refused_spans_total` | `memory_limiter` がメモリ超過を理由に受信を拒否したスパン数 |
| `otelcol_exporter_queue_size` | Exporter の送信キュー内のバッチ数。下流が遅延すると増加する |

メトリクス名や取得方法の詳細は [公式ドキュメント（Internal Telemetry）](https://opentelemetry.io/docs/collector/internal-telemetry/) を参照してください。

### pprof

メトリクスで「Heap が増えている」ことがわかっても、「どの関数がメモリを確保しているか」まではわかりません。pprof は Go 標準のプロファイリング機能で、heap profile を取得すると、関数ごとのメモリ使用量の内訳を確認できます。

OTel Collector では [pprof extension](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension/pprofextension) を有効にすると、HTTP endpoint 経由で heap profile を取得できます。

```yaml
extensions:
  pprof:
    endpoint: 0.0.0.0:1777

service:
  extensions: [pprof]
```

```bash
# heap profile の取得と対話的な解析
go tool pprof http://localhost:1777/debug/pprof/heap
```

pprof の出力には **flat** と **cum** という 2 つの指標があります。

- **flat**: その関数自身が直接確保したメモリ量
- **cum**（cumulative）: その関数と、そこから呼び出される関数を含めた累積のメモリ使用量

メモリ高騰の原因を追うときは flat だけでなく cum を確認することが重要です。flat が小さくても cum が大きい関数は、呼び出し先を含めた経路全体でメモリを保持しています。この区別は実践検証セクションで繰り返し使います。

### memory_limiter

シナリオに入る前に、もう 1 つ押さえておくべき仕組みがあります。

`memory_limiter` は Collector のメモリ使用量を監視し、閾値を超えると新規データの受信を拒否する processor です。[公式の Recommended Processors](https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor#recommended-processors) の 1 番目に挙げられており、パイプラインの先頭に配置します。

本記事の検証環境では以下の設定を使用しています。

```yaml
memory_limiter:
  check_interval: 1s
  limit_percentage: 80
  spike_limit_percentage: 30
```

受信拒否が始まる実効閾値（soft_limit）は `コンテナメモリ × (limit_percentage - spike_limit_percentage)` で計算されます。本環境では `512 MB × (80% - 30%) = 256 MB` です。Heap がこの値に達すると、Receiver が新規スパンの受信を拒否し始めます。

### 再現環境

本記事のデータは Google Cloud 上で取得しました。Loadgen VM と Collector VM の 2 インスタンス構成で、負荷生成と Collector を分離しています。

ローカルでの再現は以下の手順で可能です。

```bash
git clone <リポジトリ URL>
docker compose up -d    # Collector, Prometheus, Grafana
```

pprof extension は Collector 設定で有効化済みです。Grafana は `http://localhost:3000` でアクセスできます。

### 診断フロー

本記事では以下のフローに沿って検証を進めます。

```
メトリクスで異常を検知 → pprof で原因を特定 → パラメータを変更 → 再テストで改善を確認
```

次章では、Tail Sampling Processor を対象にこのフローを実践します。

## 実践検証: Tail Sampling

<!-- TODO: データ取得後に記述 -->

## まとめ

<!-- TODO: データ取得後に記述 -->
