# Grafana Metrics Export Summary

エクスポート日時: 2026-03-17 17:14:49
期間: 直近 10 分
間隔: 15 秒

## エクスポートしたメトリクス

- **Heap_Alloc_bytes**: Collector Heap Memory - 現在のヒープ割り当てサイズ
- **Total_Alloc_bytes**: Total Alloc (cumulative) - 累積メモリ割り当て
- **Sys_Memory_bytes**: Sys Memory - OS から割り当てられたメモリ
- **RSS_Memory_bytes**: RSS (Resident Set Size) - 物理メモリ使用量
- **Uptime_seconds**: Collector Uptime - 起動時間
- **CPU_Usage_Rate**: CPU Usage Rate - CPU使用率
- **Receiver_Accepted_Spans_Rate**: Receiver: 受信したSpansのレート
- **Receiver_Refused_Spans_Rate**: Receiver: 拒否されたSpansのレート
- **Receiver_Accepted_Metrics_Rate**: Receiver: 受信したMetric Pointsのレート
- **Receiver_Refused_Metrics_Rate**: Receiver: 拒否されたMetric Pointsのレート
- **Receiver_Accepted_Logs_Rate**: Receiver: 受信したLog Recordsのレート
- **Receiver_Refused_Logs_Rate**: Receiver: 拒否されたLog Recordsのレート
- **Processor_Batch_Avg_Size**: Batch Processor: 平均バッチサイズ
- **Processor_Batch_Metadata_Cardinality**: Batch Processor: Metadata Cardinality
- **Processor_Batch_Size_Trigger_Rate**: Batch Processor: サイズトリガー送信レート
- **Processor_Batch_Timeout_Trigger_Rate**: Batch Processor: タイムアウトトリガー送信レート
- **Exporter_Sent_Spans_Rate**: Exporter: 送信成功Spansのレート
- **Exporter_Failed_Spans_Rate**: Exporter: 送信失敗Spansのレート
- **Exporter_Sent_Metrics_Rate**: Exporter: 送信成功Metric Pointsのレート
- **Exporter_Failed_Metrics_Rate**: Exporter: 送信失敗Metric Pointsのレート
- **Exporter_Sent_Logs_Rate**: Exporter: 送信成功Log Recordsのレート
- **Exporter_Failed_Logs_Rate**: Exporter: 送信失敗Log Recordsのレート
- **Exporter_Queue_Usage**: Exporter: キュー使用率
- **Exporter_Enqueue_Failed_Rate**: Exporter: キュー投入失敗レート (Spans)
- **Receiver_Accepted_Spans_Total**: Receiver: テスト期間中に受信したSpans累計
- **Receiver_Refused_Spans_Total**: Receiver: テスト期間中に拒否されたSpans累計
- **Exporter_Sent_Spans_Total**: Exporter: テスト期間中に送信成功したSpans累計
- **Exporter_Failed_Spans_Total**: Exporter: テスト期間中に送信失敗したSpans累計
- **TailSampling_Traces_On_Memory**: Tail Sampling: 現在メモリに保持しているトレース数
- **TailSampling_Count_Traces_Sampled**: Tail Sampling: サンプリング判定済みトレース累計（policy/decision ラベル付き）
- **TailSampling_Global_Count_Traces_Sampled**: Tail Sampling: 全ポリシー通じたサンプリング判定済みトレース累計
- **TailSampling_New_Trace_Received**: Tail Sampling: 新規トレース到着数累計
- **TailSampling_Dropped_Too_Early**: Tail Sampling: num_traces上限超過による強制ドロップ累計