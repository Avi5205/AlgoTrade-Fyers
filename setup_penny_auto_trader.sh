#!/usr/bin/env bash
set -euo pipefail

echo "==============================================================="
echo " Setting up penny auto-trader (FULL AUTO) for FYERS"
echo "==============================================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "ERROR: $COMPOSE_FILE not found in $SCRIPT_DIR"
  exit 1
fi

echo "[1/4] Creating scripts/penny_auto_trader.py ..."

mkdir -p scripts

cat << 'PYEOF' > scripts/penny_auto_trader.py
import os
import json
import time
import logging
from datetime import datetime, time as dtime

import pandas as pd
from fyers_apiv3 import fyersModel

DATA_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")
RECO_PATH = os.path.join(DATA_DIR, "penny_recommendations.csv")
POSITIONS_PATH = os.path.join(DATA_DIR, "penny_open_positions.json")


def load_fyers():
    client_id = os.getenv("FYERS_CLIENT_ID")
    access_token = os.getenv("FYERS_ACCESS_TOKEN")

    if not client_id or not access_token:
        raise RuntimeError("FYERS_CLIENT_ID or FYERS_ACCESS_TOKEN missing from environment.")

    logging.info("Initializing FYERS client for auto-trading...")
    fy = fyersModel.FyersModel(client_id=client_id, token=access_token, log_path="/app/logs")
    return fy


def load_positions():
    if not os.path.exists(POSITIONS_PATH):
        return {}
    try:
        with open(POSITIONS_PATH, "r") as f:
            data = json.load(f)
            if not isinstance(data, dict):
                return {}
            return data
    except Exception:
        return {}


def save_positions(positions):
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(POSITIONS_PATH, "w") as f:
        json.dump(positions, f, indent=2, sort_keys=True)


def is_market_time(now=None):
    """
    Basic NSE cash market hours filter: 09:15 - 15:30 IST, Mon-Fri.
    """
    now = now or datetime.now()
    # Monday=0, Sunday=6
    if now.weekday() >= 5:
        return False
    t = now.time()
    return dtime(9, 15) <= t <= dtime(15, 30)


def get_ltp_map(fyers, fyers_symbols):
    """
    Fetch last traded price (LTP) for a list of FYERS symbols.
    """
    if not fyers_symbols:
        return {}

    symbols_str = ",".join(sorted(set(fyers_symbols)))
    try:
        resp = fyers.quotes({"symbols": symbols_str})
    except Exception as e:
        logging.error("Error fetching quotes: %s", e)
        return {}

    ltp_map = {}
    try:
        for item in resp.get("d", []):
            sym = item.get("n") or item.get("symbol")
            v = item.get("v", {})
            ltp = v.get("lp")
            if sym and ltp is not None:
                ltp_map[sym] = float(ltp)
    except Exception as e:
        logging.error("Error parsing quotes response: %s", e)

    return ltp_map


def infer_fyers_symbol(row):
    """
    Infer FYERS trading symbol from recommendation row.

    Priority:
      1) If 'fyers_symbol' column exists and is non-empty, use it.
      2) Else, try 'NSE:{symbol}-EQ' as a best-effort guess for NSE cash.

    WARNING: For BSE / SME / special cases this may be wrong.
    In that case, add a 'fyers_symbol' column in penny_recommendations.csv
    or penny_fundamentals.csv explicitly.
    """
    fyers_symbol = None

    if "fyers_symbol" in row and isinstance(row["fyers_symbol"], str) and row["fyers_symbol"].strip():
        fyers_symbol = row["fyers_symbol"].strip()
    else:
        sym = row.get("symbol")
        if isinstance(sym, str) and sym.strip():
            fyers_symbol = f"NSE:{sym.strip()}-EQ"

    return fyers_symbol


def place_buy_orders(fyers, positions):
    """
    Read penny_recommendations.csv and place BUY orders for symbols
    that are not yet in positions with status=OPEN.
    """
    if not os.path.exists(RECO_PATH):
        logging.info("No recommendations file found at %s", RECO_PATH)
        return positions

    df = pd.read_csv(RECO_PATH)
    if df.empty:
        logging.info("Recommendations file is empty.")
        return positions

    for _, row in df.iterrows():
        symbol = row.get("symbol", "")
        name = row.get("name", "")
        fyers_symbol = infer_fyers_symbol(row)

        if not fyers_symbol:
            logging.warning("Skipping %s (%s): unable to infer FYERS symbol.", name, symbol)
            continue

        pos_key = fyers_symbol

        # Skip if already open
        pos = positions.get(pos_key)
        if pos and pos.get("status") == "OPEN":
            continue

        try:
            qty = int(row.get("qty", 0))
            entry_price = float(row.get("recommended_entry"))
            stop_loss = float(row.get("stop_loss"))
            target1 = float(row.get("target1") or 0.0) if not pd.isna(row.get("target1")) else None
            target2 = float(row.get("target2") or 0.0) if not pd.isna(row.get("target2")) else None
        except Exception as e:
            logging.warning("Skipping %s (%s): numeric conversion error: %s", name, symbol, e)
            continue

        if qty <= 0:
            logging.info("Skipping %s (%s): qty <= 0", name, fyers_symbol)
            continue

        if entry_price <= 0 or stop_loss <= 0 or stop_loss >= entry_price:
            logging.info("Skipping %s (%s): invalid entry/SL (entry=%.2f, SL=%.2f).", name, fyers_symbol, entry_price, stop_loss)
            continue

        # For now, use MARKET order at current price
        order_data = {
            "symbol": fyers_symbol,
            "qty": qty,
            "type": 2,               # 2 = MARKET as per fyers_apiv3 docs
            "side": 1,               # 1 = BUY
            "productType": "CNC",    # delivery, swing
            "limitPrice": 0,
            "stopPrice": 0,
            "validity": "DAY",
            "disclosedQty": 0,
            "offlineOrder": False,
            "stopLoss": 0,
            "takeProfit": 0,
        }

        logging.info("Placing BUY order for %s (%s), qty=%d", name, fyers_symbol, qty)
        try:
            resp = fyers.place_order(order_data)
        except Exception as e:
            logging.error("Error placing BUY order for %s (%s): %s", name, fyers_symbol, e)
            continue

        logging.info("BUY response for %s: %s", fyers_symbol, resp)

        if resp.get("s") == "ok":
            order_id = resp.get("id", "")
            positions[pos_key] = {
                "symbol": symbol,
                "name": name,
                "fyers_symbol": fyers_symbol,
                "qty": qty,
                "entry_price": entry_price,
                "stop_loss": stop_loss,
                "target1": target1,
                "target2": target2,
                "status": "OPEN",
                "buy_order_id": order_id,
                "created_at": datetime.now().isoformat(),
                "last_update": datetime.now().isoformat(),
                "trail_at_t1": True,   # if True: move SL to entry when T1 hit
            }
        else:
            logging.error("BUY order failed for %s (%s): %s", name, fyers_symbol, resp)

    return positions


def manage_exits(fyers, positions):
    """
    For each OPEN position:
      - If price <= SL: sell full qty, mark CLOSED_SL
      - If price >= T2: sell full qty, mark CLOSED_T2
      - If price >= T1 and trail_at_t1: move SL to entry
    """
    open_symbols = [p["fyers_symbol"] for p in positions.values() if p.get("status") == "OPEN"]
    if not open_symbols:
        return positions

    ltp_map = get_ltp_map(fyers, open_symbols)
    if not ltp_map:
        logging.info("No LTP data available for open positions.")
        return positions

    for key, pos in list(positions.items()):
        if pos.get("status") != "OPEN":
            continue

        fyers_symbol = pos.get("fyers_symbol")
        if not fyers_symbol:
            continue

        ltp = ltp_map.get(fyers_symbol)
        if ltp is None:
            logging.info("No LTP for %s", fyers_symbol)
            continue

        qty = int(pos.get("qty", 0))
        if qty <= 0:
            continue

        entry_price = float(pos.get("entry_price", 0))
        stop_loss = float(pos.get("stop_loss", 0))
        target1 = pos.get("target1")
        target2 = pos.get("target2")

        # 1) Trail SL to entry when T1 hit
        if target1 is not None and pos.get("trail_at_t1", False):
            try:
                if ltp >= float(target1) and stop_loss < entry_price:
                    logging.info("Trailing SL for %s to entry price %.2f (T1 hit, LTP=%.2f).", fyers_symbol, entry_price, ltp)
                    pos["stop_loss"] = entry_price
                    pos["last_update"] = datetime.now().isoformat()
                    positions[key] = pos
                    stop_loss = entry_price
            except Exception:
                pass

        # 2) Check for STOP-LOSS
        if ltp <= stop_loss:
            logging.info("STOP-LOSS HIT for %s (LTP=%.2f, SL=%.2f). Exiting position.", fyers_symbol, ltp, stop_loss)
            sell_and_close(fyers, pos, reason="SL_HIT")
            pos["status"] = "CLOSED_SL"
            pos["exit_price"] = ltp
            pos["exit_reason"] = "SL_HIT"
            pos["last_update"] = datetime.now().isoformat()
            positions[key] = pos
            continue

        # 3) Check for TARGET2
        if target2 is not None:
            try:
                if ltp >= float(target2):
                    logging.info("TARGET2 HIT for %s (LTP=%.2f, T2=%.2f). Exiting position.", fyers_symbol, ltp, float(target2))
                    sell_and_close(fyers, pos, reason="T2_HIT")
                    pos["status"] = "CLOSED_T2"
                    pos["exit_price"] = ltp
                    pos["exit_reason"] = "T2_HIT"
                    pos["last_update"] = datetime.now().isoformat()
                    positions[key] = pos
                    continue
            except Exception:
                pass

    return positions


def sell_and_close(fyers, pos, reason):
    """
    Sends a full-qty SELL MARKET order for the position.
    """
    fyers_symbol = pos.get("fyers_symbol")
    qty = int(pos.get("qty", 0))
    name = pos.get("name", "")
    if not fyers_symbol or qty <= 0:
        logging.warning("Invalid position data for sell: %s", pos)
        return

    order_data = {
        "symbol": fyers_symbol,
        "qty": qty,
        "type": 2,              # MARKET
        "side": -1,             # SELL
        "productType": "CNC",
        "limitPrice": 0,
        "stopPrice": 0,
        "validity": "DAY",
        "disclosedQty": 0,
        "offlineOrder": False,
        "stopLoss": 0,
        "takeProfit": 0,
    }

    logging.info("Placing SELL order for %s (%s), qty=%d, reason=%s", name, fyers_symbol, qty, reason)
    try:
        resp = fyers.place_order(order_data)
        logging.info("SELL response for %s: %s", fyers_symbol, resp)
    except Exception as e:
        logging.error("Error placing SELL order for %s (%s): %s", name, fyers_symbol, e)


def main_loop():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    logging.info("Starting penny auto-trader (FULL AUTO, swing to T2)...")

    fyers = load_fyers()

    while True:
        try:
            now = datetime.now()
            if not is_market_time(now):
                logging.info("Outside market hours. Sleeping for 5 minutes.")
                time.sleep(300)
                continue

            positions = load_positions()

            # 1) Place new BUY orders for fresh recommendations
            positions = place_buy_orders(fyers, positions)

            # 2) Manage exits (SL / T2, SL trail at T1)
            positions = manage_exits(fyers, positions)

            # 3) Persist state
            save_positions(positions)

            time.sleep(60)  # 1-minute cycle
        except Exception as e:
            logging.error("Unexpected error in main loop: %s", e)
            time.sleep(60)


if __name__ == "__main__":
    main_loop()
PYEOF

echo "[2/4] Backing up existing docker-compose.yml to docker-compose.yml.auto.bak ..."
cp "$COMPOSE_FILE" "${COMPOSE_FILE}.auto.bak"

echo "[3/4] Checking if 'penny-trader' service is already present ..."
if grep -q "penny-trader:" "$COMPOSE_FILE"; then
  echo "INFO: 'penny-trader' service already exists in $COMPOSE_FILE. No changes made."
else
  echo "INFO: Appending 'penny-trader' service definition to $COMPOSE_FILE ..."

  cat << 'EOFYAML' >> "$COMPOSE_FILE"

  penny-trader:
    build: .
    container_name: fyers-penny-trader
    env_file:
      - ./config/credentials.env
    volumes:
      - ./logs:/app/logs
      - ./data:/app/data
    command: ["python", "scripts/penny_auto_trader.py"]
    restart: unless-stopped
EOFYAML

  echo "INFO: 'penny-trader' service appended successfully."
fi

echo "[4/4] Validating docker compose configuration ..."
if command -v docker-compose >/dev/null 2>&1; then
  docker-compose config >/dev/null && echo "docker-compose.yml looks valid."
elif command -v docker >/dev/null 2>&1; then
  docker compose config >/dev/null && echo "docker-compose.yml looks valid."
else
  echo "WARNING: docker / docker-compose not found in PATH. Skipping validation."
fi

echo "==============================================================="
echo " SETUP COMPLETE."
echo " When you are REALLY READY for live auto-trading, run:"
echo "   docker compose build"
echo "   docker compose up -d penny-trader"
echo
echo " To stop auto-trading at any time:"
echo "   docker compose stop penny-trader"
echo "==============================================================="
