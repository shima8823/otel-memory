#!/usr/bin/env python3
"""
Grafanaダッシュボードのクエリデータを取得してLLM/人間向けに出力

使用方法:
    python export_grafana_metrics.py [--duration MINUTES] [--step SECONDS] [--output DIR]

例:
    python export_grafana_metrics.py                     # デフォルト: 直近15分、60秒間隔
    python export_grafana_metrics.py --duration 60      # 直近60分
    python export_grafana_metrics.py --step 30          # 30秒間隔
"""
import argparse
import json
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError

PROMETHEUS_URL = "http://localhost:9090"

# ダッシュボード (otel-collector-memory.json) から抽出したクエリ定義
# カテゴリごとに整理
QUERIES = {
    # Memory Overview
    "Heap_Alloc_bytes": {
        "query": 'otelcol_process_runtime_heap_alloc_bytes{job="otel-collector-self"}',
        "description": "Collector Heap Memory - 現在のヒープ割り当てサイズ",
        "unit": "bytes"
    },
    "Total_Alloc_bytes": {
        "query": 'otelcol_process_runtime_total_alloc_bytes_total{job="otel-collector-self"}',
        "description": "Total Alloc (cumulative) - 累積メモリ割り当て",
        "unit": "bytes"
    },
    "Sys_Memory_bytes": {
        "query": 'otelcol_process_runtime_total_sys_memory_bytes{job="otel-collector-self"}',
        "description": "Sys Memory - OS から割り当てられたメモリ",
        "unit": "bytes"
    },
    "RSS_Memory_bytes": {
        "query": 'otelcol_process_memory_rss_bytes{job="otel-collector-self"}',
        "description": "RSS (Resident Set Size) - 物理メモリ使用量",
        "unit": "bytes"
    },
    "Uptime_seconds": {
        "query": 'otelcol_process_uptime_seconds_total{job="otel-collector-self"}',
        "description": "Collector Uptime - 起動時間",
        "unit": "seconds"
    },
    "CPU_Usage_Rate": {
        "query": 'rate(otelcol_process_cpu_seconds_total{job="otel-collector-self"}[1m])',
        "description": "CPU Usage Rate - CPU使用率",
        "unit": "ratio"
    },
    
    # Receiver (受信)
    "Receiver_Accepted_Spans_Rate": {
        "query": 'rate(otelcol_receiver_accepted_spans_total{job="otel-collector-self"}[1m])',
        "description": "Receiver: 受信したSpansのレート",
        "unit": "ops"
    },
    "Receiver_Refused_Spans_Rate": {
        "query": 'rate(otelcol_receiver_refused_spans_total{job="otel-collector-self"}[1m])',
        "description": "Receiver: 拒否されたSpansのレート",
        "unit": "ops"
    },
    "Receiver_Accepted_Metrics_Rate": {
        "query": 'rate(otelcol_receiver_accepted_metric_points_total{job="otel-collector-self"}[1m])',
        "description": "Receiver: 受信したMetric Pointsのレート",
        "unit": "ops"
    },
    "Receiver_Refused_Metrics_Rate": {
        "query": 'rate(otelcol_receiver_refused_metric_points_total{job="otel-collector-self"}[1m])',
        "description": "Receiver: 拒否されたMetric Pointsのレート",
        "unit": "ops"
    },
    "Receiver_Accepted_Logs_Rate": {
        "query": 'rate(otelcol_receiver_accepted_log_records_total{job="otel-collector-self"}[1m])',
        "description": "Receiver: 受信したLog Recordsのレート",
        "unit": "ops"
    },
    "Receiver_Refused_Logs_Rate": {
        "query": 'rate(otelcol_receiver_refused_log_records_total{job="otel-collector-self"}[1m])',
        "description": "Receiver: 拒否されたLog Recordsのレート",
        "unit": "ops"
    },
    
    # Processor (処理)
    "Processor_Batch_Avg_Size": {
        "query": 'rate(otelcol_processor_batch_batch_send_size_sum{job="otel-collector-self"}[1m]) / rate(otelcol_processor_batch_batch_send_size_count{job="otel-collector-self"}[1m])',
        "description": "Batch Processor: 平均バッチサイズ",
        "unit": "items"
    },
    "Processor_Batch_Metadata_Cardinality": {
        "query": 'otelcol_processor_batch_metadata_cardinality{job="otel-collector-self"}',
        "description": "Batch Processor: Metadata Cardinality",
        "unit": "count"
    },
    "Processor_Batch_Size_Trigger_Rate": {
        "query": 'rate(otelcol_processor_batch_batch_size_trigger_send_total{job="otel-collector-self"}[1m])',
        "description": "Batch Processor: サイズトリガー送信レート",
        "unit": "ops"
    },
    "Processor_Batch_Timeout_Trigger_Rate": {
        "query": 'rate(otelcol_processor_batch_timeout_trigger_send_total{job="otel-collector-self"}[1m])',
        "description": "Batch Processor: タイムアウトトリガー送信レート",
        "unit": "ops"
    },
    
    # Exporter (送信)
    "Exporter_Sent_Spans_Rate": {
        "query": 'rate(otelcol_exporter_sent_spans_total{job="otel-collector-self"}[1m])',
        "description": "Exporter: 送信成功Spansのレート",
        "unit": "ops"
    },
    "Exporter_Failed_Spans_Rate": {
        "query": 'rate(otelcol_exporter_send_failed_spans_total{job="otel-collector-self"}[1m])',
        "description": "Exporter: 送信失敗Spansのレート",
        "unit": "ops"
    },
    "Exporter_Sent_Metrics_Rate": {
        "query": 'rate(otelcol_exporter_sent_metric_points_total{job="otel-collector-self"}[1m])',
        "description": "Exporter: 送信成功Metric Pointsのレート",
        "unit": "ops"
    },
    "Exporter_Failed_Metrics_Rate": {
        "query": 'rate(otelcol_exporter_send_failed_metric_points_total{job="otel-collector-self"}[1m])',
        "description": "Exporter: 送信失敗Metric Pointsのレート",
        "unit": "ops"
    },
    "Exporter_Sent_Logs_Rate": {
        "query": 'rate(otelcol_exporter_sent_log_records_total{job="otel-collector-self"}[1m])',
        "description": "Exporter: 送信成功Log Recordsのレート",
        "unit": "ops"
    },
    "Exporter_Failed_Logs_Rate": {
        "query": 'rate(otelcol_exporter_send_failed_log_records_total{job="otel-collector-self"}[1m])',
        "description": "Exporter: 送信失敗Log Recordsのレート",
        "unit": "ops"
    },
    "Exporter_Queue_Usage": {
        "query": 'otelcol_exporter_queue_size{job="otel-collector-self"} / otelcol_exporter_queue_capacity{job="otel-collector-self"}',
        "description": "Exporter: キュー使用率",
        "unit": "ratio"
    },
    "Exporter_Enqueue_Failed_Rate": {
        "query": 'rate(otelcol_exporter_enqueue_failed_spans_total{job="otel-collector-self"}[1m])',
        "description": "Exporter: キュー投入失敗レート (Spans)",
        "unit": "ops"
    },
}


def query_prometheus(query: str, start: int, end: int, step: str) -> dict:
    """Prometheusから時系列データを取得"""
    params = urlencode({
        "query": query,
        "start": start,
        "end": end,
        "step": step
    })
    url = f"{PROMETHEUS_URL}/api/v1/query_range?{params}"
    
    try:
        req = Request(url)
        with urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode())
    except HTTPError as e:
        print(f"HTTP Error: {e.code} - {e.reason}", file=sys.stderr)
        return {"status": "error", "error": str(e)}
    except URLError as e:
        print(f"URL Error: {e.reason}", file=sys.stderr)
        return {"status": "error", "error": str(e)}
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return {"status": "error", "error": str(e)}


def format_value(value: str, unit: str) -> str:
    """値をフォーマット（人間が読みやすい形式）"""
    try:
        num = float(value)
        if unit == "bytes":
            if num >= 1024 * 1024 * 1024:
                return f"{num / (1024 * 1024 * 1024):.2f} GB"
            elif num >= 1024 * 1024:
                return f"{num / (1024 * 1024):.2f} MB"
            elif num >= 1024:
                return f"{num / 1024:.2f} KB"
            else:
                return f"{num:.0f} B"
        elif unit == "ratio":
            return f"{num * 100:.2f}%"
        elif unit == "ops":
            return f"{num:.2f}/s"
        elif unit == "seconds":
            if num >= 3600:
                return f"{num / 3600:.2f}h"
            elif num >= 60:
                return f"{num / 60:.2f}m"
            else:
                return f"{num:.2f}s"
        else:
            return f"{num:.4f}"
    except (ValueError, TypeError):
        return value


def format_output(name: str, info: dict, data: list, raw_values: bool = False) -> str:
    """LLM/人間向けにフォーマット"""
    lines = [
        f"## {name}",
        f"説明: {info['description']}",
        f"単位: {info['unit']}",
        "",
        "時間, 値" + ("" if raw_values else ", フォーマット済み"),
        "-" * 60
    ]
    
    for ts, val in data:
        dt = datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")
        if raw_values:
            lines.append(f"{dt}, {val}")
        else:
            formatted = format_value(val, info['unit'])
            lines.append(f"{dt}, {val}, {formatted}")
    
    return "\n".join(lines)


def export_single_metric(name: str, info: dict, start: int, end: int, step: str, output_dir: Path, raw_values: bool = False) -> bool:
    """単一メトリクスをエクスポート"""
    result = query_prometheus(info["query"], start, end, step)
    
    if result.get("status") != "success":
        print(f"  ⚠️  {name}: クエリ失敗 - {result.get('error', 'unknown error')}", file=sys.stderr)
        return False
    
    data = result.get("data", {})
    results = data.get("result", [])
    
    if not results:
        print(f"  ⚠️  {name}: データなし")
        return False
    
    # 複数の結果がある場合（例: 複数のラベル）、それぞれを別々に出力
    for i, result_item in enumerate(results):
        values = result_item.get("values", [])
        metric_labels = result_item.get("metric", {})
        
        if not values:
            continue
        
        # ラベル情報をファイル名に追加
        suffix = ""
        if len(results) > 1:
            # 重要なラベルを抽出
            label_parts = []
            for key in ["receiver", "processor", "exporter", "data_type"]:
                if key in metric_labels:
                    label_parts.append(f"{metric_labels[key]}")
            if label_parts:
                suffix = "_" + "_".join(label_parts)
            else:
                suffix = f"_{i}"
        
        output = format_output(name, info, values, raw_values)
        
        # ラベル情報をヘッダーに追加
        if metric_labels:
            label_str = ", ".join([f"{k}={v}" for k, v in metric_labels.items() if not k.startswith("__")])
            if label_str:
                output = output.replace("## " + name, f"## {name}\nラベル: {label_str}")
        
        filename = f"{name}{suffix}.txt"
        (output_dir / filename).write_text(output, encoding="utf-8")
        print(f"  ✅ {filename} ({len(values)} data points)")
    
    return True


def export_all_metrics(duration_minutes: int = 15, step_seconds: int = 60, output_dir: str = "metrics_export", raw_values: bool = False):
    """すべてのメトリクスをエクスポート"""
    end = int(datetime.now().timestamp())
    start = end - (duration_minutes * 60)
    step = str(step_seconds)
    
    output_path = Path(output_dir)
    output_path.mkdir(exist_ok=True)
    
    print(f"=" * 60)
    print(f"Grafana Metrics Export")
    print(f"=" * 60)
    print(f"期間: 直近 {duration_minutes} 分")
    print(f"間隔: {step_seconds} 秒")
    print(f"出力先: {output_path.absolute()}")
    print(f"クエリ数: {len(QUERIES)}")
    print(f"=" * 60)
    print()
    
    success_count = 0
    fail_count = 0
    
    for name, info in QUERIES.items():
        if export_single_metric(name, info, start, end, step, output_path, raw_values):
            success_count += 1
        else:
            fail_count += 1
    
    print()
    print(f"=" * 60)
    print(f"完了: 成功 {success_count}, 失敗/データなし {fail_count}")
    print(f"出力ディレクトリ: {output_path.absolute()}")
    print(f"=" * 60)
    
    # サマリーファイルを作成
    summary_lines = [
        "# Grafana Metrics Export Summary",
        f"",
        f"エクスポート日時: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        f"期間: 直近 {duration_minutes} 分",
        f"間隔: {step_seconds} 秒",
        f"",
        "## エクスポートしたメトリクス",
        ""
    ]
    
    for name, info in QUERIES.items():
        summary_lines.append(f"- **{name}**: {info['description']}")
    
    (output_path / "_SUMMARY.md").write_text("\n".join(summary_lines), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(
        description="Grafanaダッシュボードのクエリデータを取得してLLM/人間向けに出力"
    )
    parser.add_argument(
        "--duration", "-d",
        type=int,
        default=15,
        help="取得する期間（分）。デフォルト: 15"
    )
    parser.add_argument(
        "--step", "-s",
        type=int,
        default=60,
        help="データポイントの間隔（秒）。デフォルト: 60"
    )
    parser.add_argument(
        "--output", "-o",
        type=str,
        default="metrics_export",
        help="出力ディレクトリ。デフォルト: metrics_export"
    )
    parser.add_argument(
        "--raw",
        action="store_true",
        help="フォーマット済み値を省略し、生の値のみ出力"
    )
    
    args = parser.parse_args()
    
    export_all_metrics(
        duration_minutes=args.duration,
        step_seconds=args.step,
        output_dir=args.output,
        raw_values=args.raw
    )


if __name__ == "__main__":
    main()
