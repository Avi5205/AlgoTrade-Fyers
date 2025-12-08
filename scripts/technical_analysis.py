import logging
from dataclasses import dataclass
from math import sqrt
from typing import Optional

import pandas as pd

from market_data import PriceDataSource, PriceHistory


@dataclass
class TechnicalSnapshot:
    last_close: float
    sma20: Optional[float]
    sma50: Optional[float]
    sma200: Optional[float]
    volatility_annual: Optional[float]
    trend_label: str


class TechnicalAnalysisService:
    """
    Single Responsibility:
      - Convert raw OHLCV history into technical signals & indicators.
    """

    def __init__(self, data_source: PriceDataSource) -> None:
        self._data_source = data_source

    @staticmethod
    def _compute_sma(series: pd.Series, window: int) -> Optional[float]:
        if len(series) < window:
            return None
        return float(series.rolling(window).mean().iloc[-1])

    @staticmethod
    def _compute_annual_volatility(closes: pd.Series) -> Optional[float]:
        if len(closes) < 10:
            return None
        returns = closes.pct_change().dropna()
        if returns.empty:
            return None
        return float(returns.std() * sqrt(252.0))

    @staticmethod
    def _classify_trend(
        last_close: float,
        sma20: Optional[float],
        sma50: Optional[float],
        sma200: Optional[float],
    ) -> str:
        if sma20 is None or sma50 is None:
            return "No clear trend (insufficient data)"
        if sma200 is None:
            # Fallback classification without SMA200
            if last_close > sma50 and sma20 > sma50:
                return "Uptrend (short-term)"
            if last_close < sma50 and sma20 < sma50:
                return "Downtrend (short-term)"
            return "Sideways / Choppy"

        # Full hierarchy
        if last_close > sma200 and sma20 > sma50 > sma200:
            return "Strong uptrend"
        if last_close > sma50 and sma20 >= sma50:
            return "Uptrend"
        if last_close < sma50 and sma20 < sma50 <= sma200:
            return "Downtrend"
        if last_close < sma200 and sma50 < sma200:
            return "Strong downtrend"
        return "Sideways / Choppy"

    def build_snapshot(
        self,
        exchange: str,
        symbol: str,
        lookback_days: int = 250,
    ) -> Optional[TechnicalSnapshot]:
        hist: PriceHistory = self._data_source.get_history(
            exchange=exchange, symbol=symbol, lookback_days=lookback_days
        )

        df = hist.df
        if df is None or df.empty:
            logging.warning(
                "No historical prices for %s:%s, cannot compute technicals.",
                exchange,
                symbol,
            )
            return None

        closes = df["close"].dropna()
        if closes.empty:
            logging.warning(
                "No valid close prices for %s:%s, cannot compute technicals.",
                exchange,
                symbol,
            )
            return None

        last_close = float(closes.iloc[-1])
        sma20 = self._compute_sma(closes, 20)
        sma50 = self._compute_sma(closes, 50)
        sma200 = self._compute_sma(closes, 200)
        vol_annual = self._compute_annual_volatility(closes)
        trend = self._classify_trend(last_close, sma20, sma50, sma200)

        return TechnicalSnapshot(
            last_close=last_close,
            sma20=sma20,
            sma50=sma50,
            sma200=sma200,
            volatility_annual=vol_annual,
            trend_label=trend,
        )
