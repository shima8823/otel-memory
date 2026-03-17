# ブログ構成メモ

このファイルは、ブログの構成と「各セクションで何を書くか」を整理するためのファイルです。

## セクションリンク

- ブログ本文の正本: `docs/blog/drafts/paper.md`
- Tail Sampling の図版・キャプチャ: `docs/blog/scenario-reports/tail-sampling/captures/`

## 記事全体の構成

### はじめに
モチベーションと背景（データ欠損リスク）

### デバッグの基本技法と環境準備
- 観測方法（internal metrics / pprof）
- 負荷生成ツール（loadgen / telemetrygen）
- 環境構築（Google Cloud）
- 診断の基本フロー

### シナリオ選定の設計思想
- なぜ複数シナリオが必要か（原因の切り分け）
- 選定に使う7つの視点
- 原因分類
- 代表シナリオ: Tail Sampling、高カーディナリティ、Batch × Queue メモリ増幅

### 実践検証: Tail Sampling（保持遅延型）
1. 再現手順（decision_wait: 30s, always_sample）
2. Grafana 観測（Heap の急騰→高止まり→解放パターン）
3. pprof 解析（tailsamplingprocessor のバッファ）
4. メカニズム解明（概算式と実測検算）
5. パラメータ最適化（decision_wait 短縮）
6. 他シナリオとの鑑別

### 実践検証: 高カーディナリティ（状態膨張型）
1. 再現手順（spanmetrics + UUID 属性）
2. タイムライン（60秒で memory_limiter 発火 → 295秒で OOM）
3. メトリクス観測（スループット段階的低下 + Heap 右肩上がり）
4. メカニズム解明（内部マップの無限膨張 + GC の死のスパイラル）
5. pprof 解析（spanmetricsconnector の map 操作）
6. 実務パターンと対処法
7. Tail Sampling との鑑別

### 実践検証: Batch × Queue メモリ増幅（キュー滞留型）
1. 再現手順（send_batch_size: 8192, queue_size: 500 + 下流遅延）
2. Grafana 観測（exporter queue メトリクスと Heap の soft_limit 付近での振動パターン）
3. pprof 解析（batch processor + exporter queue のバッファ）
4. メカニズム解明（掛け算効果の概算式と実測検算）
5. パラメータ最適化（send_batch_size + queue_size チューニング）
6. Batch Processor の今後（exporter-level batching への移行動向）
7. 他シナリオとの鑑別

### ベストプラクティス
- Memory Limiter / Batch / Sending Queue の設定指針
- ステートフル Processor の注意事項
- 監視アラート設定テンプレート
- 安全なベースライン設定テンプレート

### まとめ

## 完成状態

| セクション | ファイル | 状態 |
|-----------|--------|------|
| デバッグ基本技法 | `drafts/paper.md` セクション2に統合 | 完成 |
| シナリオ選定 | `why-these-scenarios.md` | 完成 |
| Tail Sampling | `drafts/paper.md` に統合、図版は `tail-sampling/captures/` | 完成 |
| 高カーディナリティ | `drafts/paper.md` への統合は未着手、図版は `high-cardinality/captures/` | 保留 |
| Batch × Queue メモリ増幅 | `drafts/paper.md` への統合は未着手、図版は `batch-queue/captures/` | 保留 |
| ベストプラクティス | `drafts/paper.md` セクション7に統合 | 完成 |

## drafts/paper.md の方針

`docs/blog/scenario-reports/` 配下には図版、pprof、ログなどの素材のみを残し、シナリオごとの本文レポートは持たない。

### 今後の予定

- 高カーディナリティ（状態膨張型）を追加（別 PR）
- Batch × Queue メモリ増幅（キュー滞留型）を追加（別 PR）
