#!/usr/bin/env bash
set -euo pipefail

echo "==============================================================="
echo " Setting up Penny Engine (Fundamental-first + LIMIT orders)"
echo "  - Universe: data/penny_fundamentals.csv (NSE/BSE penny stocks)"
echo "  - Full scan: data/penny_scan_report.csv"
echo "  - Best picks: data/penny_recommendations.csv"
echo "  - Orders: CNC LIMIT at recommended_entry from best picks"
echo "==============================================================="

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

mkdir -p scripts data

echo "[1/2] Rewriting scripts/penny_reco_scheduler.py ..."
cat > scripts/penny_reco_scheduler.py << 'PYEOF'
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
    """
    Take scanner output and:
      - keep only lower-risk, high-score names
      - size positions by risk and by available capital
      - derive a LIMIT entry from scanner buy zones
    """
    if df_scan.empty:
        return df_scan

    df = df_scan.copy()

    # Filter out highest-risk names
    df = df[df["risk_flag"] != "High"]
    if df.empty:
        return df

    # Focus on stronger names by total_score (keep top 60%)
    df = df[df["total_score"] >= df["total_score"].quantile(0.4)]

    # Sort primarily by fundamental_score, then by total_score
    if "fundamental_score" in df.columns:
        df = df.sort_values(
            ["fundamental_score", "total_score"],
            ascending=[False, False],
        ).reset_index(drop=True)
    else:
        df = df.sort_values("total_score", ascending=False).reset_index(drop=True)

    if df.empty:
        return df

    max_risk_per_trade = total_capital * max_risk_pct
    recs = []

    for _, row in df.iterrows():
        price = float(row["cmp"])

        stop = (
            float(row["stop_loss"])
            if row.get("stop_loss") is not None and not pd.isna(row.get("stop_loss"))
            else price * 0.9
        )
        risk_per_share = max(price - stop, 0.01)

        # Derive LIMIT entry from scanner buy zone
        buy_low = row.get("buy_zone_low")
        buy_high = row.get("buy_zone_high")

        if (
            buy_low is not None
            and not pd.isna(buy_low)
            and buy_high is not None
            and not pd.isna(buy_high)
        ):
            recommended_entry = round(
                (float(buy_low) + float(buy_high)) / 2.0, 2
            )
        elif buy_low is not None and not pd.isna(buy_low):
            recommended_entry = float(buy_low)
        else:
            recommended_entry = price  # fallback to CMP if zones missing

        # Risk-based position size
        qty_risk = int(max_risk_per_trade // risk_per_share) if risk_per_share > 0 else 0
        # Capital-based position size (do not exceed total_capital)
        qty_capital = int(total_capital // price) if price > 0 else 0

        qty = min(qty_risk, qty_capital)
        if qty <= 0:
            continue

        capital_required = qty * price
        risk_on_trade = qty * risk_per_share

        rr_to_target2 = None
        if row.get("target2") is not None and not pd.isna(row.get("target2")):
            rr_to_target2 = round(
                (float(row["target2"]) - recommended_entry) / risk_per_share,
                2,
            )

        recs.append(
            {
                "symbol": row["symbol"],
                "yf_symbol": row["yf_symbol"],
                "fyers_symbol": row.get("fyers_symbol", ""),
                "name": row["name"],
                "cmp": price,
                "entry_low": row.get("buy_zone_low"),
                "entry_high": row.get("buy_zone_high"),
                "recommended_entry": recommended_entry,
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
    df_reco = df_reco.sort_values(
        ["fundamental_score", "total_score"],
        ascending=[False, False],
    ).reset_index(drop=True)
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
    print(
        f"[{datetime.now().isoformat(timespec='seconds')}] "
        f"Saved {len(df_reco)} recommendation(s) to {RECO_CSV}"
    )
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

    print(
        f"[{datetime.now().isoformat(timespec='seconds')}] "
        f"Starting penny recommendation scheduler (daily 09:25 IST)..."
    )
    sched.start()


if __name__ == "__main__":
    main()
PYEOF

echo "[2/2] Rewriting scripts/penny_auto_trader.py ..."
cat > scripts/penny_auto_trader.py << 'PYEOF'
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
        print(
            f"[{datetime.now().isoformat(timespec='seconds')}] "
            f"No recommendations file found at {RECO_CSV}"
        )
        return pd.DataFrame()

    df = pd.read_csv(RECO_CSV)
    if df.empty:
        print(
            f"[{datetime.now().isoformat(timespec='seconds')}] "
            f"Recommendations file is empty."
        )
        return df

    return df


def _init_fyers() -> fyersModel.FyersModel:
    client_id = os.getenv("FYERS_CLIENT_ID")
    token = os.getenv("FYERS_ACCESS_TOKEN")

    if not client_id or not token:
        raise SystemExit("FYERS_CLIENT_ID or FYERS_ACCESS_TOKEN not set in environment.")

    print(f"[{datetime.now().isoformat(timespec='seconds')}] Initializing FYERS client...")
    return fyersModel.FyersModel(client_id=client_id, token=token)


def _place_buy(
    f: fyersModel.FyersModel,
    fy_symbol: str,
    name: str,
    qty: int,
    limit_price: float,
) -> None:
    print(
        f"[{datetime.now().isoformat(timespec='seconds')}] "
        f"Placing LIMIT BUY for {name} ({fy_symbol}), qty={qty}, limit={limit_price}"
    )
    order = {
        "symbol": fy_symbol,
        "qty": int(qty),
        "type": 2,          # 2 = LIMIT
        "side": 1,          # BUY
        "productType": "CNC",
        "limitPrice": float(limit_price),
        "stopPrice": 0,
        "validity": "DAY",
        "disclosedQty": 0,
        "offlineOrder": False,
        "segment": "EQUITY",
    }
    try:
        resp = f.place_order(order)
        print(
            f"[{datetime.now().isoformat(timespec='seconds')}] "
            f"BUY response for {fy_symbol}: {resp}"
        )
        if not isinstance(resp, dict) or resp.get("s") != "ok":
            print(
                f"[{datetime.now().isoformat(timespec='seconds')}] "
                f"ERROR placing BUY for {fy_symbol}: {resp}"
            )
    except Exception as e:
        print(
            f"[{datetime.now().isoformat(timespec='seconds')}] "
            f"EXCEPTION placing BUY for {fy_symbol}: {e}"
        )


def run_auto_trader(poll_interval_sec: int = 60) -> None:
    fy = _init_fyers()
    placed: Set[str] = set()

    print(
        f"[{datetime.now().isoformat(timespec='seconds')}] "
        f"Starting penny auto-trader loop..."
    )
    while True:
        df = _load_recommendations()
        if not df.empty:
            for _, row in df.iterrows():
                symbol = str(row.get("symbol"))
                name = str(row.get("name", symbol))
                fyers_symbol = str(row.get("fyers_symbol", "")).strip()
                qty = int(row.get("qty", 0))

                recommended_entry = row.get("recommended_entry")
                try:
                    limit_price = (
                        float(recommended_entry)
                        if recommended_entry is not None
                        and not pd.isna(recommended_entry)
                        else None
                    )
                except Exception:
                    limit_price = None

                if symbol in placed:
                    continue

                if not fyers_symbol:
                    print(
                        f"[{datetime.now().isoformat(timespec='seconds')}] "
                        f"WARNING: No fyers_symbol for {symbol}, skipping."
                    )
                    continue

                if qty <= 0:
                    print(
                        f"[{datetime.now().isoformat(timespec='seconds')}] "
                        f"WARNING: qty<=0 for {symbol}, skipping."
                    )
                    continue

                if limit_price is None or limit_price <= 0:
                    print(
                        f"[{datetime.now().isoformat(timespec='seconds')}] "
                        f"WARNING: No valid recommended_entry for {symbol}, skipping."
                    )
                    continue

                _place_buy(fy, fyers_symbol, name, qty, limit_price)
                placed.add(symbol)

        print(
            f"[{datetime.now().isoformat(timespec='seconds')}] "
            f"Cycle complete. Sleeping {poll_interval_sec} sec."
        )
        time.sleep(poll_interval_sec)


if __name__ == "__main__":
    interval = int(os.getenv("PENNY_TRADER_POLL_SEC", "60"))
    run_auto_trader(poll_interval_sec=interval)
PYEOF

echo
echo "Done. Next steps:"
echo "  1) docker compose build --no-cache"
echo "  2) docker compose run --rm fyers-swing-bot python scripts/penny_scanner.py"
echo "  3) docker compose run --rm fyers-swing-bot python scripts/penny_reco_scheduler.py"
echo "  4) docker compose up -d penny-trader"
echo "  5) docker logs -f fyers-penny-trader"
echo "==============================================================="
