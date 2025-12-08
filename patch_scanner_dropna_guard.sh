#!/usr/bin/env bash
set -euo pipefail

echo "==============================================================="
echo " Patching penny_scanner.py to guard dropna(subset=['Close'])"
echo "==============================================================="

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PY_FILE="scripts/penny_scanner.py"

if [ ! -f "$PY_FILE" ]; then
  echo "ERROR: $PY_FILE not found. Run this from repo root."
  exit 1
fi

# Prefer python3 on macOS; fallback to python if present
PYTHON_BIN="python3"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  PYTHON_BIN="python"
fi

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "ERROR: Neither python3 nor python found on PATH."
  exit 1
fi

$PYTHON_BIN << 'PYEOF'
from pathlib import Path

path = Path("scripts") / "penny_scanner.py"
code = path.read_text()

lines = code.splitlines()
new_lines = []
replaced = False

for line in lines:
    if line.strip() == 'hist = hist.dropna(subset=["Close"])':
        indent = line[:len(line) - len(line.lstrip())]
        block = f'''{indent}# Robust drop of rows with NaN in Close; tolerate missing Close column
{indent}subset_cols = [c for c in ["Close"] if c in hist.columns]
{indent}if not subset_cols:
{indent}    print(f"  WARNING: Data from Yahoo for {yf_symbol} has no \'Close\' column, skipping.")
{indent}    continue
{indent}hist = hist.dropna(subset=subset_cols)'''
        new_lines.append(block)
        replaced = True
    else:
        new_lines.append(line)

if not replaced:
    raise SystemExit("Patch failed: could not find 'hist = hist.dropna(subset=[\"Close\"])' in scripts/penny_scanner.py")

path.write_text("\n".join(new_lines) + "\n")
print("Patch applied successfully to scripts/penny_scanner.py")
PYEOF

echo
echo "[1/2] Rebuilding Docker images so patched scanner is baked in ..."
docker compose build

echo
echo "[2/2] Quick test of scanner inside Docker ..."
docker compose run --rm fyers-swing-bot python scripts/penny_scanner.py || true

echo
echo "==============================================================="
echo " Done."
echo " - Scanner will now skip any symbol where Yahoo returns no 'Close' column"
echo " - Next you can run:"
echo "     docker compose run --rm fyers-swing-bot python scripts/penny_reco_scheduler.py"
echo "     docker compose up -d penny-reco penny-trader"
echo "     docker logs -f fyers-penny-trader"
echo "==============================================================="
