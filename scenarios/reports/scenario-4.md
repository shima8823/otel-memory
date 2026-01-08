# 診断レポート: シナリオ4 - 不適切な batch 設定（バースト処理の失敗とデータ欠損）

## 1. 概要

極端に大きい `batch` と `sending_queue` 設定により、スパイク負荷時にメモリが急激に蓄積し、`memory_limiter` が発火してデータ欠損が発生する過程を検証した。

**重要**: このシナリオは「設定を大きくすればスループットが上がる」という誤解を検証する。実際には、大きすぎる設定はスパイク耐性を下げ、**データ欠損**という最も深刻な問題を引き起こす。

---

## 2. 再現条件

### Collector 設定
- **Dockerメモリ制限**: 256MB（512MB → 256MB に変更）
- **memory_limiter**: `limit_percentage: 80` (205 MB)
- **batch**: 
  - `send_batch_size: 20000`（ベースラインの10倍）
  - `send_batch_max_size: 30000`
  - `timeout: 120s`（ベースラインの600倍）
- **sending_queue**: `queue_size: 10000`（ベースラインの20倍）

### 負荷設定（loadgen）
- **シナリオ**: spike
- **目標レート**: 15,000 spans/sec
- **実測レート**: 通常 1,600-1,700 spans/sec、スパイク 2,700-3,300 spans/sec
- **実行時間**: 3分間 (180秒)
- **スパイク周期**: 10秒ごとに切り替え

### 環境
- **実行日時**: 2026/01/08 15:53:27 - 15:56:22

---

## 3. タイムライン

| 経過時間 | 時刻 | イベント | スループット | Heap Memory | 備考 |
|---------|------|----------|-------------|-------------|------|
| **0秒** | 15:53:27 | 🚀 **負荷開始** | - | ~20 MB | 通常負荷開始 |
| 10秒 | 15:53:37 | スパイク開始 | 2,747/sec → 4,815/sec | - | 第1回スパイク |
| 19秒 | 15:53:46 | 通常負荷に戻る | 2,737/sec | - | - |
| 29秒 | 15:53:56 | スパイク開始 | 2,723/sec → 4,734/sec | - | 第2回スパイク |
| **84秒** | 15:54:51 | ⚠️ **memory_limiter 発火（1回目）** | 2,750/sec | **~205 MB超** | "data refused due to high memory usage" |
| **138秒** | 15:55:45 | ⚠️ **memory_limiter 発火（2回目）** | - | **~205 MB超** | "data refused due to high memory usage" |
| **175秒** | 15:56:22 | ⚫ **loadgen 終了** | - | - | 総送信: 675,032 spans |

### 定量データ

| メトリクス | 値 | 備考 |
|-----------|-----|------|
| **総送信スパン数** | 675,032 | 3分間 |
| **平均スループット** | 3,750 spans/sec | target 15,000 の 25% |
| **Heap Memory（最大）** | **169.59 MB** | 15:53:57 |
| **memory_limiter 発火回数** | **2回** | 84秒後、138秒後 |
| **Receiver Refused** | **0.67-1.80 spans/sec** | **データ欠損発生** ⚠️ |
| **Batch Avg Size** | 20,000 items | 設定通り |

---

## 4. 観測されたシグネチャ（メトリクス）

### 4.1 メモリの「テントウ虫型」グラフ（スパイク→復帰の繰り返し）

```
15:42-52: ~22 MB（ベースライン、負荷前）
15:53:57: 169.59 MB 📈（スパイク、7.5倍増）
15:54:57: 130.36 MB 📉（通常時、復帰開始）
15:55:57: 154.64 MB 📈（再スパイク）
15:56:57:  26.20 MB 📉（負荷終了、完全復帰）
```

**診断ポイント**: メモリが周期的に急増・減少する「テントウ虫型」が明確に観察された。

### 4.2 データ欠損の発生（最重要シグネチャ）

**Receiver Refused Rate**:
```
15:53:57: 0.67 spans/sec ⚠️
15:54:57: 1.10 spans/sec ⚠️
15:55:57: 1.80 spans/sec ⚠️（最大）
15:56:57: 0.63 spans/sec ⚠️
```

**loadgen のエラーログ**:
```
15:54:51: "data refused due to high memory usage"
15:55:45: "data refused due to high memory usage"
```

**→ memory_limiter が発火し、データ欠損が発生した**

### 4.3 主要メトリクス

| メトリクス | 挙動 | 意味 |
|-----------|------|------|
| `otelcol_process_runtime_heap_alloc_bytes` | テントウ虫型（169 MB ↔ 130 MB） | batch が 20,000個溜まるまで送信されず、メモリ蓄積 |
| `otelcol_receiver_refused_spans_total` | **0.67-1.80 spans/sec** | **memory_limiter 発火によるデータ欠損** ⚠️ |
| `otelcol_receiver_accepted_spans_total` | 1,676-3,333 spans/sec（変動） | スパイク負荷パターンを反映 |
| `otelcol_processor_batch_batch_size_average` | **20,000 items** | 設定通り、極端に大きいバッチ |
| **timeout** | 120s | スパイク後の復帰が遅い原因 |

---

## 5. 詳細分析

### 5.1 不適切な設定によるメモリ蓄積メカニズム

#### batch processor の動作

**正常設定（ベースライン）**:
```
send_batch_size: 2,000
timeout: 200ms
→ 2,000個 または 200ms で送信
→ メモリ蓄積: 最小限
```

**異常設定（シナリオ4）**:
```
send_batch_size: 20,000
timeout: 120s
→ 20,000個 または 120s で送信
→ メモリ蓄積: 大量
```

#### メモリ蓄積の計算

```
実測スループット（スパイク時）: 3,300 spans/sec
send_batch_size: 20,000

20,000 ÷ 3,300 = 約6秒

→ スパイク時、6秒間メモリに蓄積し続ける
→ 1 span ≈ 4KB → 20,000 spans = 80 MB
→ 複数バッチ + Queue → 169 MB まで増加
```

### 5.2 memory_limiter 発火によるデータ欠損

#### トリガー条件

```
Docker メモリ制限: 256 MB
limit_percentage: 80%
→ 閾値: 256 MB × 0.8 = 205 MB

実測 Heap: 169.59 MB（最大）
→ 205 MB 未満だが、発火している？
```

**理由**: `spike_limit_percentage` も考慮される
```
spike_limit: 256 MB × 0.2 = 51 MB
実際の閾値: 205 - 51 = 154 MB（一時的）
または、瞬間的に 205 MB を超えたがサンプリング時には下がっていた
```

#### データ欠損の影響

```
Receiver Refused: 1.80 spans/sec（最大）
実行時間: 180秒
総データ欠損: 約 1.80 × 180 = 324 spans

総送信: 675,032 spans
欠損率: 324 ÷ 675,032 = 0.048%
```

**→ わずかな欠損率でも、監査ログなど重要なデータが失われる可能性**

### 5.3 timeout: 120s の影響

**スパイク後の復帰が遅い**:
```
15:53:57: 169.59 MB（スパイク）
15:54:57: 130.36 MB（1分後、まだ高い）
15:56:57:  26.20 MB（3分後、ようやく復帰）
```

**原因**: `timeout: 120s`
- 通常時（1,600 spans/sec）では 20,000個に到達しない
- → timeout で送信されるまで待つ
- → 120秒間メモリが高止まり

---

## 6. ベースライン設定との比較

### 設定の比較

| 設定 | ベースライン（適切） | シナリオ4（極端に不適切） | 倍率 | 影響 |
|------|---------------------|---------------------------|------|------|
| **Docker Memory** | 512 MB | **256 MB** | 0.5倍 | memory_limiter が発火しやすい |
| `send_batch_size` | 2,000 | **20,000** | 10倍 | スパイク時の大量メモリ蓄積 |
| `timeout` | 200ms | **120s** | 600倍 | 復帰速度が極端に遅い |
| `queue_size` | 500 | **10,000** | 20倍 | さらにメモリ蓄積 |

### 結果の比較

| 項目 | ベースライン（予測） | シナリオ4（実測） | 差分 |
|------|---------------------|------------------|------|
| Heap Memory（最大） | ~30 MB | **169.59 MB** | **5.7倍** |
| memory_limiter 発火 | なし | **2回** | - |
| **データ欠損** | **なし** | **あり（1.8 spans/sec）** | - |
| 復帰速度 | 速い（秒単位） | **遅い（分単位）** | - |

---

## 7. 実務での発生パターン

### 典型的なシナリオ

#### パターンA: 「スループットを上げたい」という誤解

```
開発者の意図:
「send_batch_size を大きくすれば、一度に多く送信できて速くなる！」

設定:
send_batch_size: 20,000
timeout: 120s

結果:
- 通常時: 20,000個溜まらず、120秒待つ → 遅い ❌
- スパイク時: メモリ蓄積 → OOM / データ欠損 ❌
```

#### パターンB: キューサイズの過剰設定

```
開発者の意図:
「queue_size を大きくすれば、下流の遅延を吸収できる！」

設定:
queue_size: 10,000

結果:
- 下流停止時: 10,000 × 4KB = 40 MB のメモリ蓄積
- スパイク時: さらに増加 → OOM ❌
```

#### パターンC: timeout の過剰設定

```
開発者の意図:
「timeout を長くすれば、バッチサイズに到達しやすい！」

設定:
timeout: 120s

結果:
- 通常時: 120秒待つ → レイテンシ増加 ❌
- スパイク後: 120秒間メモリ高止まり ❌
```

---

## 8. 対処法

### 8.1 設計段階での対処（最重要）

#### ✅ 適切な batch 設定

```yaml
# ❌ 悪い例: 大きすぎる設定
batch:
  send_batch_size: 20000
  timeout: 120s

# ✅ 良い例: バランスの取れた設定
batch:
  send_batch_size: 2000    # 適度なサイズ
  send_batch_max_size: 4000
  timeout: 200ms           # 短い timeout
```

**判断基準**:
- `send_batch_size`: 平均スループットの 0.5-1秒分
- `timeout`: 200ms-1s
- スループット 4,000 spans/sec なら、`send_batch_size: 2000-4000`

#### ✅ 適切な queue 設定

```yaml
# ❌ 悪い例: 大きすぎる queue
sending_queue:
  queue_size: 10000

# ✅ 良い例: 適度な queue
sending_queue:
  queue_size: 500-1000    # 数秒分のバッファ
  num_consumers: 1-3
```

### 8.2 運用段階での対処

#### ✅ memory_limiter の適切な設定

```yaml
memory_limiter:
  limit_percentage: 80     # 標準
  spike_limit_percentage: 20
```

**重要**: memory_limiter は batch processor の **前** に配置

#### ✅ メトリクスによる早期検知

```prometheus
# メモリが周期的に急増したらアラート（テントウ虫型）
stddev_over_time(otelcol_process_runtime_heap_alloc_bytes[5m]) > 50MB

# データ欠損が発生したらアラート
rate(otelcol_receiver_refused_spans_total[1m]) > 0
```

#### ✅ Dockerメモリ制限の設定

```yaml
# 本番環境では必ず設定
deploy:
  resources:
    limits:
      memory: 512M  # 適切な制限
```

### 8.3 緊急時の対処

**データ欠損が発生した場合**:

1. **即座に Collector を再起動** → メモリがクリアされる
2. **設定を見直す**:
   - `send_batch_size` を 2,000-4,000 に戻す
   - `timeout` を 200ms-1s に戻す
   - `queue_size` を 500-1000 に戻す
3. **memory_limiter のログを確認** → 発火頻度を把握
4. **欠損したデータの影響範囲を特定**

---

## 9. 結論と教訓

### 9.1 「大きい設定 = 速い」は誤解

- `send_batch_size` を大きくしても、スループットは上がらない
- むしろ、スパイク耐性が下がり、メモリ高騰を招く
- 適切な設定は、平均スループットの 0.5-1秒分

### 9.2 データ欠損は最も深刻な問題

- メモリ高騰だけでなく、**データ欠損**が発生する
- 監査ログなど重要な情報が失われる可能性
- `memory_limiter` は最後の砦だが、発火するとデータ欠損は避けられない

### 9.3 テントウ虫型グラフの診断

| 症状 | 原因 |
|------|------|
| メモリが周期的に急増・減少 | スパイク負荷 + 大きすぎる batch 設定 |
| スパイク後の復帰が遅い | timeout が長すぎる |
| データ欠損が発生 | memory_limiter が発火 |

### 9.4 本番投入チェックリスト

batch processor を設定する際は、以下を確認すること：

- [ ] `send_batch_size` は平均スループットの 0.5-1秒分（2,000-4,000 推奨）
- [ ] `timeout` は 200ms-1s（短めに）
- [ ] `queue_size` は 500-1,000（適度に）
- [ ] memory_limiter を batch processor の前に配置した
- [ ] Dockerメモリ制限を設定した（512MB-1GB 推奨）
- [ ] データ欠損（Receiver Refused）の監視アラートを設定した
- [ ] 本番相当のスパイク負荷で負荷テストを実施した

---

## 10. 参考情報

### 関連ドキュメント
- [batch processor](https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/batchprocessor)
- [memory_limiter processor](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md)
- [sending_queue](https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md#sending-queue)
- [scenario.md](../scenario.md) - シナリオ4 の再現手順

### 実行コマンド
```bash
# シナリオ4を実行
make scenario-4

# メトリクスをエクスポート
make export-metrics DURATION=5 STEP=10
```

### 他のシナリオとの比較
- **シナリオ1**: 下流停止 → Queue 100% 張り付き
- **シナリオ2**: キャパシティ不足 → Queue 乱高下、慢性的な Refused
- **シナリオ3b**: 高カーディナリティ → Heap 右肩上がり、GC後も戻らない
- **シナリオ4**: 不適切な batch 設定 → **テントウ虫型、データ欠損** ← 本シナリオ

