#!/bin/bash
# pprof 自動キャプチャスクリプト

INTERVAL=${1:-10}  # デフォルト10秒
DATE_DIR=$(date +%m-%d)
# ファイル名の衝突を避けるための通し番号ファイル
RUN_ID=$(date +%H%M%S)
BASE_DIR=${2:-""}
MAX_CAPTURES=${3:-0}
OUTPUT_FILE=${OUTPUT_FILE:-""}
PPROF_URL=${PPROF_URL:-""}
if [ -z "$OUTPUT_FILE" ] && [ -n "${PPROF_LAST_DIR_FILE:-}" ]; then
    OUTPUT_FILE="${PPROF_LAST_DIR_FILE}"
fi
if [ -z "$BASE_DIR" ]; then
    BASE_DIR="pprof/${DATE_DIR}/captures"
fi
if [ -z "$PPROF_URL" ]; then
    PPROF_TUNNEL_PORT=${PPROF_TUNNEL_PORT:-1777}
    PPROF_URL="http://localhost:${PPROF_TUNNEL_PORT}/debug/pprof/heap"
fi
OUTPUT_DIR="${BASE_DIR}/${RUN_ID}"
READY_MARKER="${OUTPUT_DIR}/.ready"
HAS_READY=0

mkdir -p "$OUTPUT_DIR"
if [ -n "$OUTPUT_FILE" ]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    echo "$OUTPUT_DIR" > "$OUTPUT_FILE"
fi

echo "===================================================="
echo "📸 pprof 自動キャプチャを開始します"
echo "⏱️  間隔: ${INTERVAL}秒"
echo "📂 保存先: $OUTPUT_DIR"
echo "🔗 PPROF URL: $PPROF_URL"
echo "⚠️  注意: pprof トンネルが必要です (例: make -C terraform pprof)"
echo "===================================================="

COUNT=0
while true; do
    TS=$(date +%H%M%S)
    FILE_PATH="${OUTPUT_DIR}/heap_${TS}.pprof"
    
    # Heapプロファイルをバイナリ形式で取得
    # -s で進捗を非表示に
    # --fail で404などの時に空ファイルを作らないように
    if curl -s --fail "$PPROF_URL" > "$FILE_PATH"; then
        FILE_SIZE=$(ls -lh "$FILE_PATH" | awk '{print $5}')
        echo "[$(date +%T)] 📥 Captured: heap_${TS}.pprof ($FILE_SIZE)"
        if [ "$HAS_READY" -eq 0 ]; then
            touch "$READY_MARKER"
            HAS_READY=1
        fi
    else
        echo "[$(date +%T)] ❌ Failed to capture. Is the tunnel running?"
        rm -f "$FILE_PATH"
    fi

    COUNT=$((COUNT + 1))
    if [ "$MAX_CAPTURES" -gt 0 ] && [ "$COUNT" -ge "$MAX_CAPTURES" ]; then
        echo "✅ Reached max captures: ${MAX_CAPTURES}"
        break
    fi

    sleep "$INTERVAL"
done
