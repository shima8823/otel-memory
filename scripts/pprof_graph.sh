#!/bin/bash
# pprof peak プロファイルのコールグラフ画像を自動生成
#
# Usage: pprof_graph.sh <pprof_dir> <output_dir>
#
# pprof_dir 内のピークファイルを特定し、コールグラフを PNG で output_dir に出力する。
# 出力ファイル: pprof-graph.png
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PPROF_DIR="${1:?Usage: $0 <pprof_dir> <output_dir>}"
OUTPUT_DIR="${2:?Usage: $0 <pprof_dir> <output_dir>}"

if [ ! -d "$PPROF_DIR" ]; then
  echo "pprof directory not found: $PPROF_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# pprof_peak_diff.sh の PRINT_ONLY モードでピークファイルを特定
PEAK_OUTPUT=$(PRINT_ONLY=1 bash "${SCRIPT_DIR}/pprof_peak_diff.sh" "$PPROF_DIR" 2>/dev/null) || {
  echo "⚠️  Failed to find peak profile in $PPROF_DIR" >&2
  exit 1
}

PEAK_FILE=$(echo "$PEAK_OUTPUT" | grep "^PEAK:" | sed 's/^PEAK: //')

if [ -z "$PEAK_FILE" ] || [ ! -f "$PEAK_FILE" ]; then
  echo "⚠️  Peak file not found: $PEAK_FILE" >&2
  exit 1
fi

OUTPUT_FILE="${OUTPUT_DIR}/pprof-graph.png"

echo "Generating call graph: $PEAK_FILE → $OUTPUT_FILE"
go tool pprof -png -inuse_space -nodecount=15 "$PEAK_FILE" > "$OUTPUT_FILE" 2>/dev/null

if [ -s "$OUTPUT_FILE" ]; then
  echo "✅ pprof-graph.png generated ($(du -h "$OUTPUT_FILE" | cut -f1))"
else
  echo "⚠️  pprof-graph.png is empty, generation may have failed" >&2
  rm -f "$OUTPUT_FILE"
  exit 1
fi
