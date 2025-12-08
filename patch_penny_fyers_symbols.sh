#!/usr/bin/env bash
set -euo pipefail

echo "==============================================================="
echo " Patching fyers_symbol for selected penny stocks"
echo "==============================================================="

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PY_SCRIPT="scripts/_patch_penny_fyers_symbols.py"

cat << 'PYEOF' > "$PY_SCRIPT"
import pandas as pd
from pathlib import Path

path = Path("data") / "penny_fundamentals.csv"
print(f"Loading {path} ...")
df = pd.read_csv(path)

if "fyers_symbol" not in df.columns:
    df["fyers_symbol"] = ""

mapping = {
    "FCL": "NSE:FCL-EQ",
    "MCLOUD": "NSE:MCLOUD-EQ",
    "MOREPENLAB": "NSE:MOREPENLAB-EQ",
}

if "symbol" not in df.columns:
    raise SystemExit("ERROR: 'symbol' column not found in penny_fundamentals.csv")

for sym, fy in mapping.items():
    mask = df["symbol"].astype(str).str.upper().eq(sym)
    if mask.any():
        df.loc[mask, "fyers_symbol"] = fy
        print(f"Set fyers_symbol={fy} for symbol={sym}")
    else:
        print(f"WARNING: symbol={sym} not found in CSV")

df.to_csv(path, index=False)
print(f"Saved patched file to {path}")

cols_show = ["symbol", "yf_symbol"] if "yf_symbol" in df.columns else ["symbol"]
cols_show += ["name", "cmp", "fyers_symbol"]
print("\nPreview after patch:")
print(df[cols_show].query("symbol in ['FCL','MCLOUD','MOREPENLAB']"))
PYEOF

echo "[1/2] Running patch inside Docker ..."
docker compose run --rm fyers-swing-bot python "$PY_SCRIPT"

echo "[2/2] Rebuilding image (to bake updated CSV into containers) ..."
docker compose build

echo "Done. Next recommended steps:"
echo "  docker compose run --rm fyers-swing-bot python scripts/penny_scanner.py"
echo "  docker compose run --rm fyers-swing-bot python scripts/penny_reco_scheduler.py"
echo "  docker compose up -d penny-reco penny-trader"
echo "  docker logs -f fyers-penny-trader"
echo "==============================================================="
