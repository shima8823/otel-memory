# 共有 telemetrygen パラメータ
# ルート Makefile と terraform/Makefile の両方から include される
# 値を変更すればローカル・GCP 両方に反映される

# === Tail Sampling ===
TGEN_TAIL_RATE := 1500
TGEN_TAIL_DURATION := 120s
TGEN_TAIL_WORKERS := 10
TGEN_TAIL_CHILD_SPANS := 5

# === Batch × Queue ===
TGEN_BQ_RATE := 4000
TGEN_BQ_DURATION := 120s
TGEN_BQ_WORKERS := 10
TGEN_BQ_CHILD_SPANS := 3
# デフォルト ~280B → ~540B に増大するためのパディング（256文字）
TGEN_BQ_PADDING := aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# === SpanMetrics (高カーディナリティ) ===
TGEN_SM_RATE := 1300
TGEN_SM_DURATION := 300
TGEN_SM_WORKERS := 10
TGEN_SM_ATTR_COUNT := 8
