#!/usr/bin/env python3
import re
import subprocess
import sys

if len(sys.argv) < 2:
    print("N/A")
    sys.exit(0)

path = sys.argv[1]
out = subprocess.run(
    ["go", "tool", "pprof", "-top", path],
    capture_output=True,
    text=True,
).stdout

m = re.search(r"of\s+([0-9.]+)\s*([kKMGTP]?B)\s+total", out)
if not m:
    m = re.search(r"total:\s*([0-9.]+)\s*([kKMGTP]?B)", out)
if not m:
    print("N/A")
    sys.exit(0)

value = float(m.group(1))
unit = m.group(2)
scale = {"B": 1, "kB": 1024, "KB": 1024, "MB": 1024**2, "GB": 1024**3, "TB": 1024**4}.get(unit, 1)
mb = value * scale / (1024**2)
print(f"{mb:.2f}MB")
