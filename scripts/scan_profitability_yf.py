import os
import sys
from datetime import datetime
from typing import Optional, Union

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.append(PROJECT_ROOT)

import pandas as pd
import yfinance as yf

from core.universe import get_universe
from core.risk_manager import load_settings

REPORT_PATH = os.path.join(PROJECT_ROOT, "data", "profitability_report_yf.csv")


def nse_to_yahoo(symbol: str) -> str:
    """
    Convert NSE:RELIANCE-EQ -> RELIANCE.NS for Yahoo Finance.
    """
    try:
        core = symbol.split(":")[1]  # RELIANCE-EQ
        base = core.split("-")[0]   # RELIANCE
        return base + ".NS"
    except Exception:
        return symbol  # fallback


NumberLike = Union[float, int, pd.Series, pd.Index]


def compute_return(latest: NumberLike, past: NumberLike) -> Optional[float]:
    if latest is None or past is None:
        return None

    try:
        latest_val = float(latest)
        past_val = float(past)
    except Exception:
        return None

    if past_val == 0:
        return None

    return (latest_val - past_val) / past_val * 100.0


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


def classify_sma_trend(price: float, sma20: float, sma50: float, sma200: float) -> str:
    """
    Simple SMA-stack classification for swing trend.
    """
    if price > sma20 > sma50 > sma200:
        return "Strong SMA uptrend (P>20>50>200)"
    if sma20 > sma50 > sma200 and price >= sma20:
        return "Healthy uptrend (20>50>200, P>=20)"
    if price >= sma50 > sma200 and sma20 >= sma50:
        return "Mild uptrend / consolidation"
    if price < sma20 < sma50 < sma200:
        return "Strong SMA downtrend (P<20<50<200)"
    return "Mixed / Range"


def compute_swing_score(
    month_ret: Optional[float],
    week_ret: Optional[float],
    sma_trend: str,
) -> float:
    """
    A simple numeric score to rank swing candidates.
    You can tune weights later.
    """
    m = month_ret if month_ret is not None else 0.0
    w = week_ret if week_ret is not None else 0.0

    score = m * 0.7 + w * 0.3  # bias more towards 1M performance

    if "Strong SMA uptrend" in sma_trend:
        score += 5.0
    elif "Healthy uptrend" in sma_trend:
        score += 3.0
    elif "Strong SMA downtrend" in sma_trend:
        score -= 5.0

    return round(score, 2)


def scan_universe_yf():
    settings = load_settings()
    universe = get_universe()

    if not universe:
        print("Universe is empty. Configure symbols in config/settings.yaml under 'universe.symbols'.")
        return

    rows = []

    print(f"Scanning {len(universe)} symbols via Yahoo Finance...")
    for symbol in universe:
        yf_symbol = nse_to_yahoo(symbol)
        print(f"  -> {symbol} (Yahoo: {yf_symbol})")

        # ~6 months of daily data
        df = yf.download(yf_symbol, period="6mo", interval="1d", progress=False)

        if df.empty or df.shape[0] < 60:
            print(f"     Skipping {symbol}: not enough data from Yahoo (need at least 60 bars).")
            continue

        df = df.dropna()
        if df.empty or "Close" not in df.columns:
            print(f"     Skipping {symbol}: missing Close data from Yahoo.")
            continue

        df = df.sort_index()

        # Compute SMAs
        df["SMA20"] = df["Close"].rolling(window=20).mean()
        df["SMA50"] = df["Close"].rolling(window=50).mean()
        df["SMA200"] = df["Close"].rolling(window=200).mean()

        latest_row = df.iloc[-1]
        latest_close = latest_row["Close"]
        sma20 = latest_row["SMA20"]
        sma50 = latest_row["SMA50"]
        sma200 = latest_row["SMA200"]

        # Need valid SMAs: if 200-day SMA is NaN (insufficient history), still allow, but mark trend mixed
        if pd.isna(sma20) or pd.isna(sma50) or pd.isna(sma200):
            sma_trend = "SMA data incomplete"
        else:
            sma_trend = classify_sma_trend(float(latest_close), float(sma20), float(sma50), float(sma200))

        # Returns
        day_ret = compute_return(latest_close, df["Close"].iloc[-2]) if df.shape[0] >= 2 else None
        week_ret = compute_return(latest_close, df["Close"].iloc[-6]) if df.shape[0] >= 6 else None
        month_ret = compute_return(latest_close, df["Close"].iloc[-22]) if df.shape[0] >= 22 else None

        rating = classify_stock(day_ret, week_ret, month_ret)
        swing_score = compute_swing_score(month_ret, week_ret, sma_trend)

        rows.append(
            {
                "symbol": symbol,
                "yf_symbol": yf_symbol,
                "latest_close": round(float(latest_close), 2),
                "day_change_pct": round(day_ret, 2) if day_ret is not None else None,
                "week_change_pct": round(week_ret, 2) if week_ret is not None else None,
                "month_change_pct": round(month_ret, 2) if month_ret is not None else None,
                "sma20": round(float(sma20), 2) if not pd.isna(sma20) else None,
                "sma50": round(float(sma50), 2) if not pd.isna(sma50) else None,
                "sma200": round(float(sma200), 2) if not pd.isna(sma200) else None,
                "sma_trend": sma_trend,
                "rating": rating,
                "swing_score": swing_score,
            }
        )

    if not rows:
        print("No data collected from Yahoo for any symbol.")
        return

    df_report = pd.DataFrame(rows)
    df_report.sort_values(
        by=["swing_score", "month_change_pct", "week_change_pct", "day_change_pct"],
        ascending=[False, False, False, False],
        inplace=True,
    )

    os.makedirs(os.path.dirname(REPORT_PATH), exist_ok=True)
    df_report.to_csv(REPORT_PATH, index=False)

    print("\n==== Swing Candidates (Top 20 by swing_score) ====\n")
    with pd.option_context("display.max_rows", 20, "display.width", 200, "display.max_columns", None):
        print(df_report.head(20))

    print(f"\nFull report saved to: {REPORT_PATH}")
    print("Columns: symbol, yf_symbol, latest_close, day_change_pct, week_change_pct, month_change_pct, "
          "sma20, sma50, sma200, sma_trend, rating, swing_score")


if __name__ == "__main__":
    print("Starting Yahoo-based profitability + SMA scan at", datetime.now().isoformat())
    scan_universe_yf()
