# ブログ構成メモ

このファイルは、ブログの構成と「各セクションで何を書くか」を整理するためのファイルです。

## セクションリンク

- デバッグの基本技法と環境準備: `docs/blog/debug-basics.md`
- シナリオの選定: `docs/blog/scenario-reports/why-these-scenarios.md`
- 実践検証（Tail Sampling）: `docs/blog/scenario-reports/tail-sampling/report.md`
- 実践検証（高カーディナリティ）: `docs/blog/scenario-reports/high-cardinality/report.md`
- 実践検証（Batch × Queue メモリ増幅）: `docs/blog/scenario-reports/batch-queue/report.md`
- ベストプラクティス: `docs/blog/best-practices.md`

## 記事全体の構成

### はじめに
モチベーションと背景（データ欠損リスク）

### デバッグの基本技法と環境準備
- 観測方法（internal metrics / pprof）
- 負荷生成ツール（loadgen / telemetrygen）
- 環境構築（ローカル / GCP）
- 診断の基本フロー

### シナリオ選定の設計思想
- なぜ複数シナリオが必要か（原因の切り分け）
- 選定に使う7つの視点
- 原因分類（キュー滞留型 / 状態膨張型 / 保持遅延型）
- 代表シナリオ: Tail Sampling（時間軸）、高カーディナリティ（空間軸）、Batch × Queue メモリ増幅（流量軸）

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
| デバッグ基本技法 | `debug-basics.md` | 完成 |
| シナリオ選定 | `why-these-scenarios.md` | 完成 |
| Tail Sampling | `tail-sampling/report.md` | 完成 |
| 高カーディナリティ | `high-cardinality/report.md` | 完成 |
| Batch × Queue メモリ増幅 | `batch-queue/report.md` | 完成 |
| ベストプラクティス | `best-practices.md` | 完成 |

## paper.md の方針

`docs/blog/paper.md` は各詳細レポートの要約を集約したブログ本文です。

### 現在のスコープ（PR 用）

- **Tail Sampling（保持遅延型）のみ**を記載
- 高カーディナリティ（状態膨張型）は記載しない

### 理由

PR のレビュー負担を軽減するため、まず Tail Sampling シナリオ単体で完成させてレビューに出す。
高カーディナリティなど追加シナリオは後続 PR で追加する。

### 今後の予定

- 高カーディナリティ（状態膨張型）を追加（別 PR）
- Batch × Queue メモリ増幅（キュー滞留型）を追加（別 PR）
