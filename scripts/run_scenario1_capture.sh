#!/bin/bash
set -euo pipefail

PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}
ZONE=${ZONE:-asia-northeast1-a}
COLLECTOR_INSTANCE=${COLLECTOR_INSTANCE:-otel-collector}
SCENARIO_TARGET=${SCENARIO_TARGET:-scenario-1}
CAPTURE_INTERVAL=${CAPTURE_INTERVAL:-5}
CAPTURE_BASE_DIR=${CAPTURE_BASE_DIR:-""}
MAX_CAPTURES=${MAX_CAPTURES:-0}
KEEP_FORWARD=${KEEP_FORWARD:-0}
OUTPUT_FILE=${OUTPUT_FILE:-""}

if [ -z "$PROJECT_ID" ]; then
  echo "PROJECT_ID is not set. Run: export PROJECT_ID=\$(gcloud config get-value project)" >&2
  exit 1
fi

LOG_DIR=${LOG_DIR:-"pprof/logs"}
mkdir -p "${LOG_DIR}"
FORWARD_LOG=$(mktemp "${LOG_DIR}/port_forward.XXXXXX.log")
CAPTURE_LOG=$(mktemp "${LOG_DIR}/capture.XXXXXX.log")
PORT_FORWARD_PID=""
CAPTURE_PID=""
KEEP_LOGS=${KEEP_LOGS:-0}

cleanup() {
  if [ -n "${CAPTURE_PID}" ] && kill -0 "${CAPTURE_PID}" 2>/dev/null; then
    kill "${CAPTURE_PID}" 2>/dev/null || true
    wait "${CAPTURE_PID}" 2>/dev/null || true
  fi
  if [ "${KEEP_FORWARD}" != "1" ]; then
    if [ -n "${PORT_FORWARD_PID}" ] && kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
      kill "${PORT_FORWARD_PID}" 2>/dev/null || true
      wait "${PORT_FORWARD_PID}" 2>/dev/null || true
    fi
  else
    echo "Port-forward kept running (PID: ${PORT_FORWARD_PID})"
  fi
  if [ "${KEEP_LOGS}" != "1" ]; then
    rm -f "${FORWARD_LOG}" "${CAPTURE_LOG}"
  else
    echo "Logs kept:"
    echo "  ${FORWARD_LOG}"
    echo "  ${CAPTURE_LOG}"
  fi
}

trap cleanup EXIT

echo "=== Port forwarding (Grafana/Prometheus/pprof) ==="
gcloud compute ssh "${COLLECTOR_INSTANCE}" \
  --project "${PROJECT_ID}" \
  --zone "${ZONE}" \
  -- -N \
  -L 3000:localhost:3000 \
  -L 9090:localhost:9090 \
  -L 1777:localhost:1777 \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  >"${FORWARD_LOG}" 2>&1 &
PORT_FORWARD_PID=$!

echo "Waiting for pprof port to be ready..."
READY=0
for _ in $(seq 1 30); do
  if ! kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
    KEEP_LOGS=1
    echo "Port-forward process exited unexpectedly. Log: ${FORWARD_LOG}" >&2
    tail -n 50 "${FORWARD_LOG}" >&2 || true
    exit 1
  fi
  if curl -s --fail http://localhost:1777/debug/pprof/heap >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 1
done
if [ "${READY}" -ne 1 ]; then
  KEEP_LOGS=1
  echo "pprof port did not become ready. Check port-forward logs: ${FORWARD_LOG}" >&2
  tail -n 50 "${FORWARD_LOG}" >&2 || true
  exit 1
fi

echo "=== Start pprof capture ==="
if [ -n "${CAPTURE_BASE_DIR}" ]; then
  bash scripts/capture_pprof.sh "${CAPTURE_INTERVAL}" "${CAPTURE_BASE_DIR}" "${MAX_CAPTURES}" \
    | tee "${CAPTURE_LOG}" &
else
  bash scripts/capture_pprof.sh "${CAPTURE_INTERVAL}" "" "${MAX_CAPTURES}" \
    | tee "${CAPTURE_LOG}" &
fi
CAPTURE_PID=$!

echo "=== Run scenario: ${SCENARIO_TARGET} ==="
export PROJECT_ID
make -C terraform "${SCENARIO_TARGET}"

echo "=== Stop pprof capture ==="
kill "${CAPTURE_PID}" 2>/dev/null || true
wait "${CAPTURE_PID}" 2>/dev/null || true

OUTPUT_DIR=$(grep -m1 "保存先:" "${CAPTURE_LOG}" | sed 's/.*保存先: //')
if [ -n "${OUTPUT_DIR}" ]; then
  echo "Captured profiles: ${OUTPUT_DIR}"
  if [ -n "${OUTPUT_FILE}" ]; then
    echo "${OUTPUT_DIR}" > "${OUTPUT_FILE}"
  fi
else
  echo "Captured profiles: (see log output above)"
fi
