# Plan: 高カーディナリティシナリオを Prometheus scrape 方式に変更

## 実施済み（2026-02-19）

旧方式（Python OTel SDK の OTLP push）で pyloadgen が OOM する問題を根本的に解決した。

### 変更内容

1. **`pyloadgen/high_cardinality_prom_server.py` を新規作成**
   - Python stdlib のみ使用（外部依存なし）
   - stateless な Prometheus メトリクス HTTP サーバ
   - 毎 scrape で uuid ベースのユニークラベルを生成

2. **`otel-collector/scenarios/scenario-high-cardinality-metrics.yaml` を書き換え**
   - OTLP receiver → prometheus receiver（2s scrape interval）
   - prometheus exporter に `metric_expiration: 0s` で時系列永久保持

3. **`Makefile` / `terraform/Makefile` を更新**
   - loadgen の IP を動的取得して Collector 設定に反映
   - pyloadgen OTel SDK の pip install が不要に

4. **`pyloadgen/high_cardinality_metrics.py` を削除**
   - OTLP push 方式は廃止

### 旧方式の問題

Python OTel SDK の cumulative temporality が全ユニーク時系列を SDK 内部に永久保持。
1500 rps × 240s = 360,000 ユニーク系列 ≈ 1.4GB → loadgen VM (e2-small, 2GB) で OOM。

### 新方式の利点

- loadgen は完全に stateless（OOM しない）
- Collector 側の prometheus exporter がメモリ消費の主犯（意図通り）
- 実務で最も一般的な高カーディナリティパターン（Prometheus エコシステム全般の問題）を再現
