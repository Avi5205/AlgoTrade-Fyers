import os
import yaml
import pandas as pd

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETTINGS_PATH = os.path.join(PROJECT_ROOT, "config", "settings.yaml")


def load_settings():
    with open(SETTINGS_PATH, "r") as f:
        return yaml.safe_load(f)


class SwingTrendStrategy:
    def __init__(self):
        self.settings = load_settings()
        self.cfg = self.settings["strategy"]["entry"]
        self.lookback = self.settings["strategy"]["lookback"]

    def generate_signal(self, symbol: str, df: pd.DataFrame) -> dict | None:
        if df.shape[0] < self.lookback:
            return None

        df = df.copy()
        df["ma_short"] = df["close"].rolling(self.cfg["ma_short"]).mean()
        df["ma_long"] = df["close"].rolling(self.cfg["ma_long"]).mean()

        last = df.iloc[-1]
        prev = df.iloc[-2]

        if last["volume"] < self.cfg["min_volume"]:
            return None

        bullish_cross = prev["ma_short"] <= prev["ma_long"] and last["ma_short"] > last["ma_long"]
        if bullish_cross and last["close"] > last["ma_short"] and last["close"] > last["ma_long"]:
            return {
                "symbol": symbol,
                "side": "BUY",
                "entry_price": float(last["close"]),
            }

        return None
