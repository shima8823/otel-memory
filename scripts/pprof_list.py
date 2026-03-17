#!/usr/bin/env python3
"""
List pprof files with total inuse_space and basic trend info.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path


def get_inuse_mb(path: Path):
    """Return total inuse_space in MB, or None when parsing fails."""
    try:
        out = subprocess.run(
            ["go", "tool", "pprof", "-top", str(path)],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        ).stdout
        match = re.search(r"of\s+([0-9.]+)\s*([kKMGTP]?B)\s+total", out)
        if not match:
            match = re.search(r"total:\s*([0-9.]+)\s*([kKMGTP]?B)", out)
        if not match:
            return None
        value = float(match.group(1))
        unit = match.group(2)
        scale = {
            "B": 1,
            "kB": 1024,
            "KB": 1024,
            "MB": 1024 ** 2,
            "GB": 1024 ** 3,
            "TB": 1024 ** 4,
        }.get(unit, 1)
        return value * scale / (1024 ** 2)
    except Exception:
        return None


def parse_args():
    parser = argparse.ArgumentParser(
        description="Show per-profile memory totals from .pprof files."
    )
    parser.add_argument("directory", help="Directory containing .pprof files")
    parser.add_argument(
        "--format",
        choices=("table", "plain"),
        default="table",
        help="Output format (default: table)",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    dir_path = Path(args.directory)
    files = sorted(dir_path.glob("*.pprof"))

    if not files:
        print(f"No .pprof files found in {dir_path}", file=sys.stderr)
        sys.exit(1)

    results = []
    for profile in files:
        mb = get_inuse_mb(profile)
        if mb is not None:
            results.append((profile.name, mb))

    if not results:
        print("Failed to parse any pprof files", file=sys.stderr)
        sys.exit(1)

    if args.format == "plain":
        for name, mb in results:
            print(f"{name}: {mb:.2f}MB")
        return

    min_mb = min(value for _, value in results)
    max_mb = max(value for _, value in results)
    first_mb = results[0][1]
    last_mb = results[-1][1]
    peak_name = max(results, key=lambda item: item[1])[0]

    print(f"{'File':<25} {'Memory':>10}  {'Change':>10}  {'Status'}")
    print("-" * 60)
    prev_mb = None
    for name, mb in results:
        change = ""
        status = ""
        if prev_mb is not None:
            delta = mb - prev_mb
            if abs(delta) > 0.5:
                change = f"{delta:+.1f}MB"
        if name == peak_name:
            status = "PEAK"
        elif mb > first_mb * 1.5:
            status = "HIGH"
        elif prev_mb and mb < prev_mb * 0.8:
            status = "DROP"
        print(f"{name:<25} {mb:>8.2f}MB  {change:>10}  {status}")
        prev_mb = mb

    print("-" * 60)
    print(f"Start: {first_mb:.2f}MB -> Peak: {max_mb:.2f}MB -> End: {last_mb:.2f}MB")
    if first_mb > 0:
        growth_pct = (max_mb / first_mb - 1) * 100
        print(f"Growth: {max_mb - first_mb:+.2f}MB ({growth_pct:+.1f}%)")
    else:
        print(f"Growth: {max_mb - first_mb:+.2f}MB")
    print(f"Peak file: {peak_name}")
    print(f"Range: {min_mb:.2f}MB - {max_mb:.2f}MB")


if __name__ == "__main__":
    main()
