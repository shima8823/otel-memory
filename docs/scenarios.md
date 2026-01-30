# OTel Collector メモリ高騰シナリオ（pprof対応版）

実務で遭遇しやすいメモリ高騰シナリオを、**再現 → 観測 → pprof 解析 → 対処**の流れで整理したガイドです。

---

## クイックリファレンス

| 番号 | シナリオ | コマンド | 主な観察ポイント |
|------|---------|---------|-----------------|
| **1** | **下流停止** | `make scenario-1` | Queue Usage 100%, Receiver Refused |
| **2** | **Processor（高カーディナリティ）** | `make scenario-2` | Heap が右肩上がり、GC後も戻らない |
| **3** | **キャパシティ不足** | `make scenario-3` | Queue 乱高下, CPU 張り付き, Refused |
| **4** | **batch バースト処理** | `make scenario-4` | テントウ虫型グラフ、スパイク時の挙動 |

---

## 事前準備

### ローカル（Docker Compose）

```
make up
```

### pprof キャプチャ（共通）

```
make pprof-capture-bg
make scenario-1
make pprof-capture-stop

# 保存先はログから取得
grep -m1 "保存先:" pprof/logs/pprof_capture.log

# ピークと直前を diff
make pprof-peak-diff DIR=pprof/01-23/captures/175921
```

詳細は `docs/pprof.md` を参照してください。

---

## シナリオ1: 下流（バックエンド）の遅延・停止

**現象**: Jaeger/Prometheus 等が遅い・停止している状態。Exporter のキューに滞留が発生しメモリが急増。

**再現手順**:
1. `make scenario-1`
2. （手動で実行する場合）`docker compose stop jaeger`

**診断シグネチャ (Grafana)**:
- **Queue Usage**: 0% → **100%** 張り付き
- **Heap Memory**: 急増 → Force GC → 高止まり
- **Receiver Refused**: `otelcol_receiver_refused_spans_total` 増加

**pprof での典型所見**:
- Exporter の `sending_queue` / retry 周辺が優勢

**対処法**:
- `sending_queue` を過剰に大きくしない
- `memory_limiter` を必ず有効化
- 長期的には Persistent Queue の検討

**詳細レポート**: `docs/scenario-reports/scenario-1.md`

---

## シナリオ2: Processor コンポーネントのメモリ高騰

`groupbyattrs` などの **ステートフル processor** は内部にマップを保持するため、
**カーディナリティの影響でメモリが膨張**します。

**再現手順**:
1. `make scenario-2` を実行し、5分観察

**診断シグネチャ**:
- Heap が右肩上がり
- GC 後も戻らない
- throughput が段階的に低下

**pprof での典型所見**:
- `groupbyattrsprocessor` のマップ構造が肥大化

**対処法**:
- 高カーディナリティ属性（ID/UUID等）を keys から除外
- `memory_limiter` をステートフル processor の**前**に配置

**詳細レポート**: `docs/scenario-reports/scenario-2.md`

---

## シナリオ3: 慢性的な入力過多（キャパシティ不足）

**現象**: Collector の処理能力を超える入力が恒常的に流入。

**再現手順**:
1. `make scenario-3`

**診断シグネチャ (Grafana)**:
- **Queue Usage**: 100% ではなく **高位で乱高下**
- **CPU Usage**: 常に高い
- **Receiver Refused**: 恒常的に発生

**pprof での典型所見**:
- バッチ処理・エンコード周辺の CPU が目立つ

**対処法**:
- Collector の水平スケール
- サンプリング / 属性削除で入力量を削減

---

## シナリオ4: batch プロセッサの不適切な設定

**現象**: スパイク時にメモリ急増、復帰が遅い。スパイクが連続すると高止まり。

**再現手順**:
1. `make scenario-4`

**診断シグネチャ**:
- **Heap Memory**: テントウ虫型（スパイク→遅い復帰）
- **Receiver Refused**: スパイク時に発生
- **Queue Usage**: スパイク時に急増

**pprof での典型所見**:
- Batch での滞留が支配的

**対処法**:
- `send_batch_size` を適正化
- `timeout` を短く
- `queue_size` を適度に抑える

**詳細レポート**: `docs/scenario-reports/scenario-4.md`

---

## 診断フローチャート

```
メモリ高騰を検知
       │
       ▼
┌────────────────────────┐
│ メモリの変化パターンは？│
└────────────────────────┘
       │
       ├─── テントウ虫型（周期的上下動） ──▶ batch 設定問題 (シナリオ4)
       │
       ├─── 右肩上がり（GC後も戻らない）──▶ Processor 高カーディナリティ (シナリオ2b)
       │
       └─── 急増→高止まり ──▶ Queue Usage は？
                              ├── 100% 張り付き → 下流停止 (シナリオ1)
                              └── 70-90% 乱高下 → キャパ過多 (シナリオ3)
```

---

## 関連ドキュメント

- `docs/pprof.md`
- `docs/scenario-reports/`
- `otel-collector/scenarios/*.yaml`
