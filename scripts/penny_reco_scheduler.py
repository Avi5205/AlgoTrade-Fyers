import logging
import math
import os
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

import pandas as pd

from penny_scanner import scan_penny_universe


def _build_recommendations(
    df_scan: pd.DataFrame,
    total_capital: float,
    max_risk_pct: float,
    top_n: int = 3,
) -> pd.DataFrame:
    """
    Takes scan output and converts to actionable recommendations with position sizing.
    """
    if df_scan.empty:
        return pd.DataFrame()

    df = df_scan.copy()

    # Filter to only those with fyers_symbol (tradable via FYERS)
    df = df[df["fyers_symbol"].notna() & df["fyers_symbol"].astype(str).str.len().gt(0)]
    if df.empty:
        logging.warning("No candidates have fyers_symbol; nothing to recommend.")
        return pd.DataFrame()

    # Sort by total_score (already sorted, but be explicit)
    df = df.sort_values("total_score", ascending=False).head(top_n).reset_index(drop=True)

    max_risk_per_trade = total_capital * max_risk_pct
    recs = []

    for _, row in df.iterrows():
        symbol = row["symbol"]
        name = row["name"]
        cmp_val = float(row["cmp"])
        entry = float(row.get("last_close") or cmp_val)
        entry_low = float(row.get("entry_low") or entry * 0.95)
        entry_high = float(row.get("entry_high") or entry * 1.02)
        stop_loss = float(row.get("stop_loss") or entry * 0.8)
        target2 = float(row.get("target2") or entry * 1.25)
        fyers_symbol = row["fyers_symbol"]

        risk_per_share = entry - stop_loss
        if risk_per_share <= 0:
            logging.warning(
                "Invalid risk_per_share for %s; skipping in recommendations.", symbol
            )
            continue

        qty = math.floor(max_risk_per_trade / risk_per_share)
        capital_required = qty * entry
        if qty <= 0 or capital_required > total_capital:
            logging.warning(
                "Not enough capital to allocate to %s (required %.2f, total %.2f).",
                symbol,
                capital_required,
                total_capital,
            )
            continue

        risk_on_trade = qty * risk_per_share
        rr_to_target2 = (target2 - entry) / risk_per_share if risk_per_share > 0 else 0.0

        rec = {
            "symbol": symbol,
            "exchange": row["exchange"],
            "name": name,
            "fyers_symbol": fyers_symbol,
            "cmp": cmp_val,
            "entry_low": round(entry_low, 2),
            "entry_high": round(entry_high, 2),
            "recommended_entry": round(entry, 2),
            "stop_loss": round(stop_loss, 2),
            "target1": round(float(row.get("target1") or entry * 1.12), 2),
            "target2": round(target2, 2),
            "risk_per_share": round(risk_per_share, 2),
            "qty": int(qty),
            "capital_required": round(capital_required, 2),
            "risk_on_trade": round(risk_on_trade, 2),
            "rr_to_target2": round(rr_to_target2, 2),
            "fundamental_score": float(row["fundamental_score"]),
            "technical_score": float(row["technical_score"]),
            "total_score": float(row["total_score"]),
            "risk_flag": row["risk_flag"],
            "trend_label": row["trend_label"],
            "recommendation_time": datetime.now().isoformat(timespec="seconds"),
        }
        recs.append(rec)

    if not recs:
        logging.warning("No recommendations created.")
        return pd.DataFrame()

    return pd.DataFrame(recs)


def run_once() -> Optional[pd.DataFrame]:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    logging.info("=== Running penny scanner ===")
    df_scan = scan_penny_universe()
    if df_scan.empty:
        logging.warning("Scan produced no candidates. Exiting scheduler run.")
        return None

    total_capital = float(os.getenv("PENNY_TEST_CAPITAL", "500"))
    max_risk_pct = float(os.getenv("PENNY_MAX_RISK_PCT", "0.05"))

    logging.info(
        "Building recommendations with total_capital=%.2f, max_risk_pct=%.2f",
        total_capital,
        max_risk_pct,
    )

    df_reco = _build_recommendations(
        df_scan=df_scan,
        total_capital=total_capital,
        max_risk_pct=max_risk_pct,
        top_n=3,
    )
    if df_reco is None or df_reco.empty:
        logging.warning("No recommendations generated from scan.")
        return None

    out_path = Path("data") / "penny_recommendations.csv"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    df_reco.to_csv(out_path, index=False)
    logging.info("Saved %d recommendation(s) to %s", len(df_reco), out_path)
    logging.info("Top recommendations:\n%s", df_reco[["symbol", "name", "qty", "recommended_entry", "stop_loss", "target2"]])
    return df_reco


def run_loop(interval_minutes: int = 1440) -> None:
    """
    Simple forever loop: run once, then sleep interval_minutes.
    Suitable for running in Docker with restart: unless-stopped.
    """
    while True:
        try:
            run_once()
        except Exception as exc:
            logging.exception("Error during penny recommendation loop: %s", exc)
        logging.info("Sleeping %d minutes before next run...", interval_minutes)
        time.sleep(interval_minutes * 60)


if __name__ == "__main__":
    # Default: run once and exit (safer for manual use).
    run_once()
