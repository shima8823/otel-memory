# 共有 telemetrygen パラメータ
# ルート Makefile と terraform/Makefile の両方から include される
# Google Cloud シナリオ実行で共有するパラメータ

# === Tail Sampling ===
TGEN_TAIL_RATE := 2500
TGEN_TAIL_DURATION := 120s
TGEN_TAIL_WORKERS := 10
TGEN_TAIL_CHILD_SPANS := 10

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

# === 負荷後バッファ（tail_sampling drain 待機） ===
POST_LOAD_BUFFER_TAIL := 90

# === メトリクスエクスポート ===
EXPORT_DURATION ?= 5
EXPORT_DURATION_BQ ?= 10
EXPORT_DURATION_TAIL ?= 10
