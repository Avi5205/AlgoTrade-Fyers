#!/usr/bin/env bash
set -euo pipefail

echo "Patching scripts/penny_scanner.py to guard missing Close column..."

python3 - << 'PY'
from pathlib import Path

path = Path("scripts/penny_scanner.py")
code = path.read_text()

needle = '        try:\n            hist = yf.download(yf_symbol, period="6mo", interval="1d", progress=False)\n'
if needle not in code:
    raise SystemExit("Patch failed: expected yf.download line not found in scripts/penny_scanner.py")

guard = (
'        try:\n'
'            hist = yf.download(yf_symbol, period="6mo", interval="1d", progress=False)\n'
'            # Guard: if no data or no Close column, skip this symbol\n'
'            if hist is None or hist.empty or "Close" not in hist.columns:\n'
'                print(f"  WARNING: No usable price history for {yf_symbol}, skipping.")\n'
'                continue\n'
)

new_code = code.replace(needle, guard)
path.write_text(new_code)
print("Patch applied successfully to scripts/penny_scanner.py")
PY
