import io
from pathlib import Path

path = Path("scripts/penny_scanner.py")
code = path.read_text()

old = '''df_hist = yf.download(yf_symbol, period="6mo", interval="1d", progress=False)
df_hist = df_hist.dropna(subset=["Close"])
'''

new = '''df_hist = yf.download(yf_symbol, period="6mo", interval="1d", progress=False)

# Guard: if no data or no Close column, skip this symbol
if df_hist is None or df_hist.empty or "Close" not in df_hist.columns:
    print(f"  WARNING: No usable price history from Yahoo for {yf_symbol}, skipping.")
    continue

df_hist = df_hist.dropna(subset=["Close"])
'''

if old not in code:
    raise SystemExit("Patch failed: expected block not found in penny_scanner.py")

path.write_text(code.replace(old, new))
print("Patch applied successfully to scripts/penny_scanner.py")
