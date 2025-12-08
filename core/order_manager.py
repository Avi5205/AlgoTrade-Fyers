from fyers_apiv3 import fyersModel
from core.auth import get_fyers_client


class OrderManager:
    def __init__(self):
        self.fyers: fyersModel.FyersModel = get_fyers_client()

    def place_swing_order(self, symbol: str, qty: int, side: str, limit_price: float | None = None):
        if qty <= 0:
            return {"error": "qty <= 0, not placing order"}

        side_val = 1 if side.upper() == "BUY" else -1

        order = {
            "symbol": symbol,
            "qty": qty,
            "type": 1 if limit_price is None else 2,  # 1=market, 2=limit
            "side": side_val,
            "productType": "CNC",
            "limitPrice": limit_price or 0,
            "stopPrice": 0,
            "validity": "DAY",
            "disclosedQty": 0,
            "offlineOrder": "False",
        }
        resp = self.fyers.place_order(order)
        return resp
