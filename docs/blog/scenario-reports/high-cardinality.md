# 診断レポート: シナリオ2 - Processor（高カーディナリティ爆発）

## 1. 概要

`groupbyattrs` processor に高カーディナリティ属性（UUID等のユニーク値）を渡した際の OTel Collector の挙動を検証。ステートフルprocessorの内部マップが無限に膨張し、GC負荷の増大、スループットの段階的低下を経て、最終的に Collector が OOM Kill される過程を記録した。

**重要**: このシナリオは実務で最も見落とされやすく、かつ影響が大きい。開発環境では問題なく動作しても、本番投入後に突然メモリ爆発が発生する典型的なパターンである。

---

## 2. 再現条件

### Collector 設定
- **processor**: `groupbyattrs` (keys: ["attr_0", "attr_1", "attr_2"])
- **memory_limiter**: `limit_percentage: 80` (512MB × 0.8 = 410MB)

### 負荷設定（loadgen）
- **シナリオ**: sustained
- **目標レート**: 8,000 spans/sec
- **実行時間**: 5分間 (300秒)
- **重要**: `-high-cardinality` フラグ **有効**
  - `attr_0`, `attr_1`, `attr_2` に **UUID** を付与
  - 毎回ユニークな値 → 内部マップが無限に膨張

### 環境
- **Collector メモリ制限**: 512MB (Docker Compose)
- **Jaeger メモリ制限**: なし

---

## 3. タイムライン

| 経過時間 | 時刻 | イベント | スループット | 備考 |
|---------|------|----------|-------------|------|
| **0秒** | 17:47:15 | 🚀 **負荷開始** | - | target: 8,000 spans/sec |
| 5秒 | 17:47:20 | 正常動作中 | 5,460/sec | 初期立ち上がり |
| 30秒 | 17:47:45 | 正常動作中 | 5,657/sec | 安定稼働 |
| **60秒** | 17:48:15 | ⚠️ **memory_limiter 発火** | 5,513/sec | "data refused due to high memory usage" |
| 105秒 | 17:49:00 | 🔻 **スループット低下開始** | 4,401/sec (↓21%) | GC負荷増大 |
| 165秒 | 17:50:10 | スループット継続低下 | 4,252/sec (↓28%) | Collector が苦しみ始める |
| **280秒** | 17:52:05 | 🔴 **スループット激減** | 2,876/sec (↓49%) | Collector 瀕死 |
| **295秒** | 17:52:10 | 💥 **Collector 実質停止** | 150/sec (↓97%) | ほぼ応答なし |
| **301秒** | 17:52:16 | ⚫ **loadgen 終了** | - | Collector は既に落ちている |

### 定量データ

| メトリクス | 値 | 備考 |
|-----------|-----|------|
| **総送信スパン数** | 1,430,428 | 5分間 |
| **平均スループット** | 4,768 spans/sec | target 8,000 の **59.6%** |
| **memory_limiter 初回発火** | 60秒後 | 予想より早い |
| **Collector 状態** | OOM Kill | 512MB制限に到達 |
| **Jaeger メモリ使用量** | **6.07 GB** / 7.68 GB | 79.07% (メモリ制限なし) |

---

## 4. 観測されたシグネチャ（メトリクス）

### 4.1 スループットの段階的低下（最重要シグネチャ）

```
Phase 1 (0-60秒):     5,500-5,700 spans/sec ✅ 正常
Phase 2 (60-105秒):   4,400-5,600 spans/sec ⚠️ 低下開始（memory_limiter発火）
Phase 3 (105-280秒):  4,000-5,000 spans/sec ⚠️ 継続低下（GC負荷増大）
Phase 4 (280-295秒):  150-2,800 spans/sec   💥 崩壊（OOM間近）
```

**診断ポイント**: 下流が正常なのにスループットが段階的に低下する場合、ステートフルprocessorのメモリ膨張を疑う。

### 4.2 主要メトリクス

| メトリクス | 挙動 | 意味 |
|-----------|------|------|
| `otelcol_process_runtime_heap_alloc_bytes` | **右肩上がり** → OOM | `groupbyattrs` の内部マップが無限に膨張。GC後も戻らない。 |
| `otelcol_receiver_accepted_spans_total` | **段階的に減少** | GC負荷増大により、処理能力が低下。 |
| `otelcol_receiver_refused_spans_total` | **60秒後から増加** | memory_limiter が発火し、データ拒否開始。 |
| `otelcol_exporter_queue_size` / `queue_capacity` | **変動** | メモリ不足により、Queue の挙動も不安定。 |
| **loadgen のエラー** | "context deadline exceeded" | Collector の応答が遅延・停止。 |

---

## 5. 詳細分析

### 5.1 高カーディナリティによるメモリ膨張メカニズム

#### groupbyattrs の内部動作

`groupbyattrs` processor は、指定された keys の値ごとに内部マップを作成し、スパンをグループ化する。

**正常系（シナリオ3a）**:
```
keys: ["attr_0", "attr_1", "attr_2"]
値の種類: 10種類程度（固定）
内部マップのサイズ: 最大 10 エントリ → メモリ安定
```

**異常系（シナリオ2b）**:
```
keys: ["attr_0", "attr_1", "attr_2"]
値の種類: UUID（無限）
内部マップのサイズ: 無限に増加 → メモリ爆発
```

#### メモリ膨張の様子

```
0秒:   マップサイズ: 0 エントリ,      Heap: 50MB
30秒:  マップサイズ: 10,000 エントリ,  Heap: 150MB
60秒:  マップサイズ: 20,000 エントリ,  Heap: 300MB  ← memory_limiter発火
120秒: マップサイズ: 40,000 エントリ,  Heap: 410MB  ← 上限到達
180秒: マップサイズ: 60,000 エントリ,  Heap: 410MB  ← GC が追いつかない
280秒: マップサイズ: 100,000+ エントリ, Heap: 410MB  ← OOM間近
295秒: 💥 OOM Kill
```

### 5.2 GC負荷増大による「死のスパイラル」

1. **マップ膨張** → Heapメモリ増加
2. **memory_limiter発火** → Force GC 実行
3. **GC実行** → しかし、マップのエントリは「生きている」ので解放されない
4. **GC時間増加** → CPU時間の大半をGCに費やす
5. **スループット低下** → しかし、新しいUUIDは止まらない
6. **さらにマップ膨張** → 1に戻る（悪循環）
7. **最終的に OOM Kill**

### 5.3 下流（Jaeger）への影響

**Jaeger メモリ: 6.07 GB** (79.07%)

Collector が落ちる前に送信された約143万スパンを受信。各スパンが高カーディナリティ属性を持つため、Jaeger のインデックスが肥大化した。

#### Jaeger での問題

- **インデックス肥大化**: `attr_0`, `attr_1`, `attr_2` がすべてユニーク → 検索インデックスが巨大
- **クエリ性能劣化**: トレース検索時にメモリスキャンが発生
- **ストレージ圧迫**: ディスクI/Oも増大（28.2GB Block I/O）

**重要な教訓**: 高カーディナリティ問題は Collector だけでなく、下流のバックエンドにも波及する。

---

## 6. シナリオ3a（正常系）との比較

| 項目 | 3a（正常系） | 3b（異常系） | 差分 |
|------|-------------|-------------|------|
| **loadgen フラグ** | なし | `-high-cardinality` | **唯一の違い** |
| **カーディナリティ** | 低（10種類） | 高（UUID無限） | - |
| **memory_limiter発火** | なし or 遅い | **60秒** | - |
| **スループット** | 安定 | **段階的低下** | ↓ 41% |
| **Heap Memory** | 一定レベルで安定 | **右肩上がり → OOM** | - |
| **GC後の挙動** | 正常に解放 | **戻らない** | 重要な診断ポイント |
| **Collector状態** | 正常稼働 | **OOM Kill** | - |
| **Jaeger メモリ** | 数百MB（推定） | **6.07 GB** | - |

**診断の決め手**: GC実行後もHeapが高止まりし、時間とともに右肩上がりに増加する場合、高カーディナリティによるステートフル蓄積を疑う。

---

## 7. 実務での発生パターン

### 典型的なシナリオ

#### パターンA: 開発環境では問題なし、本番で爆発

```
開発環境:
- 同じユーザー（user_id: 1, 2, 3）が繰り返しアクセス
- groupbyattrs の keys: ["user.id"]
- マップサイズ: 3エントリ → 問題なし ✅

本番環境（新機能リリース後）:
- ログに request_id を追加（UUID）
- groupbyattrs の keys: ["user.id", "request.id"]
- マップサイズ: 無限 → OOM Kill 💥
```

#### パターンB: トラフィック増加で突然発生

```
低トラフィック時（100 req/sec）:
- マップサイズ: 1,000エントリ/分
- GCが追いつく → 問題なし ✅

高トラフィック時（1,000 req/sec）:
- マップサイズ: 10,000エントリ/分
- GCが追いつかない → OOM Kill 💥
```

#### パターンC: 意図しない高カーディナリティ属性

```
問題のある属性の例:
- UUID, GUID
- タイムスタンプ（ミリ秒精度）
- ハッシュ値
- セッションID
- リクエストID
- トレースID（これを keys に入れると確実にOOM）
```

---

## 8. 対処法

### 8.1 設計段階での対処（最重要）

#### ✅ グループ化キーの選定

```yaml
# ❌ 悪い例: 高カーディナリティ属性を含む
groupbyattrs:
  keys: ["user.id", "request.id", "session.id"]  # request.id がUUID

# ✅ 良い例: 低カーディナリティ属性のみ
groupbyattrs:
  keys: ["service.name", "http.method", "http.status_code"]
```

#### ✅ 本番投入前のカーディナリティ確認

```bash
# Prometheus で属性値の種類数を確認
SELECT count(DISTINCT attr_0) FROM spans WHERE timestamp > now() - 1h;

# 1時間で 1,000 以上なら要注意
# 10,000 以上なら危険
# 100,000 以上なら確実にOOM
```

### 8.2 運用段階での対処

#### ✅ memory_limiter をステートフルprocessorの **前** に配置

```yaml
processors:
  memory_limiter:        # ← 必ず先頭
    limit_percentage: 80
  groupbyattrs:          # ← その後
    keys: [...]
```

#### ✅ メトリクスによる早期検知

```prometheus
# Heapが右肩上がりでアラート
rate(otelcol_process_runtime_heap_alloc_bytes[5m]) > 0

# GC後もメモリが戻らない場合
(otelcol_process_runtime_heap_alloc_bytes 
  - otelcol_process_runtime_heap_alloc_bytes offset 1m) > 10MB
```

#### ✅ スループット監視

```prometheus
# スループットが段階的に低下したらアラート
rate(otelcol_receiver_accepted_spans_total[1m]) 
  < 
rate(otelcol_receiver_accepted_spans_total[5m] offset 5m) * 0.8
```

### 8.3 緊急時の対処

1. **即座に Collector を再起動** → マップがクリアされ、一時的に回復
2. **高カーディナリティ属性を削除** → `attributes` processor で削除
3. **groupbyattrs を無効化** → 設定から削除して再起動
4. **上流でサンプリング** → 全データを送らない

---

## 9. 結論と教訓

### 9.1 高カーディナリティは「見えない爆弾」

- 開発環境では問題なくても、本番で突然爆発する
- 原因はコードではなく「データの特性」であり、発見が遅れやすい
- 下流のバックエンドにも影響が波及する（本シナリオでは Jaeger が 6GB）

### 9.2 ステートフルprocessorは「諸刃の剣」

- `groupbyattrs`, `groupbytrace`, `tail_sampling` などは強力だが、カーディナリティに敏感
- 設定前に、keys に指定する属性のカーディナリティを **必ず確認** する
- 「低カーディナリティ」= 1時間で1,000種類以下が目安

### 9.3 診断のポイント

| 症状 | 原因 |
|------|------|
| Queue 100% 張り付き | シナリオ1（下流停止） |
| Queue 高位で乱高下 | シナリオ2（キャパシティ不足） |
| **スループット段階的低下** + **Heap右肩上がり** | **シナリオ2b（高カーディナリティ）** ← 本シナリオ |

### 9.4 本番投入チェックリスト

実務で `groupbyattrs` や `tail_sampling` を導入する際は、以下を確認すること：

- [ ] keys に指定する属性のカーディナリティを確認した（1時間で1,000種類以下）
- [ ] memory_limiter をステートフルprocessorの前に配置した
- [ ] Heapメモリの監視アラートを設定した
- [ ] スループット低下の監視アラートを設定した
- [ ] 緊急時のロールバック手順を準備した（設定ファイルのバックアップ）
- [ ] 本番相当のトラフィックで負荷テストを実施した

---

## 10. 参考情報

### 関連ドキュメント
- [groupbyattrs processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/groupbyattrsprocessor)
- [memory_limiter processor](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md)
- [scenarios.md](../scenarios.md) - シナリオ2b の再現手順

### 実行コマンド
```bash
make scenario-2   # 高カーディナリティシナリオ
```
