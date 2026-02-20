#!/usr/bin/env python3
"""Stateless Prometheus metrics HTTP server for high-cardinality load generation."""

import argparse
import logging
import random
import signal
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

METHODS = ("GET", "POST", "PUT", "DELETE")
STATUS_CODES = ("200", "201", "400", "404", "500")
LOGGER = logging.getLogger("high-cardinality-prom-server")

# Parsed once in main() and read in handler for each scrape.
ARGS: argparse.Namespace | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Serve stateless high-cardinality Prometheus metrics"
    )
    parser.add_argument("--port", type=int, default=9091)
    parser.add_argument("--series-per-scrape", type=int, default=5000)
    parser.add_argument("--duration", type=int, default=240)
    args = parser.parse_args()

    if not (1 <= args.port <= 65535):
        parser.error("--port must be in range 1..65535")
    if args.series_per_scrape <= 0:
        parser.error("--series-per-scrape must be greater than 0")
    if args.duration < 0:
        parser.error("--duration must be 0 or greater")

    return args


def build_metrics_payload(series_per_scrape: int) -> bytes:
    lines = [
        "# HELP http_requests_total Total HTTP requests",
        "# TYPE http_requests_total counter",
        "# HELP http_request_duration_ms HTTP request duration in milliseconds",
        "# TYPE http_request_duration_ms gauge",
    ]

    for _ in range(series_per_scrape):
        request_id = str(uuid.uuid4())
        user_id = f"user-{random.randint(0, 999)}"
        endpoint = f"/api/users/{random.randint(1, 1_000_000)}"
        method = random.choice(METHODS)
        status = random.choice(STATUS_CODES)

        labels = (
            f'request_id="{request_id}",'
            f'user_id="{user_id}",'
            f'endpoint="{endpoint}",'
            f'method="{method}",'
            f'status="{status}"'
        )

        lines.append(f"http_requests_total{{{labels}}} 1")
        lines.append(
            f"http_request_duration_ms{{{labels}}} {random.randint(1, 5000)}"
        )

    return ("\n".join(lines) + "\n").encode("utf-8")


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path != "/metrics":
            body = b"404 Not Found\n"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if ARGS is None:
            body = b"500 Internal Server Error\n"
            self.send_response(500)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        payload = build_metrics_payload(ARGS.series_per_scrape)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format: str, *_args: object) -> None:
        # Suppress per-request access logs.
        return


def install_signal_handlers(server: HTTPServer) -> None:
    def _handle_signal(signum: int, _frame: object) -> None:
        signame = signal.Signals(signum).name
        LOGGER.info("%s received, shutting down server", signame)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)


def main() -> int:
    global ARGS

    logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")
    ARGS = parse_args()

    server = HTTPServer(("", ARGS.port), MetricsHandler)
    install_signal_handlers(server)

    timer = None
    if ARGS.duration > 0:
        def _timed_shutdown() -> None:
            LOGGER.info("Duration %ss elapsed, shutting down server", ARGS.duration)
            server.shutdown()

        timer = threading.Timer(ARGS.duration, _timed_shutdown)
        timer.daemon = True
        timer.start()

    LOGGER.info(
        "Starting stateless Prometheus server: port=%d series_per_scrape=%d duration=%s",
        ARGS.port,
        ARGS.series_per_scrape,
        f"{ARGS.duration}s" if ARGS.duration > 0 else "forever",
    )

    try:
        server.serve_forever()
    finally:
        if timer is not None:
            timer.cancel()
        server.server_close()
        LOGGER.info("Server stopped")

    return 0


if __name__ == "__main__":
    sys.exit(main())
