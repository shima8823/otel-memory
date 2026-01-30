#!/bin/bash
# pprof 自動比較スクリプト
# ディレクトリ内の全 .pprof ファイルをスキャンし、
# 最小メモリ使用量（ベースライン）と最大メモリ使用量（ピーク）を自動検出して比較します。

set -euo pipefail

DIR=${1:-}
if [ -z "$DIR" ]; then
  echo "Usage: $0 <pprof_dir>" >&2
  echo "Example: $0 notes/01-23/captures/175921" >&2
  exit 1
fi

if [ ! -d "$DIR" ]; then
  echo "❌ Directory not found: $DIR" >&2
  exit 1
fi

# .pprof ファイルの存在確認
PPROF_FILES=("${DIR}"/*.pprof)
if [ ! -f "${PPROF_FILES[0]}" ]; then
  echo "❌ No .pprof files found in: $DIR" >&2
  exit 1
fi

echo "📊 Scanning .pprof files in: $DIR"
echo ""

min_file=""
min_val=999999999999999
max_file=""
max_val=0

# 各ファイルの inuse_space を解析
for f in "${DIR}"/*.pprof; do
  [ -s "$f" ] || continue  # 空ファイルをスキップ
  
  # go tool pprof で inuse_space の合計値を取得
  # -top で "Showing top ... out of XXXMB total" という行を抽出
  raw_output=$(go tool pprof -top "$f" 2>/dev/null | grep "Showing top" || echo "")
  
  if [ -z "$raw_output" ]; then
    echo "⚠️  Skipping (no data): $(basename "$f")"
    continue
  fi
  
  # "71.50MB" のような文字列を抽出
  val_str=$(echo "$raw_output" | sed -E 's/.*of ([0-9.]+[kMG]?B).*/\1/')
  
  # 単位を bytes に変換（numfmt が使える場合）
  if command -v numfmt >/dev/null 2>&1; then
    val=$(echo "$val_str" | numfmt --from=iec 2>/dev/null || echo "0")
  else
    # numfmt がない場合は簡易的に MB として扱う
    val=$(echo "$val_str" | sed -E 's/([0-9.]+)MB/\1/' | awk '{print int($1 * 1024 * 1024)}')
  fi
  
  echo "  $(basename "$f"): $val_str"
  
  # 最小値の更新
  if [ "$val" -lt "$min_val" ]; then
    min_val=$val
    min_file=$f
  fi
  
  # 最大値の更新
  if [ "$val" -gt "$max_val" ]; then
    max_val=$val
    max_file=$f
  fi
done

echo ""

# 結果の確認
if [ -z "$min_file" ] || [ -z "$max_file" ]; then
  echo "❌ Could not determine min/max files" >&2
  exit 1
fi

# 同一ファイルの場合
if [ "$min_file" = "$max_file" ]; then
  echo "⚠️  All files have similar heap size. No significant variation detected."
  echo "   Opening single profile: $(basename "$min_file")"
  go tool pprof -http=:8080 "$min_file"
  exit 0
fi

# 結果表示
echo "=========================================="
echo "🔍 Auto-detected profiles:"
echo "=========================================="
echo "📌 Baseline (最小): $(basename "$min_file")"
go tool pprof -top "$min_file" 2>/dev/null | grep "Showing top" || echo "  (data unavailable)"
echo ""
echo "📈 Peak (最大):     $(basename "$max_file")"
go tool pprof -top "$max_file" 2>/dev/null | grep "Showing top" || echo "  (data unavailable)"
echo ""
echo "=========================================="
echo "🌐 Opening diff view at http://localhost:8081"
echo "   Press Ctrl+C to stop"
echo "=========================================="

# Diff 表示
go tool pprof -http=:8081 --diff_base "$min_file" "$max_file"
