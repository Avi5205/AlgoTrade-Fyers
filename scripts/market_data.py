import logging
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

import pandas as pd


@dataclass
class PriceHistory:
    """Value object holding OHLCV history."""
    df: pd.DataFrame  # columns: date, open, high, low, close, volume


class PriceDataSource:
    """
    Abstraction for any source of historical prices (SRP/Interface Segregation).
    Implementations: NSE/BSE EOD CSV, API clients, etc.
    """

    def get_history(
        self,
        exchange: str,
        symbol: str,
        lookback_days: int = 250,
    ) -> PriceHistory:
        """
        Return OHLCV history for a symbol.
        - exchange: 'NSE' or 'BSE'
        - symbol: internal code like 'FCL', 'MCLOUD', etc.
        - lookback_days: limit history window.
        """
        raise NotImplementedError


class NseBseEodCsvPriceDataSource(PriceDataSource):
    """
    Concrete implementation using a local CSV generated from NSE/BSE bhavcopies.

    Expected CSV: data/eod_prices.csv with columns like:
      exchange,symbol,series,date,open,high,low,close,volume

    - exchange: 'NSE' or 'BSE'
    - symbol: like 'FCL', 'MCLOUD', etc. (your internal symbol codes)
    - date: ISO or DD-MMM-YYYY, will be parsed by pandas.to_datetime
    """

    def __init__(self, csv_path: Path | str = Path("data") / "eod_prices.csv") -> None:
        self._path = Path(csv_path)
        self._df: Optional[pd.DataFrame] = None

    def _load(self) -> pd.DataFrame:
        if self._df is not None:
            return self._df

        if not self._path.exists():
            logging.warning(
                "EOD prices file %s not found. Scanner will skip technicals.",
                self._path,
            )
            self._df = pd.DataFrame()
            return self._df

        df = pd.read_csv(self._path)
        if "date" not in df.columns:
            raise ValueError(
                f"EOD prices file {self._path} must contain a 'date' column."
            )

        df["date"] = pd.to_datetime(df["date"])
        # Normalize column names
        rename_map = {}
        if "close_price" in df.columns and "close" not in df.columns:
            rename_map["close_price"] = "close"
        if "tottrdqty" in df.columns and "volume" not in df.columns:
            rename_map["tottrdqty"] = "volume"
        if rename_map:
            df = df.rename(columns=rename_map)

        required_cols = {"exchange", "symbol", "date", "close"}
        missing = required_cols - set(df.columns)
        if missing:
            raise ValueError(
                f"EOD prices file {self._path} is missing required column(s): {missing}"
            )

        self._df = df
        logging.info(
            "Loaded EOD prices from %s with %d rows.", self._path, len(self._df)
        )
        return self._df

    def get_history(
        self,
        exchange: str,
        symbol: str,
        lookback_days: int = 250,
    ) -> PriceHistory:
        df = self._load()
        if df.empty:
            return PriceHistory(pd.DataFrame())

        exchange = str(exchange).strip().upper()
        symbol = str(symbol).strip().upper()

        mask = (
            df["exchange"].astype(str).str.upper().eq(exchange)
            & df["symbol"].astype(str).str.upper().eq(symbol)
        )
        hist = df.loc[mask].copy()
        if hist.empty:
            logging.warning(
                "No EOD data found in %s for %s:%s", self._path, exchange, symbol
            )
            return PriceHistory(pd.DataFrame())

        hist = hist.sort_values("date")
        if lookback_days is not None and lookback_days > 0:
            cutoff = datetime.now().date() - timedelta(days=lookback_days)
            hist = hist[hist["date"] >= pd.Timestamp(cutoff)]

        # Ensure required columns exist
        for col in ("open", "high", "low", "close", "volume"):
            if col not in hist.columns:
                hist[col] = pd.NA

        return PriceHistory(
            df=hist[["date", "open", "high", "low", "close", "volume"]].reset_index(
                drop=True
            )
        )
