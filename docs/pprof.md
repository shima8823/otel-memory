# pprof 手順まとめ

OpenTelemetry Collector の pprof 取得・比較手順を、ローカル実行と Terraform/GCP 実行の両方でまとめたドキュメントです。

## 出力先

- pprof キャプチャ: `pprof/<MM-DD>/captures/<RUN_ID>/heap_*.pprof`
- キャプチャログ: `pprof/logs/pprof_capture.log`
- ポートフォワードログ: `pprof/logs/port_forward.log`

## ローカル（Docker Compose）での基本操作

```
# 起動
make up

# 1回だけ取得（UIで確認）
make pprof-heap
make pprof-allocs
make pprof-cpu
```

## ローカルでの連続キャプチャ

```
# フォアグラウンド（5秒間隔）
make pprof-capture

# バックグラウンド
make pprof-capture-bg
make pprof-capture-status
make pprof-capture-stop
```

保存先は `pprof/<MM-DD>/captures/<RUN_ID>` です。  
`CAPTURE_INTERVAL`, `CAPTURE_BASE_DIR`, `CAPTURE_MAX` で調整できます。

## Terraform / GCP 統合（推奨）

```
export PROJECT_ID=$(gcloud config get-value project)
make pprof-scenario1-full
```

このターゲットは以下をまとめて実行します。

1. Terraform apply
2. VM への同期・再起動
3. ポートフォワード
4. pprof キャプチャ開始
5. シナリオ実行
6. キャプチャ停止 + diff 表示

`.pprof_last_dir` は作成しません。保存先はログから取得できます。

```
grep -m1 "保存先:" pprof/logs/pprof_capture.log
```

### 変数で調整

```
SCENARIO=scenario-2 SYNC=0 RESTART=0 make pprof-scenario-full
```

## ワンコマンド（シナリオ1専用スクリプト）

```
export PROJECT_ID=$(gcloud config get-value project)
bash scripts/run_scenario1_capture.sh
```

よく使う調整例:

```
CAPTURE_INTERVAL=3 \
CAPTURE_BASE_DIR=pprof/01-23/captures \
KEEP_FORWARD=1 \
bash scripts/run_scenario1_capture.sh
```

## pprof の比較

```
# ピークと直前を自動で diff
make pprof-peak-diff DIR=pprof/01-23/captures/175921

# 手動で diff
make pprof-diff BASE=pprof/01-23/captures/175921/heap_120000.pprof \
               NEW=pprof/01-23/captures/175921/heap_120010.pprof
```

## トラブルシュート

- `localhost:1777` が開かない → ポートフォワード未起動
- `.pprof` が空 → 取得タイミングが早すぎる / Collector が落ちている
- Grafana が空 → scrape 遅延 or 時刻ずれ
