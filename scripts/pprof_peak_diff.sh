#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DIR=${1:-}
if [ -z "$DIR" ]; then
  echo "Usage: $0 <pprof_dir>" >&2
  exit 1
fi

if [ ! -d "$DIR" ]; then
  echo "Directory not found: $DIR" >&2
  exit 1
fi

LIST_OUTPUT=$(mktemp)
trap 'rm -f "$LIST_OUTPUT"' EXIT

# Use machine-readable output to avoid format drift from table rendering.
if ! python3 "${SCRIPT_DIR}/pprof_list.py" "$DIR" --format plain > "$LIST_OUTPUT"; then
  echo "Failed to run pprof_list.py for DIR=$DIR" >&2
  exit 1
fi

if ! grep -q "\.pprof" "$LIST_OUTPUT"; then
  echo "No .pprof entries found in: $DIR" >&2
  exit 1
fi

declare -a files=()
declare -a totals=()

while IFS= read -r line; do
  # Expected format: heap_123456.pprof: 12.34MB
  file=$(echo "$line" | awk -F: '{print $1}')
  total=$(echo "$line" | awk -F: '{print $2}' | xargs)
  if [ -z "$file" ] || [ -z "$total" ]; then
    continue
  fi

  number=$(echo "$total" | sed -E 's/^([0-9.]+).*/\1/')
  unit=$(echo "$total" | sed -E 's/^[0-9.]+([A-Za-z]+).*/\1/')
  if [ -z "$number" ] || [ -z "$unit" ]; then
    continue
  fi

  case "$unit" in
    B) scale=1 ;;
    kB|KB) scale=1024 ;;
    MB) scale=$((1024**2)) ;;
    GB) scale=$((1024**3)) ;;
    TB) scale=$((1024**4)) ;;
    *) continue ;;
  esac

  bytes=$(awk -v n="$number" -v s="$scale" 'BEGIN { printf "%.0f", n*s }')
  files+=("$file")
  totals+=("$bytes")
done < "$LIST_OUTPUT"

if [ "${#files[@]}" -lt 2 ]; then
  echo "Need at least two profiles to diff. Check DIR=$DIR" >&2
  exit 1
fi

peak_idx=0
for i in "${!totals[@]}"; do
  if [ "${totals[$i]}" -gt "${totals[$peak_idx]}" ]; then
    peak_idx=$i
  fi
done

if [ "$peak_idx" -eq 0 ]; then
  base_idx=1
else
  base_idx=$((peak_idx - 1))
fi

base_path="${DIR}/${files[$base_idx]}"
peak_path="${DIR}/${files[$peak_idx]}"

if [ ! -f "$base_path" ] || [ ! -f "$peak_path" ]; then
  echo "Failed to resolve base/peak profiles." >&2
  echo "BASE: $base_path" >&2
  echo "PEAK: $peak_path" >&2
  exit 1
fi

PPROF_DIFF_PORT=${PPROF_DIFF_PORT:-8081}

echo "BASE: $base_path"
echo "PEAK: $peak_path"
echo "Opening diff view at http://localhost:${PPROF_DIFF_PORT}"
go tool pprof -http=:"${PPROF_DIFF_PORT}" --diff_base "$base_path" "$peak_path"
