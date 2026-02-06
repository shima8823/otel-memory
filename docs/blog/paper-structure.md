# ブログ構成メモ

このファイルは、ブログの構成と「各セクションで何を書くか」を整理するためのファイルです。  

## セクションリンク

- デバッグの基本技法と環境準備: `docs/blog/debug-basics.md`
- シナリオの選定: `docs/blog/scenario-reports/why-these-scenarios.md`
- 実践検証: `docs/blog/scenario-reports/*.md`
- ベストプラクティス: `docs/blog/best-practices.md`

## 各セクションで書くこと

### はじめに
モチベーションと背景(データ欠損リスク)

### デバッグの基本技法と環境準備
- 観測方法
  - otelcol_* の内部メトリクスをgrafanaで表示
    - 内部メトリクスは変更される可能性が高いので公式docで確認すること
  - pprof（heap profile）
  - TODO: zpages
- 負荷生成ツール
    - loadgen
    - TODO: telemetrygen
- 環境構築
  - local
  - google cloud での環境構築

### デバッグ例（シナリオ別メモリ挙動と解析）
- シナリオの選定理由

- 【シナリオX: 〇〇】
  1. 再現手順
    - 設定ファイル
    - 負荷生成コマンド
    - 期待される症状
  2. prometheus && grafanaで観測
    - 内部メトリクスの観測
  3. メモリ肥大化のメカニズム解明
    - pprof heap profile の取得
    - どのデータ構造が肥大化しているか
    - なぜその設定がその構造を肥大化させるのか
  4. パラメータ最適化
    - どのパラメータをどう変更すべきか
    - その変更がメモリ構造にどう影響するか（pprofで検証）
    - トレードオフの明示（スループット vs メモリ）
  5. 監視ポイント
    - otelcol_* メトリクスのどれを見るべきか
    - アラート閾値の根拠

### ベストプラクティス
主要コンポーネント（Memory Limiter, Batch, Queue）
- メモリ高騰を防ぐために公式ドキュメントを参照した値を確認する
- 設定テンプレート
- 監視アラート設定

### まとめ

