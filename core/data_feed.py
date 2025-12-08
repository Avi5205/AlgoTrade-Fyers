from datetime import datetime, timedelta
import os
import json
import pandas as pd

from core.auth import get_fyers_client


def get_historical_ohlc(symbol: str, days: int = 200, timeframe: str = "D") -> pd.DataFrame:
    fyers = get_fyers_client()
    to_date = datetime.now()
    from_date = to_date - timedelta(days=days * 2)

    data = {
        "symbol": symbol,
        "resolution": timeframe,
        "date_format": "1",
        "range_from": from_date.strftime("%Y-%m-%d"),
        "range_to": to_date.strftime("%Y-%m-%d"),
        "cont_flag": "1",
    }

    resp = fyers.history(data)
    candles = resp.get("candles", [])

    if not candles:
        # Log the raw response so we can see what Fyers is sending back
        logs_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "logs")
        os.makedirs(logs_dir, exist_ok=True)
        log_path = os.path.join(logs_dir, "history_debug.log")
        with open(log_path, "a") as f:
            f.write(f"\n[{datetime.now().isoformat()}] Symbol: {symbol}\n")
            f.write(json.dumps(resp) + "\n")
        return pd.DataFrame()

    cols = ["timestamp", "open", "high", "low", "close", "volume"]
    df = pd.DataFrame(candles, columns=cols)
    df["datetime"] = pd.to_datetime(df["timestamp"], unit="s")
    df.set_index("datetime", inplace=True)
    df.drop(columns=["timestamp"], inplace=True)
    return df
