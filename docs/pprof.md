# pprof 手順メモ

OpenTelemetry Collector の pprof 取得・比較手順を、Terraform / Google Cloud 実行前提でまとめたドキュメントです。

## 出力先

- pprof キャプチャ: `captures/<MM-DD>/<RUN_ID>/pprof/heap_*.pprof`
- キャプチャログ: `captures/logs/pprof_capture.log`
- ポートフォワードログ: `captures/logs/port_forward.log`

## 推奨フロー

```bash
export PROJECT_ID=$(gcloud config get-value project)
make run-tail-sampling
```

このターゲットは以下をまとめて実行します。

1. Terraform apply
2. VM への同期・再起動
3. ポートフォワード
4. pprof キャプチャ開始
5. シナリオ実行
6. キャプチャ停止
7. diff 表示
8. Terraform destroy

## 個別操作

```bash
make -C terraform apply
make -C terraform forward-bg
make pprof-capture-bg
make pprof-capture-stop
make -C terraform forward-stop
make -C terraform destroy
```

## 変数で調整

```bash
SCENARIO=scenario-spanmetrics SYNC=0 RESTART=0 make run-scenario
```

## pprof の比較

```bash
make pprof-peak-diff DIR=captures/01-23/175921

make pprof-diff \
  BASE=captures/01-23/175921/pprof/heap_120000.pprof \
  NEW=captures/01-23/175921/pprof/heap_120010.pprof
```