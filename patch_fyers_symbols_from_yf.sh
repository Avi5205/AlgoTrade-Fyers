#!/usr/bin/env bash
set -euo pipefail

echo "==============================================================="
echo " Patching fyers_symbol in data/penny_fundamentals.csv"
echo "  - Uses yf_symbol (.NS => NSE, .BO => BSE)"
echo "  - Leaves existing fyers_symbol values as-is"
echo "==============================================================="

# Go to repo root (where docker-compose.yml lives)
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run patch inside the fyers-swing-bot container so Python is guaranteed
docker compose run --rm fyers-swing-bot python - << 'PYEOF'
import pandas as pd
from pathlib import Path
import math

path = Path("data") / "penny_fundamentals.csv"
print(f"Loading {path} ...")
df = pd.read_csv(path)

# Ensure fyers_symbol column exists
if "fyers_symbol" not in df.columns:
    df["fyers_symbol"] = ""

def is_missing(x) -> bool:
    if x is None:
        return True
    if isinstance(x, float) and math.isnan(x):
        return True
    if isinstance(x, str) and (x.strip() == "" or x.strip().lower() == "nan"):
        return True
    return False

updated_rows = 0

for idx, row in df.iterrows():
    cur_fyers = row.get("fyers_symbol", "")
    if not is_missing(cur_fyers):
        # Already has a value; don't override
        continue

    yf = row.get("yf_symbol", "")
    if is_missing(yf):
        continue

    if not isinstance(yf, str):
        continue

    parts = yf.split(".")
    if len(parts) != 2:
        continue

    base, suffix = parts[0].strip().upper(), parts[1].strip().upper()
    if suffix == "NS":
        ex = "NSE"
    elif suffix == "BO":
        ex = "BSE"
    else:
        # Unknown suffix, skip
        continue

    fyers_symbol = f"{ex}:{base}-EQ"
    df.at[idx, "fyers_symbol"] = fyers_symbol
    updated_rows += 1

print(f"Patched fyers_symbol for {updated_rows} row(s).")

df.to_csv(path, index=False)
print(f"Saved updated fundamentals to {path}")

# Show a small preview of rows that now have fyers_symbol set
preview = df[~df["fyers_symbol"].astype(str).isin(["", "nan", "NaN"])][
    ["symbol", "name", "yf_symbol", "fyers_symbol"]
].head(15)

print("\nPreview of mapped rows:")
print(preview.to_string(index=False))
PYEOF

echo
echo "[1/2] Regenerating scan + recommendations inside Docker ..."
docker compose run --rm fyers-swing-bot python scripts/penny_scanner.py
docker compose run --rm fyers-swing-bot python scripts/penny_reco_scheduler.py

echo
echo "[2/2] Showing current penny_recommendations.csv ..."
docker compose run --rm fyers-swing-bot python - << 'PYEOF'
import pandas as pd
from pathlib import Path

path = Path("data") / "penny_recommendations.csv"
df = pd.read_csv(path)
print(df.to_string(index=False))
PYEOF

echo
echo "Done."
echo "Verify that fyers_symbol is now a proper FYERS symbol (e.g. NSE:SYNCOMF-EQ)."
echo "If some remain NaN, those specific cases likely need manual overrides in data/penny_fundamentals.csv."
echo "==============================================================="
