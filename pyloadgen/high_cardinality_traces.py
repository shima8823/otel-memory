#!/usr/bin/env python3
import argparse
import logging
import signal
import threading
import time
import random
import uuid
from concurrent.futures import ThreadPoolExecutor

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

LOGGER = logging.getLogger("pyloadgen.traces")
TOTAL_SPANS = 0
COUNTER_LOCK = threading.Lock()
STOP_EVENT = threading.Event()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate high-cardinality traces with OpenTelemetry Python SDK"
    )
    parser.add_argument("--endpoint", default="localhost:4317", help="OTLP gRPC endpoint")
    parser.add_argument("--rate", type=float, default=1300, help="Target traces per second")
    parser.add_argument("--duration", type=int, default=300, help="Duration in seconds")
    parser.add_argument("--workers", type=int, default=10, help="Concurrent worker threads")
    parser.add_argument("--attr-count", type=int, default=8, help="Attributes per span")
    parser.add_argument("--depth", type=int, default=5, help="Child span depth per trace")
    args = parser.parse_args()

    if args.rate <= 0:
        parser.error("--rate must be greater than 0")
    if args.duration <= 0:
        parser.error("--duration must be greater than 0")
    if args.workers <= 0:
        parser.error("--workers must be greater than 0")
    if args.attr_count < 0:
        parser.error("--attr-count must be 0 or greater")
    if args.depth < 0:
        parser.error("--depth must be 0 or greater")

    return args


# 中カーディナリティ属性の固定プール
# 個々の値は妥当だが、dimensions に全て含めると掛け算で組み合わせ爆発する
# attr_0(50) × attr_1(30) × attr_2(20) × attr_3(10) × attr_4(5) = 1,500,000 時系列
CARDINALITIES = [50, 30, 20, 10, 5, 3, 3, 3]


def build_attrs(attr_count: int) -> dict[str, str]:
    return {
        f"attr_{idx}": f"val_{random.randint(0, CARDINALITIES[idx] - 1)}"
        for idx in range(attr_count)
    }


def add_span_count(value: int) -> None:
    global TOTAL_SPANS
    with COUNTER_LOCK:
        TOTAL_SPANS += value


def get_total_spans() -> int:
    with COUNTER_LOCK:
        return TOTAL_SPANS


def generate_nested_spans(tracer, attr_count: int, depth: int, worker_id: int) -> int:
    if depth <= 0:
        return 0

    attrs = build_attrs(attr_count)
    with tracer.start_as_current_span(
        f"worker-{worker_id}-child-{depth}", attributes=attrs
    ):
        return 1 + generate_nested_spans(tracer, attr_count, depth - 1, worker_id)


def run_worker(
    worker_id: int,
    tracer,
    worker_rate: float,
    attr_count: int,
    depth: int,
    deadline: float,
) -> None:
    interval = 1.0 / worker_rate
    next_emit = time.perf_counter()

    while not STOP_EVENT.is_set() and time.time() < deadline:
        now = time.perf_counter()
        if now < next_emit:
            time.sleep(next_emit - now)

        attrs = build_attrs(attr_count)
        spans_in_trace = 0

        with tracer.start_as_current_span(
            f"worker-{worker_id}-root", attributes=attrs
        ):
            spans_in_trace += 1
            spans_in_trace += generate_nested_spans(
                tracer=tracer,
                attr_count=attr_count,
                depth=depth,
                worker_id=worker_id,
            )

        add_span_count(spans_in_trace)
        next_emit += interval


def report_progress(deadline: float) -> None:
    last_spans = 0
    last_time = time.time()

    while not STOP_EVENT.is_set():
        time.sleep(5)

        now = time.time()
        if now >= deadline:
            return

        current_spans = get_total_spans()
        elapsed = max(now - last_time, 1e-9)
        span_rate = int((current_spans - last_spans) / elapsed)
        remaining = max(0, int(deadline - now))

        LOGGER.info(
            "[PROGRESS] Spans: %d (rate: %d/sec), Remaining: %ds",
            current_spans,
            span_rate,
            remaining,
        )

        last_spans = current_spans
        last_time = now


def setup_tracer_provider(endpoint: str) -> TracerProvider:
    resource = Resource.create({"service.name": "pyloadgen-traces"})
    exporter = OTLPSpanExporter(endpoint=endpoint, insecure=True)
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)
    return provider


def print_startup(args: argparse.Namespace) -> None:
    LOGGER.info("========================================")
    LOGGER.info("PyLoadgen (Traces) starting...")
    LOGGER.info("  Endpoint:    %s", args.endpoint)
    LOGGER.info("  Rate:        %s traces/sec", int(args.rate) if args.rate.is_integer() else args.rate)
    LOGGER.info("  Duration:    %ss", args.duration)
    LOGGER.info("  Workers:     %d", args.workers)
    LOGGER.info("  Attr Count:  %d", args.attr_count)
    LOGGER.info("  Depth:       %d", args.depth)
    LOGGER.info("========================================")


def print_finish() -> None:
    LOGGER.info("========================================")
    LOGGER.info("PyLoadgen finished")
    LOGGER.info("  Total spans sent: %d", get_total_spans())
    LOGGER.info("========================================")


def main() -> None:
    global TOTAL_SPANS

    logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")
    args = parse_args()
    TOTAL_SPANS = 0
    STOP_EVENT.clear()

    provider = setup_tracer_provider(args.endpoint)
    tracer = trace.get_tracer("pyloadgen.high-cardinality-traces")

    def handle_sigint(_signum, _frame) -> None:
        if not STOP_EVENT.is_set():
            LOGGER.info("SIGINT received, stopping...")
            STOP_EVENT.set()

    signal.signal(signal.SIGINT, handle_sigint)

    deadline = time.time() + args.duration
    print_startup(args)

    progress_thread = threading.Thread(target=report_progress, args=(deadline,), daemon=True)
    progress_thread.start()

    worker_rate = args.rate / args.workers

    try:
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            for worker_id in range(args.workers):
                pool.submit(
                    run_worker,
                    worker_id,
                    tracer,
                    worker_rate,
                    args.attr_count,
                    args.depth,
                    deadline,
                )

            while not STOP_EVENT.is_set() and time.time() < deadline:
                time.sleep(0.2)
    finally:
        STOP_EVENT.set()
        progress_thread.join(timeout=1)
        provider.shutdown()
        print_finish()


if __name__ == "__main__":
    main()
