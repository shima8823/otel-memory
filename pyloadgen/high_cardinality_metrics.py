#!/usr/bin/env python3
import argparse
import logging
import random
import signal
import threading
import time
import uuid

from opentelemetry import metrics
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource

LOGGER = logging.getLogger("pyloadgen.metrics")
STOP_EVENT = threading.Event()

METHODS = ["GET", "POST", "PUT", "DELETE"]
STATUS_CODES = ["200", "201", "400", "404", "500"]
ENDPOINT_PATTERNS = [
    "/api/users/{id}",
    "/api/orders/{id}",
    "/api/products/{id}",
    "/api/cart/{id}",
    "/api/payments/{id}",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate high-cardinality metrics with OpenTelemetry Python SDK"
    )
    parser.add_argument("--endpoint", default="localhost:4317", help="OTLP gRPC endpoint")
    parser.add_argument("--rate", type=float, default=1500, help="Metric records per second")
    parser.add_argument("--duration", type=int, default=240, help="Duration in seconds")
    parser.add_argument(
        "--cardinality",
        type=int,
        default=35000,
        help="Target time-series cardinality (display only)",
    )
    args = parser.parse_args()

    if args.rate <= 0:
        parser.error("--rate must be greater than 0")
    if args.duration <= 0:
        parser.error("--duration must be greater than 0")
    if args.cardinality <= 0:
        parser.error("--cardinality must be greater than 0")

    return args


def build_attributes(session_pool: list[str]) -> dict[str, str]:
    endpoint_template = random.choice(ENDPOINT_PATTERNS)
    endpoint_value = endpoint_template.format(id=random.randint(1, 1000000))

    return {
        "request_id": str(uuid.uuid4()),
        "user_id": f"user-{random.randint(0, 999)}",
        "session_id": random.choice(session_pool),
        "endpoint": endpoint_value,
        "method": random.choice(METHODS),
        "status": random.choice(STATUS_CODES),
    }


def setup_meter_provider(endpoint: str) -> MeterProvider:
    resource = Resource.create({"service.name": "pyloadgen-metrics"})
    exporter = OTLPMetricExporter(endpoint=endpoint, insecure=True)
    reader = PeriodicExportingMetricReader(exporter, export_interval_millis=100)
    provider = MeterProvider(resource=resource, metric_readers=[reader])
    metrics.set_meter_provider(provider)
    return provider


def print_startup(args: argparse.Namespace) -> None:
    LOGGER.info("========================================")
    LOGGER.info("PyLoadgen (Metrics) starting...")
    LOGGER.info("  Endpoint:    %s", args.endpoint)
    LOGGER.info("  Rate:        %s records/sec", int(args.rate) if args.rate.is_integer() else args.rate)
    LOGGER.info("  Duration:    %ss", args.duration)
    LOGGER.info("  Cardinality: %d (target)", args.cardinality)
    LOGGER.info("========================================")


def print_finish(total_records: int) -> None:
    LOGGER.info("========================================")
    LOGGER.info("PyLoadgen finished")
    LOGGER.info("  Total records: %d", total_records)
    LOGGER.info("========================================")


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")
    args = parse_args()
    STOP_EVENT.clear()

    provider = setup_meter_provider(args.endpoint)
    meter = metrics.get_meter("pyloadgen.high-cardinality-metrics")
    request_counter = meter.create_counter("http.server.request.count")
    request_duration = meter.create_histogram("http.server.request.duration", unit="ms")

    session_pool = [str(uuid.uuid4()) for _ in range(1000)]

    def handle_sigint(_signum, _frame) -> None:
        if not STOP_EVENT.is_set():
            LOGGER.info("SIGINT received, stopping...")
            STOP_EVENT.set()

    signal.signal(signal.SIGINT, handle_sigint)

    print_startup(args)

    deadline = time.time() + args.duration
    interval = 1.0 / args.rate
    next_emit = time.perf_counter()

    total_records = 0
    last_records = 0
    last_report_at = time.time()

    try:
        while not STOP_EVENT.is_set() and time.time() < deadline:
            now = time.perf_counter()
            if now < next_emit:
                time.sleep(next_emit - now)

            attrs = build_attributes(session_pool)
            request_counter.add(1, attrs)
            request_duration.record(random.randint(1, 5000), attrs)
            total_records += 1
            next_emit += interval

            now_wall = time.time()
            if now_wall - last_report_at >= 5:
                elapsed = max(now_wall - last_report_at, 1e-9)
                rate = int((total_records - last_records) / elapsed)
                remaining = max(0, int(deadline - now_wall))
                LOGGER.info(
                    "[PROGRESS] Records: %d (rate: %d/sec), Remaining: %ds",
                    total_records,
                    rate,
                    remaining,
                )
                last_records = total_records
                last_report_at = now_wall
    finally:
        provider.shutdown()
        print_finish(total_records)


if __name__ == "__main__":
    main()
