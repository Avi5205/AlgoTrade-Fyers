import os
import sys
from datetime import datetime
from typing import Optional

# ADD PROJECT ROOT TO PYTHON PATH:
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.append(PROJECT_ROOT)

import pandas as pd
from core.universe import get_universe
from core.data_feed import get_historical_ohlc
from core.risk_manager import load_settings

REPORT_PATH = os.path.join(PROJECT_ROOT, "data", "profitability_report.csv")


def compute_return(latest: float, past: float) -> Optional[float]:
    if latest is None or past is None or past == 0:
        return None
    return (latest - past) / past * 100.0


def classify_stock(day: Optional[float], week: Optional[float], month: Optional[float]) -> str:
    d = day if day is not None else 0.0
    w = week if week is not None else 0.0
    m = month if month is not None else 0.0

    if d > 0 and w > 0 and m > 0:
        return "Strong uptrend (D/W/M all positive)"
    if w > 0 and m > 0:
        return "Uptrend (W & M positive)"
    if m > 0 and w >= 0 and d <= 0:
        return "Pullback in uptrend"
    if d < 0 and w < 0 and m < 0:
        return "Consistent downtrend"
    if m < 0 and (d > 0 or w > 0):
        return "Short-term bounce in downtrend"
    return "Sideways / Choppy"


def scan_universe():
    settings = load_settings()
    universe = get_universe()

    if not universe:
        print("Universe is empty. Configure symbols in config/settings.yaml")
        return

    rows = []

    print(f"Scanning {len(universe)} symbols...")
    for symbol in universe:

        df = get_historical_ohlc(symbol, days=90, timeframe=settings["strategy"]["timeframe"])
        if df.empty or df.shape[0] < 25:
            print(f"Skipping {symbol}: not enough data.")
            continue

        df = df.sort_index()
        latest_close = df["close"].iloc[-1]

        day_ret = compute_return(latest_close, df["close"].iloc[-2]) if df.shape[0] >= 2 else None
        week_ret = compute_return(latest_close, df["close"].iloc[-6]) if df.shape[0] >= 6 else None
        month_ret = compute_return(latest_close, df["close"].iloc[-22]) if df.shape[0] >= 22 else None

        rating = classify_stock(day_ret, week_ret, month_ret)

        rows.append({
            "symbol": symbol,
            "latest_close": round(latest_close, 2),
            "day_change_pct": round(day_ret, 2) if day_ret is not None else None,
            "week_change_pct": round(week_ret, 2) if week_ret is not None else None,
            "month_change_pct": round(month_ret, 2) if month_ret is not None else None,
            "rating": rating
        })

    if not rows:
        print("No data collected.")
        return

    df_report = pd.DataFrame(rows)
    df_report.sort_values(
        by=["month_change_pct", "week_change_pct", "day_change_pct"],
        ascending=[False, False, False],
        inplace=True,
    )

    os.makedirs(os.path.dirname(REPORT_PATH), exist_ok=True)
    df_report.to_csv(REPORT_PATH, index=False)

    print("\n==== Profitability Report (Top 20 by Month % Change) ====\n")
    with pd.option_context("display.max_rows", 20, "display.width", 160):
        print(df_report.head(20))

    print(f"\nFull report saved to: {REPORT_PATH}")
    print("Columns: symbol, latest_close, day_change_pct, week_change_pct, month_change_pct, rating")


if __name__ == "__main__":
    print("Starting profitability scan at", datetime.now().isoformat())
    scan_universe()
