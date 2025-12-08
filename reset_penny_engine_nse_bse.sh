#!/usr/bin/env bash
set -euo pipefail

echo "==============================================================="
echo " Resetting Penny Engine (Scanner + Scheduler + Auto-Trader)"
echo "  - Uses NSE/BSE-backed Yahoo symbols (yf_symbol)"
echo "  - Respects fyers_symbol from fundamentals for auto-trading"
echo "==============================================================="

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

echo "[1/4] Ensuring directory structure ..."
mkdir -p scripts data

echo "[2/4] Rewriting scripts/penny_scanner.py ..."
cat << 'PYEOF' > scripts/penny_scanner.py
import os
import math
from dataclasses import dataclass
from datetime import datetime
from typing import Optional, Tuple, List

import pandas as pd
import numpy as np
import yfinance as yf


DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "data")
FUNDAMENTALS_CSV = os.path.join(DATA_DIR, "penny_fundamentals.csv")
SCAN_REPORT_CSV = os.path.join(DATA_DIR, "penny_scan_report.csv")


@dataclass
class TrendInfo:
    day_change_pct: Optional[float]
    week_change_pct: Optional[float]
    month_change_pct: Optional[float]
    ret_trend: str
    vol_annual_pct: Optional[float]


@dataclass
class SmaInfo:
    sma20: Optional[float]
    sma50: Optional[float]
    sma200: Optional[float]
    sma_trend: str


@dataclass
class Zones:
    buy_low: Optional[float]
    buy_high: Optional[float]
    stop_loss: Optional[float]
    target1: Optional[float]
    target2: Optional[float]


def _safe_pct_change(current: float, past: Optional[float]) -> Optional[float]:
    if past is None or past == 0 or current is None:
        return None
    return round((current - past) / past * 100.0, 2)


def _compute_trend_and_vol(hist: pd.DataFrame) -> TrendInfo:
    if hist.empty or "Close" not in hist.columns:
        return TrendInfo(None, None, None, "No data", None)

    hist = hist.copy()
    hist = hist.sort_index()
    close = hist["Close"].dropna()
    if close.empty:
        return TrendInfo(None, None, None, "No data", None)

    latest = float(close.iloc[-1])

    def get_past(days: int) -> Optional[float]:
        if len(close) < days + 1:
            return None
        return float(close.iloc[-1 - days])

    day_back = get_past(1)
    week_back = get_past(5)
    month_back = get_past(21)

    day_chg = _safe_pct_change(latest, day_back)
    week_chg = _safe_pct_change(latest, week_back)
    month_chg = _safe_pct_change(latest, month_back)

    daily_ret = close.pct_change().dropna()
    vol_annual = None
    if not daily_ret.empty:
        vol_annual = round(float(daily_ret.std() * math.sqrt(252) * 100.0), 2)

    positives = [x for x in [day_chg, week_chg, month_chg] if x is not None and x > 0]
    negatives = [x for x in [day_chg, week_chg, month_chg] if x is not None and x < 0]

    if len(positives) == 3:
        trend = "Strong uptrend (D/W/M all positive)"
    elif len(negatives) == 3:
        trend = "Consistent downtrend"
    elif (week_chg is not None and week_chg > 0) and (month_chg is not None and month_chg > 0):
        trend = "Uptrend (W & M positive)"
    elif (week_chg is not None and week_chg < 0) and (month_chg is not None and month_chg < 0):
        trend = "Downtrend (W & M negative)"
    else:
        trend = "Sideways / Choppy"

    return TrendInfo(day_chg, week_chg, month_chg, trend, vol_annual)


def _compute_sma_info(hist: pd.DataFrame) -> Tuple[float, SmaInfo]:
    if hist.empty or "Close" not in hist.columns:
        return float("nan"), SmaInfo(None, None, None, "No data")

    hist = hist.copy().sort_index()
    close = hist["Close"].dropna()
    if close.empty:
        return float("nan"), SmaInfo(None, None, None, "No data")

    latest = float(close.iloc[-1])

    sma20 = float(close.rolling(20).mean().iloc[-1]) if len(close) >= 20 else None
    sma50 = float(close.rolling(50).mean().iloc[-1]) if len(close) >= 50 else None
    sma200 = float(close.rolling(200).mean().iloc[-1]) if len(close) >= 200 else None

    trend = "SMA data incomplete"
    if sma20 and sma50 and sma200:
        if latest > sma20 > sma50 > sma200:
            trend = "Strong bullish alignment (20>50>200)"
        elif latest < sma20 < sma50 < sma200:
            trend = "Bearish alignment (20<50<200)"
        else:
            trend = "Mixed / sideways"

    return latest, SmaInfo(sma20, sma50, sma200, trend)


def _compute_zones(latest: float, hist: pd.DataFrame) -> Zones:
    if latest is None or math.isnan(latest):
        return Zones(None, None, None, None, None)

    recent = hist.tail(20)
    if "Low" in recent.columns and not recent.empty:
        swing_low = float(recent["Low"].min())
    else:
        swing_low = latest * 0.85

    if "High" in recent.columns and not recent.empty:
        swing_high = float(recent["High"].max())
    else:
        swing_high = latest * 1.05

    buy_low = round(max(swing_low, latest * 0.85), 2)
    buy_high = round(min(swing_high, latest * 0.99), 2)

    stop_loss = round(buy_low * 0.9, 2)
    target1 = round(latest * 1.1, 2)
    target2 = round(latest * 1.2, 2)

    return Zones(buy_low, buy_high, stop_loss, target1, target2)


def _compute_fundamental_score(row: pd.Series) -> float:
    score = 0.0

    roce = row.get("roce_pct", np.nan)
    if pd.notna(roce):
        score += min(max(roce, 0) * 0.8, 30)  # up to 30 pts

    pe = row.get("pe", np.nan)
    if pd.notna(pe):
        if 10 <= pe <= 25:
            score += 15
        elif 5 <= pe < 10 or 25 < pe <= 40:
            score += 8

    debt = row.get("debt_eq", np.nan)
    if pd.notna(debt):
        if debt <= 0.3:
            score += 15
        elif debt <= 0.8:
            score += 8

    qtr_profit = row.get("qtr_profit_var_pct", np.nan)
    if pd.notna(qtr_profit):
        if qtr_profit > 0:
            score += 10
        if qtr_profit > 20:
            score += 5

    qtr_sales = row.get("qtr_sales_var_pct", np.nan)
    if pd.notna(qtr_sales) and qtr_sales > 0:
        score += 5

    marcap = row.get("mar_cap_cr", np.nan)
    if pd.notna(marcap) and marcap >= 200:
        score += 5

    return round(score, 2)


def _risk_flag_from_vol(vol_annual_pct: Optional[float]) -> str:
    if vol_annual_pct is None:
        return "Unknown"
    if vol_annual_pct < 25:
        return "Low"
    if vol_annual_pct < 45:
        return "Medium"
    return "High"


def _fundamental_pass(row: pd.Series) -> bool:
    roce = row.get("roce_pct", np.nan)
    pe = row.get("pe", np.nan)
    debt = row.get("debt_eq", np.nan)
    profit_var = row.get("qtr_profit_var_pct", np.nan)
    marcap = row.get("mar_cap_cr", np.nan)

    if pd.isna(roce) or roce < 15:
        return False
    if pd.isna(debt) or debt > 1.0:
        return False
    if pd.notna(pe) and not (5 <= pe <= 80):
        return False
    if pd.notna(profit_var) and profit_var < -30:
        return False
    if pd.notna(marcap) and marcap < 100:
        return False

    return True


def scan_penny_universe() -> pd.DataFrame:
    os.makedirs(DATA_DIR, exist_ok=True)

    if not os.path.exists(FUNDAMENTALS_CSV):
        raise SystemExit(f"Fundamentals file not found: {FUNDAMENTALS_CSV}")

    print(f"Starting penny stock scan at {datetime.now().isoformat(timespec='seconds')}")
    df_f = pd.read_csv(FUNDAMENTALS_CSV)

    required_cols = [
        "symbol",
        "name",
        "cmp",
        "pe",
        "mar_cap_cr",
        "div_yld_pct",
        "np_qtr_cr",
        "qtr_profit_var_pct",
        "sales_qtr_cr",
        "qtr_sales_var_pct",
        "roce_pct",
        "debt_eq",
        "yf_symbol",
        "fyers_symbol",
    ]
    missing = [c for c in required_cols if c not in df_f.columns]
    if missing:
        print(f"[WARNING] Missing columns in fundamentals CSV: {missing}")

    # Ensure key columns exist
    for col in required_cols:
        if col not in df_f.columns:
            df_f[col] = np.nan

    df_f["fundamental_score"] = df_f.apply(_compute_fundamental_score, axis=1)
    df_f["fundamental_pass"] = df_f.apply(_fundamental_pass, axis=1)

    df_base = df_f[df_f["fundamental_pass"]].copy()
    print(f"Fundamental filter passed: {len(df_base)} stocks")

    results: List[dict] = []

    for _, row in df_base.iterrows():
        symbol = str(row["symbol"])
        name = str(row.get("name", symbol))
        yf_symbol = str(row.get("yf_symbol", "")).strip()

        print(f"\n--- Processing {name} ({yf_symbol or 'no yf_symbol'}) ---")

        if not yf_symbol or yf_symbol.lower() == "nan":
            print("  Skipping: yf_symbol missing.")
            continue

        try:
            hist = yf.download(yf_symbol, period="6mo", interval="1d", progress=False)
        except Exception as e:
            print(f"  ERROR: Failed to download history for {yf_symbol}: {e}")
            continue

        # NSE/BSE via Yahoo: guard against symbols where Yahoo returns no Close
        if hist is None or hist.empty or "Close" not in hist.columns:
            print(f"  WARNING: No usable price history for {yf_symbol}, skipping.")
            continue

        hist = hist.dropna(subset=["Close"])
        if hist.empty:
            print(f"  WARNING: All Close values NaN for {yf_symbol}, skipping.")
            continue

        latest_price, sma_info = _compute_sma_info(hist)
        trend_info = _compute_trend_and_vol(hist)
        zones = _compute_zones(latest_price, hist)

        risk_flag = _risk_flag_from_vol(trend_info.vol_annual_pct)

        technical_score = 0.0
        if sma_info.sma_trend.startswith("Strong bullish"):
            technical_score += 8
        elif "Mixed" in sma_info.sma_trend:
            technical_score += 3

        if trend_info.ret_trend.startswith("Strong uptrend"):
            technical_score += 7
        elif trend_info.ret_trend.startswith("Uptrend"):
            technical_score += 4
        elif trend_info.ret_trend.startswith("Downtrend"):
            technical_score -= 2
        elif trend_info.ret_trend.startswith("Consistent downtrend"):
            technical_score -= 4

        fundamental_score = float(row["fundamental_score"])
        total_score = round(fundamental_score + technical_score, 2)

        results.append(
            {
                "symbol": symbol,
                "yf_symbol": yf_symbol,
                "fyers_symbol": row.get("fyers_symbol", ""),
                "name": name,
                "cmp": latest_price,
                "pe": row.get("pe", np.nan),
                "roce_pct": row.get("roce_pct", np.nan),
                "debt_eq": row.get("debt_eq", np.nan),
                "qtr_profit_var_pct": row.get("qtr_profit_var_pct", np.nan),
                "qtr_sales_var_pct": row.get("qtr_sales_var_pct", np.nan),
                "mar_cap_cr": row.get("mar_cap_cr", np.nan),
                "div_yld_pct": row.get("div_yld_pct", np.nan),
                "fundamental_score": fundamental_score,
                "technical_score": round(technical_score, 2),
                "total_score": total_score,
                "risk_flag": risk_flag,
                "day_change_pct": trend_info.day_change_pct,
                "week_change_pct": trend_info.week_change_pct,
                "month_change_pct": trend_info.month_change_pct,
                "ret_trend": trend_info.ret_trend,
                "vol_annual_pct": trend_info.vol_annual_pct,
                "sma20": sma_info.sma20,
                "sma50": sma_info.sma50,
                "sma200": sma_info.sma200,
                "sma_trend": sma_info.sma_trend,
                "buy_zone_low": zones.buy_low,
                "buy_zone_high": zones.buy_high,
                "stop_loss": zones.stop_loss,
                "target1": zones.target1,
                "target2": zones.target2,
            }
        )

    if not results:
        print("No candidates after technical checks.")
        return pd.DataFrame()

    df_res = pd.DataFrame(results)
    df_res = df_res.sort_values("total_score", ascending=False).reset_index(drop=True)

    os.makedirs(DATA_DIR, exist_ok=True)
    df_res.to_csv(SCAN_REPORT_CSV, index=False)
    print(f"\n==== Penny Stock Scan Complete ====\n")
    print(df_res.head(10).to_string(index=False))
    print(f"\nFull report saved to: {SCAN_REPORT_CSV}")

    return df_res


if __name__ == "__main__":
    scan_penny_universe()
PYEOF

echo "[3/4] Rewriting scripts/penny_reco_scheduler.py ..."
cat << 'PYEOF' > scripts/penny_reco_scheduler.py
import os
from datetime import datetime

import pandas as pd
from apscheduler.schedulers.blocking import BlockingScheduler

from penny_scanner import scan_penny_universe, DATA_DIR, SCAN_REPORT_CSV  # type: ignore


RECO_CSV = os.path.join(DATA_DIR, "penny_recommendations.csv")


def _alloc_recos(
    df_scan: pd.DataFrame,
    total_capital: float,
    max_risk_pct: float,
) -> pd.DataFrame:
    if df_scan.empty:
        return df_scan

    df = df_scan.copy()

    df = df[df["risk_flag"] != "High"]
    df = df[df["total_score"] >= df["total_score"].quantile(0.4)]
    df = df.sort_values("total_score", ascending=False).reset_index(drop=True)

    if df.empty:
        return df

    max_risk_per_trade = total_capital * max_risk_pct

    recs = []
    for _, row in df.iterrows():
        price = float(row["cmp"])
        stop = float(row["stop_loss"]) if row.get("stop_loss") and not pd.isna(row.get("stop_loss")) else price * 0.9
        risk_per_share = max(price - stop, 0.01)

        qty = int(max_risk_per_trade // risk_per_share)
        if qty <= 0:
            continue

        capital_required = qty * price
        risk_on_trade = qty * risk_per_share
        rr_to_target2 = None
        if row.get("target2") and not pd.isna(row.get("target2")):
            rr_to_target2 = round((float(row["target2"]) - price) / risk_per_share, 2)

        recs.append(
            {
                "symbol": row["symbol"],
                "yf_symbol": row["yf_symbol"],
                "fyers_symbol": row.get("fyers_symbol", ""),
                "name": row["name"],
                "cmp": price,
                "entry_low": row.get("buy_zone_low"),
                "entry_high": row.get("buy_zone_high"),
                "recommended_entry": price,
                "stop_loss": stop,
                "target1": row.get("target1"),
                "target2": row.get("target2"),
                "risk_per_share": round(risk_per_share, 2),
                "qty": qty,
                "capital_required": round(capital_required, 2),
                "risk_on_trade": round(risk_on_trade, 2),
                "rr_to_target2": rr_to_target2,
                "fundamental_score": row.get("fundamental_score"),
                "technical_score": row.get("technical_score"),
                "total_score": row.get("total_score"),
                "risk_flag": row.get("risk_flag"),
                "ret_trend": row.get("ret_trend"),
            }
        )

    if not recs:
        return pd.DataFrame()

    df_reco = pd.DataFrame(recs)
    df_reco = df_reco.sort_values("total_score", ascending=False).reset_index(drop=True)
    return df_reco


def generate_recommendations() -> None:
    print(f"[{datetime.now().isoformat(timespec='seconds')}] === Running penny scanner ===")
    df_scan = scan_penny_universe()
    if df_scan.empty:
        print("No scan results, skipping recommendations.")
        return

    total_capital = float(os.getenv("PENNY_TEST_CAPITAL", "500"))
    max_risk_pct = float(os.getenv("PENNY_MAX_RISK_PCT", "0.05"))

    df_reco = _alloc_recos(df_scan, total_capital, max_risk_pct)
    if df_reco.empty:
        print("No recommendations produced after risk/capital filters.")
        return

    os.makedirs(DATA_DIR, exist_ok=True)
    df_reco.to_csv(RECO_CSV, index=False)
    print(f"[{datetime.now().isoformat(timespec='seconds')}] Saved {len(df_reco)} recommendation(s) to {RECO_CSV}")
    print("Top recommendations:")
    print(df_reco.head(10).to_string(index=False))


def main() -> None:
    mode = os.getenv("PENNY_RECO_MODE", "once").lower()
    if mode == "once":
        generate_recommendations()
        return

    sched = BlockingScheduler(timezone="Asia/Kolkata")

    sched.add_job(
        generate_recommendations,
        "cron",
        hour=9,
        minute=25,
        id="penny_reco_daily",
        name="Daily penny recommendations",
        replace_existing=True,
    )

    print(f"[{datetime.now().isoformat(timespec='seconds')}] Starting penny recommendation scheduler (daily 09:25 IST)...")
    sched.start()


if __name__ == "__main__":
    main()
PYEOF

echo "[4/4] Rewriting scripts/penny_auto_trader.py ..."
cat << 'PYEOF' > scripts/penny_auto_trader.py
import os
import time
from datetime import datetime
from typing import Set

import pandas as pd
from fyers_apiv3 import fyersModel


DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "data")
RECO_CSV = os.path.join(DATA_DIR, "penny_recommendations.csv")


def _load_recommendations() -> pd.DataFrame:
    if not os.path.exists(RECO_CSV):
        print(f"[{datetime.now().isoformat(timespec='seconds')}] No recommendations file found at {RECO_CSV}")
        return pd.DataFrame()

    df = pd.read_csv(RECO_CSV)
    if df.empty:
        print(f"[{datetime.now().isoformat(timespec='seconds')}] Recommendations file is empty.")
        return df

    return df


def _init_fyers() -> fyersModel.FyersModel:
    client_id = os.getenv("FYERS_CLIENT_ID")
    token = os.getenv("FYERS_ACCESS_TOKEN")

    if not client_id or not token:
        raise SystemExit("FYERS_CLIENT_ID or FYERS_ACCESS_TOKEN not set in environment.")

    print(f"[{datetime.now().isoformat(timespec='seconds')}] Initializing FYERS client...")
    return fyersModel.FyersModel(client_id=client_id, token=token)


def _place_buy(f: fyersModel.FyersModel, fy_symbol: str, name: str, qty: int) -> None:
    print(f"[{datetime.now().isoformat(timespec='seconds')}] Placing BUY order for {name} ({fy_symbol}), qty={qty}")
    order = {
        "symbol": fy_symbol,
        "qty": int(qty),
        "type": 2,  # MARKET
        "side": 1,  # BUY
        "productType": "CNC",
        "limitPrice": 0,
        "stopPrice": 0,
        "validity": "DAY",
        "disclosedQty": 0,
        "offlineOrder": False,
        "segment": "EQUITY",
    }
    try:
        resp = f.place_order(order)
        print(f"[{datetime.now().isoformat(timespec='seconds')}] BUY response for {fy_symbol}: {resp}")
        if not isinstance(resp, dict) or resp.get("s") != "ok":
            print(f"[{datetime.now().isoformat(timespec='seconds')}] ERROR placing BUY for {fy_symbol}: {resp}")
    except Exception as e:
        print(f"[{datetime.now().isoformat(timespec='seconds')}] EXCEPTION placing BUY for {fy_symbol}: {e}")


def run_auto_trader(poll_interval_sec: int = 60) -> None:
    fy = _init_fyers()
    placed: Set[str] = set()

    print(f"[{datetime.now().isoformat(timespec='seconds')}] Starting penny auto-trader loop...")
    while True:
        df = _load_recommendations()
        if not df.empty:
            for _, row in df.iterrows():
                symbol = str(row.get("symbol"))
                name = str(row.get("name", symbol))
                fyers_symbol = str(row.get("fyers_symbol", "")).strip()
                qty = int(row.get("qty", 0))

                if symbol in placed:
                    continue

                if not fyers_symbol:
                    print(f"[{datetime.now().isoformat(timespec='seconds')}] WARNING: No fyers_symbol for {symbol}, skipping.")
                    continue

                if qty <= 0:
                    print(f"[{datetime.now().isoformat(timespec='seconds')}] WARNING: qty<=0 for {symbol}, skipping.")
                    continue

                _place_buy(fy, fyers_symbol, name, qty)
                placed.add(symbol)

        print(f"[{datetime.now().isoformat(timespec='seconds')}] Cycle complete. Sleeping {poll_interval_sec} sec.")
        time.sleep(poll_interval_sec)


if __name__ == "__main__":
    interval = int(os.getenv("PENNY_TRADER_POLL_SEC", "60"))
    run_auto_trader(poll_interval_sec=interval)
PYEOF

chmod +x reset_penny_engine_nse_bse.sh

echo
echo "==============================================================="
echo " Files written:"
echo "  - scripts/penny_scanner.py"
echo "  - scripts/penny_reco_scheduler.py"
echo "  - scripts/penny_auto_trader.py"
echo
echo "Next steps:"
echo "  1) Rebuild images so code is baked into all services:"
echo "       docker compose build"
echo
echo "  2) Quick manual test (inside Docker):"
echo "       docker compose run --rm fyers-swing-bot python scripts/penny_scanner.py"
echo "       docker compose run --rm fyers-swing-bot python scripts/penny_reco_scheduler.py"
echo "       docker compose run --rm fyers-swing-bot python scripts/penny_auto_trader.py"
echo "     (Ctrl+C to stop the last one)"
echo
echo "  3) For daily automation via docker-compose services:"
echo "       docker compose up -d penny-reco penny-trader"
echo "       docker logs -f fyers-penny-reco"
echo "       docker logs -f fyers-penny-trader"
echo "==============================================================="
