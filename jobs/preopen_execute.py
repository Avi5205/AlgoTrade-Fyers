import os
import json
from datetime import datetime

from core.risk_manager import RiskManager
from core.order_manager import OrderManager

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIGNALS_FILE = os.path.join(PROJECT_ROOT, "data", "daily_signals.json")
TRADES_LOG = os.path.join(PROJECT_ROOT, "logs", "trades.csv")


def load_signals():
    if not os.path.exists(SIGNALS_FILE):
        return []
    with open(SIGNALS_FILE, "r") as f:
        payload = json.load(f)
    return payload.get("signals", [])


def append_trade_log(row: dict):
    os.makedirs(os.path.dirname(TRADES_LOG), exist_ok=True)
    header_exists = os.path.exists(TRADES_LOG)
    with open(TRADES_LOG, "a") as f:
        if not header_exists:
            f.write("datetime,symbol,side,qty,entry_price,order_resp\n")
        f.write(
            f'{row["datetime"]},{row["symbol"]},{row["side"]},'
            f'{row["qty"]},{row["entry_price"]},{row["order_resp"]}\n'
        )


def execute_preopen_orders():
    signals = load_signals()
    if not signals:
        print("No signals to execute.")
        return

    rm = RiskManager()
    om = OrderManager()
    current_open_positions = 0  # TODO: fetch from positions API for production

    stop_loss_pct = rm.settings["strategy"]["exit"]["stop_loss_pct"]

    for sig in signals:
        symbol = sig["symbol"]
        entry_price = sig["entry_price"]
        side = sig["side"]

        stop_loss_price = entry_price * (1 - stop_loss_pct / 100.0)
        qty = rm.position_size(entry_price, stop_loss_price, current_open_positions)
        if qty <= 0:
            print(f"Skipping {symbol} due to qty=0")
            continue

        resp = om.place_swing_order(symbol, qty, side)
        current_open_positions += 1

        log_row = {
            "datetime": datetime.now().isoformat(),
            "symbol": symbol,
            "side": side,
            "qty": qty,
            "entry_price": entry_price,
            "order_resp": resp,
        }
        append_trade_log(log_row)


if __name__ == "__main__":
    execute_preopen_orders()
