#!/usr/bin/env bash
set -euo pipefail

echo "==============================================================="
echo " Updating penny scanner, recommender & auto-trader"
echo " (using explicit FYERS symbols)"
echo "==============================================================="

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

echo
echo "[1/4] Writing scripts/penny_scanner.py ..."
cat << 'EOF' > scripts/penny_scanner.py
import os
import math
import logging
from datetime import datetime

import pandas as pd
import numpy as np
import yfinance as yf

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(BASE_DIR, "data")

FUNDAMENTALS_PATH = os.path.join(DATA_DIR, "penny_fundamentals.csv")
REPORT_PATH = os.path.join(DATA_DIR, "penny_scan_report.csv")

os.makedirs(DATA_DIR, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger("penny_scanner")


def _safe_float(val):
    try:
        if pd.isna(val):
            return None
        return float(val)
    except Exception:
        return None


def compute_fundamental_score(row: pd.Series) -> float:
    """Score fundamentals based on PE, ROCE, Debt/Equity and growth."""
    pe = _safe_float(row.get("pe"))
    roce = _safe_float(row.get("roce_pct"))
    debt = _safe_float(row.get("debt_eq"))
    qtr_profit = _safe_float(row.get("qtr_profit_var_pct"))
    qtr_sales = _safe_float(row.get("qtr_sales_var_pct"))

    score = 0.0

    # PE band
    if pe is None or pe <= 0:
        score -= 2
    elif 5 <= pe <= 40:
        score += 4
    elif 40 < pe <= 60:
        score += 2
    elif pe > 80:
        score -= 3

    # ROCE
    if roce is None:
        score -= 1
    elif roce >= 25:
        score += 4
    elif roce >= 18:
        score += 3
    elif roce >= 12:
        score += 1
    else:
        score -= 2

    # Debt / Equity
    if debt is None:
        score -= 1
    elif debt <= 0.3:
        score += 3
    elif debt <= 0.7:
        score += 1
    else:
        score -= 2

    # Growth
    if qtr_profit is not None and qtr_profit > 0:
        score += 1
    if qtr_sales is not None and qtr_sales > 0:
        score += 1

    return round(score, 2)


def compute_return(latest: float, past: float) -> float | None:
    if latest is None or past is None or past == 0:
        return None
    return round((latest / past - 1.0) * 100.0, 2)


def classify_return_trend(day, week, month) -> str:
    def is_pos(x):
        return x is not None and x > 0
    def is_neg(x):
        return x is not None and x < 0

    if is_pos(day) and is_pos(week) and is_pos(month):
        return "Strong uptrend (D/W/M all positive)"
    if is_pos(week) and is_pos(month):
        return "Uptrend (W & M positive)"
    if is_neg(day) and is_neg(week) and is_neg(month):
        return "Consistent downtrend"
    if is_pos(day) and (is_neg(week) or is_neg(month)):
        return "Short-term bounce in downtrend"
    return "Sideways / Choppy"


def compute_vol_annual(df: pd.DataFrame) -> float | None:
    if df is None or df.empty or "Close" not in df.columns:
        return None
    daily_ret = df["Close"].pct_change().dropna()
    if daily_ret.empty:
        return None
    vol = daily_ret.std() * math.sqrt(252) * 100.0
    return round(float(vol), 2)


def classify_risk_flag(vol_annual: float | None) -> str:
    if vol_annual is None:
        return "Unknown"
    if vol_annual < 25:
        return "Low"
    if vol_annual < 45:
        return "Medium"
    return "High"


def classify_sma_trend(sma20, sma50, sma200) -> str:
    if sma20 is None or sma50 is None or sma200 is None:
        return "SMA data incomplete"
    if sma20 > sma50 > sma200:
        return "Bullish (20 > 50 > 200)"
    if sma20 < sma50 < sma200:
        return "Bearish (20 < 50 < 200)"
    return "Mixed / Sideways"


def compute_buy_zone_and_targets(df: pd.DataFrame, latest_close: float):
    """Define swing buy zone and SL/targets using last 20 candles."""
    if df is None or df.empty or "Low" not in df.columns or "High" not in df.columns:
        return None, None, None, None, None
    last_20 = df.tail(20)
    if last_20.shape[0] < 5:
        return None, None, None, None, None

    recent_low = float(last_20["Low"].min())
    recent_high = float(last_20["High"].max())

    buy_zone_low = round(recent_low * 1.02, 2)
    buy_zone_high = round(min(recent_high * 0.98, latest_close * 1.03), 2)

    stop_loss = round(recent_low * 0.97, 2)

    target1 = round(latest_close * 1.10, 2)
    target2 = round(latest_close * 1.20, 2)

    return buy_zone_low, buy_zone_high, stop_loss, target1, target2


def load_fundamentals() -> pd.DataFrame:
    if not os.path.exists(FUNDAMENTALS_PATH):
        raise FileNotFoundError(f"Fundamentals file not found: {FUNDAMENTALS_PATH}")

    df = pd.read_csv(FUNDAMENTALS_PATH)

    expected_cols = [
        "name", "cmp", "pe", "mar_cap_cr", "div_yld_pct",
        "np_qtr_cr", "qtr_profit_var_pct", "sales_qtr_cr",
        "qtr_sales_var_pct", "roce_pct", "debt_eq",
        "yf_symbol", "fyers_symbol"
    ]
    missing = [c for c in expected_cols if c not in df.columns]
    if missing:
        logger.warning("Missing columns in fundamentals CSV: %s", missing)

    # Ensure helper columns exist
    for col in ["yf_symbol", "fyers_symbol"]:
        if col not in df.columns:
            df[col] = np.nan

    return df


def scan_penny_universe() -> pd.DataFrame:
    logger.info("Starting penny stock scan at %s", datetime.now().isoformat())
    df = load_fundamentals()
    logger.info("Loaded fundamentals for %d stocks from %s", df.shape[0], FUNDAMENTALS_PATH)

    # Basic penny + quality filters
    df["fundamental_score"] = df.apply(compute_fundamental_score, axis=1)

    def is_good(row):
        cmp_ = _safe_float(row.get("cmp"))
        roce = _safe_float(row.get("roce_pct"))
        debt = _safe_float(row.get("debt_eq"))
        score = _safe_float(row.get("fundamental_score"))

        if cmp_ is None or cmp_ <= 0 or cmp_ > 100:
            return False
        if roce is None or roce < 15:
            return False
        if debt is None or debt > 1.5:
            return False
        if score is None or score < 8:
            return False
        return True

    df_filt = df[df.apply(is_good, axis=1)].copy()
    logger.info("Fundamental filter passed: %d stocks", df_filt.shape[0])

    if df_filt.empty:
        logger.warning("No fundamentally strong penny stocks found with current criteria.")
        # Still save an empty report
        empty = pd.DataFrame(
            columns=[
                "symbol", "yf_symbol", "fyers_symbol", "name", "cmp",
                "pe", "roce_pct", "debt_eq", "qtr_profit_var_pct",
                "qtr_sales_var_pct", "fundamental_score",
                "latest_close", "day_change_pct", "week_change_pct", "month_change_pct",
                "ret_trend", "sma20", "sma50", "sma200", "sma_trend",
                "vol_annual_pct", "risk_flag", "technical_score", "total_score",
                "buy_zone_low", "buy_zone_high", "stop_loss", "target1", "target2"
            ]
        )
        empty.to_csv(REPORT_PATH, index=False)
        return empty

    rows_out = []

    for _, row in df_filt.iterrows():
        name = row.get("name")
        yf_symbol = row.get("yf_symbol")
        fyers_symbol = row.get("fyers_symbol")
        symbol = str(row.get("symbol")) if "symbol" in row else (name or "")

        logger.info("--- Processing %s (%s) ---", name, yf_symbol)

        if not isinstance(yf_symbol, str) or yf_symbol.strip() == "":
            logger.info("  Skipping: yf_symbol missing.")
            continue

        try:
            df_hist = yf.download(yf_symbol, period="6mo", interval="1d", progress=False)
        except Exception as e:
            logger.error("  Error downloading %s from Yahoo: %s", yf_symbol, e)
            continue

        if df_hist is None or df_hist.empty:
            logger.info("  Skipping: no price history from Yahoo for %s", yf_symbol)
            continue

        df_hist = df_hist.dropna(subset=["Close"])
        if df_hist.shape[0] < 5:
            logger.info("  Skipping: not enough candles for %s", yf_symbol)
            continue

        latest_close = float(df_hist["Close"].iloc[-1])

        day_change_pct = compute_return(latest_close, float(df_hist["Close"].iloc[-2])) if df_hist.shape[0] >= 2 else None
        week_change_pct = compute_return(latest_close, float(df_hist["Close"].iloc[-6])) if df_hist.shape[0] >= 6 else None
        month_change_pct = compute_return(latest_close, float(df_hist["Close"].iloc[-21])) if df_hist.shape[0] >= 21 else None

        ret_trend = classify_return_trend(day_change_pct, week_change_pct, month_change_pct)

        # SMAs
        sma20 = float(df_hist["Close"].rolling(20).mean().iloc[-1]) if df_hist.shape[0] >= 20 else None
        sma50 = float(df_hist["Close"].rolling(50).mean().iloc[-1]) if df_hist.shape[0] >= 50 else None
        sma200 = float(df_hist["Close"].rolling(200).mean().iloc[-1]) if df_hist.shape[0] >= 200 else None
        sma_trend = classify_sma_trend(sma20, sma50, sma200)

        vol_annual_pct = compute_vol_annual(df_hist)
        risk_flag = classify_risk_flag(vol_annual_pct)

        # Technical score
        technical_score = 0.0
        if "Strong uptrend" in ret_trend:
            technical_score += 4
        elif "Uptrend" in ret_trend:
            technical_score += 3
        elif "Consistent downtrend" in ret_trend:
            technical_score -= 3
        elif "Short-term bounce" in ret_trend:
            technical_score -= 1

        if "Bullish" in sma_trend:
            technical_score += 3
        elif "Bearish" in sma_trend:
            technical_score -= 2

        if vol_annual_pct is not None:
            if vol_annual_pct < 30:
                technical_score += 1
            elif vol_annual_pct > 60:
                technical_score -= 1

        buy_zone_low, buy_zone_high, stop_loss, target1, target2 = compute_buy_zone_and_targets(df_hist, latest_close)

        total_score = round(float(row["fundamental_score"]) + technical_score, 2)

        rows_out.append(
            {
                "symbol": symbol,
                "yf_symbol": yf_symbol,
                "fyers_symbol": fyers_symbol,
                "name": name,
                "cmp": row.get("cmp"),
                "pe": row.get("pe"),
                "roce_pct": row.get("roce_pct"),
                "debt_eq": row.get("debt_eq"),
                "qtr_profit_var_pct": row.get("qtr_profit_var_pct"),
                "qtr_sales_var_pct": row.get("qtr_sales_var_pct"),
                "fundamental_score": row.get("fundamental_score"),
                "latest_close": latest_close,
                "day_change_pct": day_change_pct,
                "week_change_pct": week_change_pct,
                "month_change_pct": month_change_pct,
                "ret_trend": ret_trend,
                "sma20": sma20,
                "sma50": sma50,
                "sma200": sma200,
                "sma_trend": sma_trend,
                "vol_annual_pct": vol_annual_pct,
                "risk_flag": risk_flag,
                "technical_score": round(technical_score, 2),
                "total_score": total_score,
                "buy_zone_low": buy_zone_low,
                "buy_zone_high": buy_zone_high,
                "stop_loss": stop_loss,
                "target1": target1,
                "target2": target2,
            }
        )

    if not rows_out:
        logger.warning("No candidates after technical checks.")
        empty = pd.DataFrame(
            columns=[
                "symbol", "yf_symbol", "fyers_symbol", "name", "cmp",
                "pe", "roce_pct", "debt_eq", "qtr_profit_var_pct",
                "qtr_sales_var_pct", "fundamental_score",
                "latest_close", "day_change_pct", "week_change_pct", "month_change_pct",
                "ret_trend", "sma20", "sma50", "sma200", "sma_trend",
                "vol_annual_pct", "risk_flag", "technical_score", "total_score",
                "buy_zone_low", "buy_zone_high", "stop_loss", "target1", "target2"
            ]
        )
        empty.to_csv(REPORT_PATH, index=False)
        return empty

    df_report = pd.DataFrame(rows_out)
    df_report = df_report.sort_values(by="total_score", ascending=False).reset_index(drop=True)
    df_report.to_csv(REPORT_PATH, index=False)

    logger.info("Penny stock scan complete. Saved report to %s", REPORT_PATH)

    # Short console summary
    with pd.option_context("display.max_rows", 20, "display.width", 180, "display.max_columns", None):
        print("\n==== Penny Scan (Top 10 by total_score) ====\n")
        print(df_report.head(10)[[
            "symbol", "yf_symbol", "fyers_symbol", "latest_close",
            "day_change_pct", "week_change_pct", "month_change_pct",
            "ret_trend", "sma_trend", "vol_annual_pct",
            "fundamental_score", "technical_score", "total_score", "risk_flag"
        ]])

    return df_report


if __name__ == "__main__":
    scan_penny_universe()
EOF

echo "[2/4] Writing scripts/penny_reco_scheduler.py ..."
cat << 'EOF' > scripts/penny_reco_scheduler.py
import os
import logging
from datetime import datetime

import pandas as pd
from apscheduler.schedulers.blocking import BlockingScheduler

from penny_scanner import scan_penny_universe

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(BASE_DIR, "data")
RECO_PATH = os.path.join(DATA_DIR, "penny_recommendations.csv")

os.makedirs(DATA_DIR, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger("penny_reco")


def generate_recommendations():
    logger.info("=== Running penny scanner at %s ===", datetime.now().isoformat())
    df_scan = scan_penny_universe()

    if df_scan is None or df_scan.empty:
        logger.warning("No scan results, skipping recommendations.")
        return

    total_capital = float(os.getenv("PENNY_TEST_CAPITAL", "500"))
    max_risk_pct = float(os.getenv("PENNY_MAX_RISK_PCT", "0.05"))
    max_risk_per_trade = total_capital * max_risk_pct

    logger.info(
        "Using total_capital=%.2f, max_risk_pct=%.2f, max_risk_per_trade=%.2f",
        total_capital, max_risk_pct, max_risk_per_trade
    )

    # Filter to attractive, tradeable names
    df = df_scan.copy()
    df = df[
        (df["total_score"] >= 12) &
        (df["risk_flag"].isin(["Low", "Medium"])) &
        (df["buy_zone_low"].notna()) &
        (df["buy_zone_high"].notna()) &
        (df["stop_loss"].notna()) &
        (df["fyers_symbol"].notna()) &
        (df["fyers_symbol"] != "")
    ].copy()

    if df.empty:
        logger.warning("No candidates after recommendation filters.")
        return

    df = df.sort_values(by="total_score", ascending=False).reset_index(drop=True)

    rec_rows = []
    for _, row in df.iterrows():
        symbol = row["symbol"]
        name = row.get("name", symbol)
        fyers_symbol = row.get("fyers_symbol")
        yf_symbol = row.get("yf_symbol")

        latest = float(row["latest_close"])
        buy_low = float(row["buy_zone_low"])
        buy_high = float(row["buy_zone_high"])
        stop_loss = float(row["stop_loss"])
        target1 = float(row["target1"])
        target2 = float(row["target2"])

        # Use mid of buy zone as recommended entry
        recommended_entry = round((buy_low + buy_high) / 2.0, 2)

        risk_per_share = round(recommended_entry - stop_loss, 2)
        if risk_per_share <= 0:
            logger.info("Skipping %s: non-positive risk_per_share.", symbol)
            continue

        qty = int(max_risk_per_trade // risk_per_share)
        if qty <= 0:
            logger.info("Skipping %s: qty computed as 0 for risk %.2f.", symbol, risk_per_share)
            continue

        capital_required = round(qty * recommended_entry, 2)
        if capital_required > total_capital:
            logger.info(
                "Skipping %s: capital_required %.2f exceeds total_capital %.2f",
                symbol, capital_required, total_capital
            )
            continue

        rr_to_target2 = round((target2 - recommended_entry) / risk_per_share, 2)

        rec_rows.append(
            {
                "symbol": symbol,
                "yf_symbol": yf_symbol,
                "fyers_symbol": fyers_symbol,
                "name": name,
                "cmp": latest,
                "entry_low": buy_low,
                "entry_high": buy_high,
                "recommended_entry": recommended_entry,
                "stop_loss": stop_loss,
                "target1": target1,
                "target2": target2,
                "risk_per_share": risk_per_share,
                "qty": qty,
                "capital_required": capital_required,
                "risk_on_trade": round(qty * risk_per_share, 2),
                "rr_to_target2": rr_to_target2,
                "fundamental_score": row["fundamental_score"],
                "technical_score": row["technical_score"],
                "total_score": row["total_score"],
                "risk_flag": row["risk_flag"],
                "ret_trend": row["ret_trend"],
            }
        )

    if not rec_rows:
        logger.warning("No final recommendations after capital / risk checks.")
        return

    df_reco = pd.DataFrame(rec_rows)
    df_reco.to_csv(RECO_PATH, index=False)

    logger.info("Saved %d recommendation(s) to %s", df_reco.shape[0], RECO_PATH)
    logger.info("Top recommendations:")
    with pd.option_context("display.max_rows", 20, "display.width", 200, "display.max_columns", None):
        print(df_reco.head(10))

    return df_reco


def main():
    logger.info("Starting penny recommendation scheduler...")
    scheduler = BlockingScheduler(timezone="Asia/Kolkata")

    # Run once at startup
    generate_recommendations()

    # Then daily on market days: e.g. 09:20 IST (before market opens)
    scheduler.add_job(
        generate_recommendations,
        trigger="cron",
        day_of_week="mon-fri",
        hour=9,
        minute=20,
        id="daily_penny_reco"
    )

    logger.info("Scheduler started.")
    scheduler.start()


if __name__ == "__main__":
    main()
EOF

echo "[3/4] Writing scripts/penny_auto_trader.py ..."
cat << 'EOF' > scripts/penny_auto_trader.py
import os
import json
import time
import logging
from datetime import datetime

import pandas as pd
from fyers_apiv3 import fyersModel


BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(BASE_DIR, "data")
RECO_PATH = os.path.join(DATA_DIR, "penny_recommendations.csv")
OPEN_POS_PATH = os.path.join(DATA_DIR, "penny_open_positions.json")

os.makedirs(DATA_DIR, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger("penny_auto_trader")


def load_open_positions() -> dict:
    if not os.path.exists(OPEN_POS_PATH):
        return {}
    try:
        with open(OPEN_POS_PATH, "r") as f:
            return json.load(f)
    except Exception:
        return {}


def save_open_positions(positions: dict):
    with open(OPEN_POS_PATH, "w") as f:
        json.dump(positions, f, indent=2)


def load_recommendations() -> pd.DataFrame:
    if not os.path.exists(RECO_PATH):
        logger.info("Recommendations file not found: %s", RECO_PATH)
        return pd.DataFrame()
    try:
        df = pd.read_csv(RECO_PATH)
    except Exception as e:
        logger.error("Failed to read recommendations: %s", e)
        return pd.DataFrame()
    return df


def init_fyers_client():
    client_id = os.getenv("FYERS_CLIENT_ID")
    token = os.getenv("FYERS_ACCESS_TOKEN")

    if not client_id or not token:
        raise RuntimeError("FYERS_CLIENT_ID or FYERS_ACCESS_TOKEN missing in environment.")

    logger.info("Initializing FYERS client for auto-trading...")
    f = fyersModel.FyersModel(client_id=client_id, token=token, is_async=False, log_path="")
    return f


def place_buy_order(fyers, row, open_positions):
    symbol = row["symbol"]
    name = row.get("name", symbol)
    fyers_symbol = row.get("fyers_symbol")

    if not isinstance(fyers_symbol, str) or not fyers_symbol.strip():
        logger.error("No fyers_symbol for %s, skipping auto-trade.", symbol)
        return

    key = fyers_symbol
    if key in open_positions and open_positions[key].get("status") == "OPEN":
        logger.info("Position already OPEN for %s (%s), skipping.", symbol, fyers_symbol)
        return

    qty = int(row.get("qty", 0))
    if qty <= 0:
        logger.info("Qty <= 0 for %s, skipping.", symbol)
        return

    entry_price = float(row.get("recommended_entry"))
    stop_loss = float(row.get("stop_loss"))
    target1 = float(row.get("target1"))
    target2 = float(row.get("target2"))

    logger.info("Placing BUY order for %s (%s), qty=%d", name, fyers_symbol, qty)

    order_payload = {
        "symbol": fyers_symbol,
        "qty": qty,
        "type": 2,              # 2 = LIMIT
        "side": 1,              # 1 = BUY
        "productType": "CNC",
        "limitPrice": entry_price,
        "validity": "DAY",
        "disclosedQty": 0,
        "offlineOrder": False,
        "stopLoss": 0,
        "takeProfit": 0,
    }

    resp = fyers.place_order(data=order_payload)
    logger.info("BUY response for %s: %s", fyers_symbol, resp)

    if isinstance(resp, dict) and resp.get("s") == "ok":
        order_id = resp.get("id") or resp.get("order_id")
        open_positions[key] = {
            "symbol": symbol,
            "name": name,
            "fyers_symbol": fyers_symbol,
            "qty": qty,
            "entry_price": entry_price,
            "stop_loss": stop_loss,
            "target1": target1,
            "target2": target2,
            "opened_at": datetime.now().isoformat(),
            "order_id": order_id,
            "status": "OPEN",
        }
        save_open_positions(open_positions)
        logger.info("Recorded OPEN position for %s (%s).", symbol, fyers_symbol)
    else:
        logger.error("BUY order failed for %s (%s): %s", name, fyers_symbol, resp)


def main_loop():
    logger.info("Starting penny auto-trader (FULL AUTO, swing to T2)...")
    fyers = init_fyers_client()

    poll_sec = int(os.getenv("PENNY_TRADE_POLL_SEC", "60"))

    while True:
        try:
            df_reco = load_recommendations()
            if df_reco.empty:
                logger.info("No recommendations available. Sleeping %d sec.", poll_sec)
                time.sleep(poll_sec)
                continue

            open_positions = load_open_positions()

            for _, row in df_reco.iterrows():
                risk_flag = row.get("risk_flag", "")
                if risk_flag == "High":
                    logger.info("Skipping %s due to High risk_flag.", row.get("symbol"))
                    continue

                place_buy_order(fyers, row, open_positions)

            logger.info("Cycle complete. Sleeping %d sec.", poll_sec)
            time.sleep(poll_sec)

        except Exception as e:
            logger.exception("Error in auto-trader loop: %s", e)
            time.sleep(poll_sec)


if __name__ == "__main__":
    main_loop()
EOF

echo "[4/4] Reminder about fundamentals CSV ..."
echo
echo "IMPORTANT:"
echo "  - Ensure data/penny_fundamentals.csv has a column named: fyers_symbol"
echo "  - For each stock you want the bot to AUTO-TRADE, fill the correct FYERS symbol"
echo "    Example: FCL.NS -> fyers_symbol = NSE:FCL-EQ"
echo "             MCLOUD.NS -> fyers_symbol = NSE:MCLOUD-EQ"
echo "             MOREPENLAB.NS -> fyers_symbol = NSE:MOREPENLAB-EQ"
echo "  - Leave fyers_symbol EMPTY for stocks that FYERS rejects (e.g. TUNWAL if invalid)."

echo
echo "Next steps:"
echo "  1) Manually update data/penny_fundamentals.csv with fyers_symbol for valid stocks."
echo "  2) Rebuild images:    docker compose build"
echo "  3) Restart services:  docker compose up -d penny-reco penny-trader"
echo "  4) Watch logs:        docker logs -f fyers-penny-trader"
echo
echo "==============================================================="
echo " Done updating penny scripts."
echo "==============================================================="
EOF

---

## 2) What you must do after running the script

1. **Run the setup script**

```bash
./setup_penny_fyers_symbols.sh

