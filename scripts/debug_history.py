import os
import sys
from datetime import datetime

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.append(PROJECT_ROOT)

from core.data_feed import get_historical_ohlc
from core.universe import get_universe
from core.risk_manager import load_settings


def main():
    settings = load_settings()
    universe = get_universe()
    if not universe:
        print("Universe empty in config/settings.yaml")
        return

    symbol = universe[0]
    print(f"Testing history for: {symbol}")

    df = get_historical_ohlc(symbol, days=90, timeframe=settings["strategy"]["timeframe"])
    print("\nDataFrame shape:", df.shape)
    print(df.tail())

if __name__ == "__main__":
    print("Running debug at", datetime.now().isoformat())
    main()
