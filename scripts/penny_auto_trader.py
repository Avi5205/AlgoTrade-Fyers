import logging
import os
from dataclasses import dataclass
from datetime import datetime, date, time
from pathlib import Path
from typing import List

import pandas as pd
from fyers_apiv3 import fyersModel
from zoneinfo import ZoneInfo


@dataclass
class TradeInstruction:
    symbol: str
    fyers_symbol: str
    exchange: str
    name: str
    side: str  # 'BUY' or 'SELL'
    qty: int
    price: float
    stop_loss: float
    target1: float
    target2: float


class FyersTradingClient:
    """
    SRP: Wrap FYERS order-placement details behind a simple interface.
    """

    def __init__(self, client_id: str, access_token: str) -> None:
        if not client_id or not access_token:
            raise ValueError(
                "FYERS_CLIENT_ID and FYERS_ACCESS_TOKEN must be set in environment."
            )
        self._client = fyersModel.FyersModel(
            client_id=client_id,
            token=access_token,
        )

    def place_market_order(self, instr: TradeInstruction) -> dict:
        """
        Places a simple CNC market BUY/SELL market order.
        Extend as needed for SL/targets.
        """
        order = {
            "symbol": instr.fyers_symbol,
            "qty": int(instr.qty),
            "type": 2,  # Market
            "side": 1 if instr.side.upper() == "BUY" else -1,
            "productType": "CNC",
            "limitPrice": 0,
            "stopPrice": 0,
            "validity": "DAY",
            "disclosedQty": 0,
            "offlineOrder": False,
            # IMPORTANT: must be alphanumeric only
            "orderTag": "pennyauto",
        }
        logging.info("Placing %s order: %s", instr.side, order)
        resp = self._client.place_order(order)
        logging.info("Order response for %s: %s", instr.fyers_symbol, resp)
        return resp


class PennyAutoTrader:
    """
    High-level orchestrator for penny auto-trading:
      - reads recommendations
      - skips already executed trades for the day
      - places new BUY orders via FYERS
    """

    def __init__(
        self,
        fyers_client: FyersTradingClient,
        recommendations_path: Path | str = Path("data") / "penny_recommendations.csv",
        executed_log_path: Path | str = Path("data") / "penny_trades_executed.csv",
    ) -> None:
        self._client = fyers_client
        self._reco_path = Path(recommendations_path)
        self._exec_path = Path(executed_log_path)

    def _load_executed_today(self) -> pd.DataFrame:
        """
        Load trades executed today (if any).

        Guard against legacy/incorrect schemas where 'symbol' or 'executed_date'
        columns might be missing by returning an empty DataFrame. This prevents
        KeyError when checking already executed trades.
        """
        if not self._exec_path.exists():
            return pd.DataFrame(columns=["symbol", "executed_date", "status"])

        df = pd.read_csv(self._exec_path)

        required_cols = {"symbol", "executed_date", "status"}
        if not required_cols.issubset(df.columns):
            logging.warning(
                "Executed trades log %s missing required columns %s; "
                "treating as empty for today's de-duplication.",
                self._exec_path,
                ", ".join(sorted(required_cols)),
            )
            # Return empty with proper columns so downstream code is safe
            return pd.DataFrame(columns=list(required_cols))

        df["executed_date"] = pd.to_datetime(df["executed_date"]).dt.date
        today = date.today()
        return df[df["executed_date"] == today]

    def _append_executed(
        self, instr: TradeInstruction, resp: dict, status: str
    ) -> None:
        row = {
            "executed_date": date.today().isoformat(),
            "executed_time": datetime.now().isoformat(timespec="seconds"),
            "symbol": instr.symbol,
            "fyers_symbol": instr.fyers_symbol,
            "side": instr.side,
            "qty": instr.qty,
            "price": instr.price,
            "status": status,
            "raw_response": str(resp),
        }
        df_new = pd.DataFrame([row])
        if self._exec_path.exists():
            try:
                df_old = pd.read_csv(self._exec_path)
                # Concatenate, even if df_old is empty
                df_all = pd.concat([df_old, df_new], ignore_index=True)
            except Exception as exc:
                logging.warning(
                    "Failed to read existing executed trades log %s (%s). "
                    "Overwriting with new entry.",
                    self._exec_path,
                    exc,
                )
                df_all = df_new
        else:
            df_all = df_new

        self._exec_path.parent.mkdir(parents=True, exist_ok=True)
        df_all.to_csv(self._exec_path, index=False)

    @staticmethod
    def _is_success(row) -> bool:
        status = str(row.get("status", "")).lower()
        # Consider only successful / filled trades as executed
        return status in ("ok", "success", "filled", "completed")

    def _build_instructions(self) -> List[TradeInstruction]:
        if not self._reco_path.exists():
            logging.warning("Recommendations file %s not found.", self._reco_path)
            return []

        df = pd.read_csv(self._reco_path)
        if df.empty:
            logging.warning("Recommendations file is empty.")
            return []

        df_executed_today = self._load_executed_today()

        if not df_executed_today.empty and "symbol" in df_executed_today.columns:
            already = {
                str(row["symbol"]).upper()
                for _, row in df_executed_today.iterrows()
                if self._is_success(row)
            }
        else:
            already = set()

        instrs: List[TradeInstruction] = []
        for _, row in df.iterrows():
            symbol = str(row["symbol"]).upper()
            if symbol in already:
                logging.info(
                    "Trade for %s already executed today; skipping.", symbol
                )
                continue

            fyers_symbol = str(row.get("fyers_symbol") or "").strip()
            if not fyers_symbol:
                logging.warning(
                    "No fyers_symbol for %s; skipping auto-trade.", symbol
                )
                continue

            qty = int(row.get("qty") or 0)
            if qty <= 0:
                logging.warning("Non-positive qty for %s; skipping auto-trade.", symbol)
                continue

            price = float(row.get("recommended_entry") or row.get("cmp") or 0.0)
            if price <= 0:
                logging.warning(
                    "Non-positive price for %s (got %s); skipping auto-trade.",
                    symbol,
                    price,
                )
                continue

            stop_loss = float(row.get("stop_loss") or price * 0.8)
            target1 = float(row.get("target1") or price * 1.12)
            target2 = float(row.get("target2") or price * 1.25)

            instrs.append(
                TradeInstruction(
                    symbol=symbol,
                    fyers_symbol=fyers_symbol,
                    exchange=str(row.get("exchange") or ""),
                    name=str(row.get("name") or ""),
                    side="BUY",
                    qty=qty,
                    price=price,
                    stop_loss=stop_loss,
                    target1=target1,
                    target2=target2,
                )
            )
        return instrs

    def run_once(self) -> None:
        # Time-window guard: only trade during NSE/BSE cash market hours
        now_ist = datetime.now(ZoneInfo("Asia/Kolkata")).time()
        market_open = time(9, 15)   # 09:15 IST
        market_close = time(15, 30)  # 15:30 IST

        if not (market_open <= now_ist <= market_close):
            logging.info(
                "Outside NSE cash-market hours (%s–%s IST); skipping auto-trades. "
                "Current IST time: %s",
                market_open,
                market_close,
                now_ist,
            )
            return

        logging.info("Loading penny recommendations from %s", self._reco_path)
        instrs = self._build_instructions()
        if not instrs:
            logging.warning("No trade instructions to execute.")
            return

        for instr in instrs:
            try:
                resp = self._client.place_market_order(instr)
                status = "ok" if str(resp.get("s")).lower() == "ok" else "error"
                if status == "ok":
                    logging.info("Order placed successfully for %s", instr.symbol)
                else:
                    logging.error(
                        "Order error for %s: %s", instr.symbol, resp
                    )
                self._append_executed(instr, resp, status=status)
            except Exception as exc:
                logging.exception(
                    "Exception while placing order for %s: %s",
                    instr.symbol,
                    exc,
                )
                self._append_executed(
                    instr, {"exception": str(exc)}, status="exception"
                )


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )
    logging.info("Starting penny auto-trader (SOLID, FYERS execution only)...")

    client_id = os.getenv("FYERS_CLIENT_ID", "")
    access_token = os.getenv("FYERS_ACCESS_TOKEN", "")
    fy_client = FyersTradingClient(client_id=client_id, access_token=access_token)

    trader = PennyAutoTrader(fyers_client=fy_client)
    trader.run_once()
    logging.info("Penny auto-trader run complete.")


if __name__ == "__main__":
    main()
