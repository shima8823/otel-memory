# ハイカーディナリティメトリクス シナリオ状態ファイル

## 1. シナリオ概要

- **ターゲット**: `make run-high-cardinality-metrics`
- **負荷ツール**: `pyloadgen/high_cardinality_prom_server.py`（Python stdlib, stateless HTTP サーバ）
- **Collector 設定**: `otel-collector/scenarios/scenario-high-cardinality-metrics.yaml`
- **方式**: Prometheus scrape（Collector が loadgen の /metrics を scrape）
- **目的**: prometheus exporter の高カーディナリティ時系列蓄積によるメモリ高騰 → memory_limiter 発火 → データドロップ

## 2. アーキテクチャ

```
[Loadgen VM]                              [Collector VM]
  high_cardinality_prom_server.py           otel-collector:
    HTTP :9091 /metrics                       prometheus receiver (scrape 2s)
    (stateless: 毎回テキスト生成)                ↓
                                             memory_limiter, batch
                                                ↓
                                             prometheus exporter (時系列蓄積 → OOM)
```

## 3. 実行結果（2026-02-19）

- **結果**: 成功（シナリオ完全再現）
- **キャプチャ**: `captures/02-19/184727/`
- **docs 保存先**: `docs/blog/scenario-reports/high-cardinality-metrics/`

### メモリ推移

| 指標 | 初期値 | ピーク | 状態 |
|------|--------|--------|------|
| Heap Alloc | 21 MB | **432 MB** | 急騰→memory_limiter で抑制 |
| Total Alloc (cumulative) | - | **3.31 GiB** | 右肩上がり（prometheus exporter 累積） |
| RSS | 173 MB | **614 MB** | 急騰→飽和（512M limit超） |

### データドロップ

| 指標 | 初期値 | ピーク | 状態 |
|------|--------|--------|------|
| Accepted Metrics Rate | 5,144/s | → **0/s** (18:49:34以降) | 完全受信停止 |
| Refused Metrics Rate | 0/s | → **10,184/s** | memory_limiter 発火 |
| Drop Rate | 0% | → **100%** | 全データドロップ |

### タイムライン

1. **18:47:34** - scrape 開始、Heap 22 MB
2. **18:48:04** - Heap 225 MB に急騰、Accepted 2,913/s
3. **18:48:19** - **Refused 発生開始** (800/s)、Accepted はまだ 4,331/s
4. **18:48:34** - Heap 364 MB、Refused 2,624/s に増加
5. **18:49:04** - Heap 432 MB（ピーク）、Refused 7,998/s
6. **18:49:34** - **Accepted 0/s、Refused 10,184/s** — 全データドロップ状態
7. **18:51:49** - シナリオ終了まで 100% ドロップ継続

### 所見

- loadgen は 240s **完走**（OOM なし）— Prometheus scrape 方式の狙い通り
- memory_limiter 発火 → data refused → **データドロップ** のシナリオが完全に再現
- **約 90 秒で 0% → 100% ドロップ** に到達（高カーディナリティの危険性を示す）
- Heap は memory_limiter により 432 MB で頭打ちだが、Total Alloc は 3.3 GiB まで累積
- RSS は docker memory limit (512M) を超えて 614 MB — OOM Kill のリスクも示唆

## 4. Grafana スクリーンショット

| 画像 | 説明 |
|------|------|
| `images/heap_memory.png` | Heap Alloc（頭打ち）と Total Alloc（右肩上がり）の対比 |
| `images/rss_memory.png` | RSS の急騰→飽和パターン |
| `images/receiver_metrics.png` | Accepted と Refused の「X字パターン」— データドロップの典型シグネチャ |
| `images/receiver_drop_rate.png` | 0% → 100% のドロップレート推移 |

## 5. pprof データ

| ファイル | 説明 |
|---------|------|
| `heap_baseline.pprof` | シナリオ開始直後のベースライン |
| `heap_peak.pprof` | メモリピーク時のプロファイル |

## 6. 旧方式からの変更点

| 項目 | 旧方式 (OTLP push) | 新方式 (Prometheus scrape) |
|------|--------------------|-----------------------|
| 負荷ツール | Python OTel SDK (high_cardinality_metrics.py) | Python stdlib HTTP server (high_cardinality_prom_server.py) |
| データ送信 | OTLP gRPC push | Collector が HTTP scrape |
| loadgen メモリ | SDK が cumulative 時系列を蓄積 → OOM | stateless → 数十MB |
| Collector 設定 | OTLP receiver | prometheus receiver |
| 実務との類似性 | 低い | 高い（Prometheus エコシステム全般の問題） |
| **シナリオ成否** | **失敗（loadgen OOM）** | **成功（完全再現）** |

## 7. 関連ファイル一覧

| ファイル | 説明 |
|---------|------|
| `pyloadgen/high_cardinality_prom_server.py` | stateless Prometheus メトリクス HTTP サーバ |
| `otel-collector/scenarios/scenario-high-cardinality-metrics.yaml` | prometheus receiver + exporter の Collector 設定 |
| `Makefile` | scenario-high-cardinality-metrics ターゲット |
| `terraform/Makefile` | GCP 環境での scenario-high-cardinality-metrics ターゲット |
| `terraform/network.tf` | GCP firewall ルール（port 9091 追加） |
