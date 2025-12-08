import os
import yaml
import math

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETTINGS_PATH = os.path.join(PROJECT_ROOT, "config", "settings.yaml")


def load_settings():
    with open(SETTINGS_PATH, "r") as f:
        return yaml.safe_load(f)


class RiskManager:
    def __init__(self):
        self.settings = load_settings()
        self.capital = self.settings["capital"]
        self.risk_per_trade_pct = self.settings["risk_per_trade_pct"]
        self.max_open_positions = self.settings["max_open_positions"]

    def position_size(self, entry_price: float, stop_loss_price: float, current_open_positions: int) -> int:
        if current_open_positions >= self.max_open_positions:
            return 0

        risk_per_trade = self.capital * (self.risk_per_trade_pct / 100.0)
        per_share_risk = abs(entry_price - stop_loss_price)
        if per_share_risk <= 0:
            return 0

        qty = math.floor(risk_per_trade / per_share_risk)
        return max(qty, 0)
