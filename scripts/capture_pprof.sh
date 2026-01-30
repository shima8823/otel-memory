#!/bin/bash
# pprof 自動キャプチャスクリプト

INTERVAL=${1:-10}  # デフォルト10秒
DATE_DIR=$(date +%m-%d)
# ファイル名の衝突を避けるための通し番号ファイル
RUN_ID=$(date +%H%M%S)
BASE_DIR=${2:-""}
MAX_CAPTURES=${3:-0}
OUTPUT_FILE=${OUTPUT_FILE:-""}
if [ -z "$BASE_DIR" ]; then
    BASE_DIR="notes/${DATE_DIR}/captures"
fi
OUTPUT_DIR="${BASE_DIR}/${RUN_ID}"

mkdir -p "$OUTPUT_DIR"
if [ -n "$OUTPUT_FILE" ]; then
    echo "$OUTPUT_DIR" > "$OUTPUT_FILE"
fi

echo "===================================================="
echo "📸 pprof 自動キャプチャを開始します"
echo "⏱️  間隔: ${INTERVAL}秒"
echo "📂 保存先: $OUTPUT_DIR"
echo "⚠️  注意: 別のターミナルで 'make pprof' トンネルを実行してください"
echo "===================================================="

COUNT=0
while true; do
    TS=$(date +%H%M%S)
    FILE_PATH="${OUTPUT_DIR}/heap_${TS}.pprof"
    
    # Heapプロファイルをバイナリ形式で取得
    # -s で進捗を非表示に
    # --fail で404などの時に空ファイルを作らないように
    if curl -s --fail http://localhost:1777/debug/pprof/heap > "$FILE_PATH"; then
        FILE_SIZE=$(ls -lh "$FILE_PATH" | awk '{print $5}')
        echo "[$(date +%T)] 📥 Captured: heap_${TS}.pprof ($FILE_SIZE)"
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
