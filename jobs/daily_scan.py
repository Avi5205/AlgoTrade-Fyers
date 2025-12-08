import os
import json
from datetime import datetime

from core.universe import get_universe
from core.data_feed import get_historical_ohlc
from strategies.swing_trend import SwingTrendStrategy

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIGNALS_FILE = os.path.join(PROJECT_ROOT, "data", "daily_signals.json")


def run_daily_scan():
    universe = get_universe()
    strategy = SwingTrendStrategy()
    signals = []

    for sym in universe:
        df = get_historical_ohlc(sym, days=250, timeframe="D")
        if df.empty:
            continue
        sig = strategy.generate_signal(sym, df)
        if sig:
            signals.append(sig)

    os.makedirs(os.path.dirname(SIGNALS_FILE), exist_ok=True)
    with open(SIGNALS_FILE, "w") as f:
        json.dump(
            {
                "date": datetime.now().strftime("%Y-%m-%d"),
                "signals": signals,
            },
            f,
            indent=2,
        )
    print(f"Saved {len(signals)} signals to {SIGNALS_FILE}")


if __name__ == "__main__":
    run_daily_scan()
