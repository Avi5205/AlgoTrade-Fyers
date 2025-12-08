import logging
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import List, Optional

import pandas as pd

from fundamentals import FundamentalRecord, FundamentalsRepository
from market_data import NseBseEodCsvPriceDataSource
from technical_analysis import TechnicalAnalysisService, TechnicalSnapshot


@dataclass
class PennyCandidate:
    symbol: str
    exchange: str
    name: str
    cmp: float
    fyers_symbol: Optional[str]

    # Fundamentals
    pe: Optional[float]
    mar_cap_cr: Optional[float]
    div_yld_pct: Optional[float]
    np_qtr_cr: Optional[float]
    qtr_profit_var_pct: Optional[float]
    sales_qtr_cr: Optional[float]
    qtr_sales_var_pct: Optional[float]
    roce_pct: Optional[float]
    debt_eq: Optional[float]

    # Technicals
    last_close: Optional[float]
    sma20: Optional[float]
    sma50: Optional[float]
    sma200: Optional[float]
    volatility_annual: Optional[float]
    trend_label: str

    # Scores
    fundamental_score: float
    technical_score: float
    total_score: float
    risk_flag: str

    # Suggested swing levels
    entry_low: Optional[float]
    entry_high: Optional[float]
    stop_loss: Optional[float]
    target1: Optional[float]
    target2: Optional[float]
    risk_per_share: Optional[float]


class PennyFundamentalFilter:
    """
    SRP: encapsulates 'fundamentally strong penny' criteria and scoring.
    """

    def __init__(
        self,
        max_price: float = 100.0,
        min_roce: float = 15.0,
        max_debt_eq: float = 0.8,
        min_qtr_profit_growth: float = 0.0,
        min_qtr_sales_growth: float = 0.0,
        min_score: float = 8.0,
    ) -> None:
        self.max_price = max_price
        self.min_roce = min_roce
        self.max_debt_eq = max_debt_eq
        self.min_qtr_profit_growth = min_qtr_profit_growth
        self.min_qtr_sales_growth = min_qtr_sales_growth
        self.min_score = min_score

    @staticmethod
    def _safe(v: Optional[float], default: float = 0.0) -> float:
        return float(v) if v is not None else default

    def score(self, rec: FundamentalRecord) -> Optional[float]:
        # Must be a penny stock
        if rec.cmp > self.max_price:
            return None

        pe = rec.pe
        roce = rec.roce_pct
        debt = rec.debt_eq
        qprof = rec.qtr_profit_var_pct
        qsales = rec.qtr_sales_var_pct

        # Mandatory low debt and minimum profitability
        if roce is None or roce < self.min_roce:
            return None
        if debt is None or debt > self.max_debt_eq:
            return None

        score = 0.0

        # PE band scoring
        if pe is not None:
            if 10 <= pe <= 30:
                score += 3.0
            elif 6 <= pe < 10 or 30 < pe <= 45:
                score += 1.5

        # ROCE strength
        if roce >= 25:
            score += 4.0
        elif roce >= 18:
            score += 3.0
        elif roce >= self.min_roce:
            score += 2.0

        # Debt discipline
        if debt <= 0.1:
            score += 3.0
        elif debt <= 0.4:
            score += 2.0
        elif debt <= self.max_debt_eq:
            score += 1.0

        # Growth signals
        if qprof is not None:
            if qprof >= 25:
                score += 2.0
            elif qprof >= self.min_qtr_profit_growth:
                score += 1.0

        if qsales is not None:
            if qsales >= 15:
                score += 2.0
            elif qsales >= self.min_qtr_sales_growth:
                score += 1.0

        return score if score >= self.min_score else None

    def risk_flag(self, rec: FundamentalRecord) -> str:
        debt = self._safe(rec.debt_eq)
        mar_cap = self._safe(rec.mar_cap_cr)
        if debt <= 0.1 and mar_cap >= 2000:
            return "Low"
        if debt <= 0.4 and mar_cap >= 500:
            return "Medium"
        return "High"


class PennyScannerService:
    """
    Orchestrates fundamentals + EOD market data + technicals to generate candidates.
    """

    def __init__(
        self,
        fundamentals_repo: FundamentalsRepository,
        price_source: NseBseEodCsvPriceDataSource,
        ta_service: TechnicalAnalysisService,
        fundamental_filter: PennyFundamentalFilter,
        lookback_days: int = 250,
    ) -> None:
        self._repo = fundamentals_repo
        self._price_source = price_source
        self._ta = ta_service
        self._ff = fundamental_filter
        self._lookback_days = lookback_days

    def _build_candidate(
        self, rec: FundamentalRecord, tech: Optional[TechnicalSnapshot], fscore: float
    ) -> PennyCandidate:
        last_close = tech.last_close if tech else rec.cmp
        sma20 = tech.sma20 if tech else None
        sma50 = tech.sma50 if tech else None
        sma200 = tech.sma200 if tech else None
        vol = tech.volatility_annual if tech else None
        trend = tech.trend_label if tech else "No trend (no EOD data)"

        # Technical scoring
        tscore = 0.0
        if tech:
            if trend == "Strong uptrend":
                tscore += 4.0
            elif trend.startswith("Uptrend"):
                tscore += 2.5
            elif trend.startswith("Downtrend") or "downtrend" in trend.lower():
                tscore -= 2.0

            if vol is not None:
                if vol < 0.35:
                    tscore += 2.0
                elif vol < 0.6:
                    tscore += 1.0
                elif vol > 0.9:
                    tscore -= 1.0

        total_score = fscore + tscore

        # Swing levels (simple structure)
        entry_low = last_close * 0.95
        entry_high = last_close * 1.02
        stop_loss = last_close * 0.8
        target1 = last_close * 1.12
        target2 = last_close * 1.25
        risk_per_share = last_close - stop_loss

        return PennyCandidate(
            symbol=rec.symbol,
            exchange=rec.exchange,
            name=rec.name,
            cmp=rec.cmp,
            fyers_symbol=rec.fyers_symbol,
            pe=rec.pe,
            mar_cap_cr=rec.mar_cap_cr,
            div_yld_pct=rec.div_yld_pct,
            np_qtr_cr=rec.np_qtr_cr,
            qtr_profit_var_pct=rec.qtr_profit_var_pct,
            sales_qtr_cr=rec.sales_qtr_cr,
            qtr_sales_var_pct=rec.qtr_sales_var_pct,
            roce_pct=rec.roce_pct,
            debt_eq=rec.debt_eq,
            last_close=last_close,
            sma20=sma20,
            sma50=sma50,
            sma200=sma200,
            volatility_annual=vol,
            trend_label=trend,
            fundamental_score=round(fscore, 2),
            technical_score=round(tscore, 2),
            total_score=round(total_score, 2),
            risk_flag=self._ff.risk_flag(rec),
            entry_low=round(entry_low, 2),
            entry_high=round(entry_high, 2),
            stop_loss=round(stop_loss, 2),
            target1=round(target1, 2),
            target2=round(target2, 2),
            risk_per_share=round(risk_per_share, 2),
        )

    def scan(self) -> pd.DataFrame:
        records = self._repo.get_all()
        logging.info("Scanning %d fundamentals for penny opportunities...", len(records))

        candidates: List[PennyCandidate] = []
        for rec in records:
            fscore = self._ff.score(rec)
            if fscore is None:
                continue

            logging.info(
                "--- Processing %s (%s, CMP=%.2f) ---",
                rec.name,
                rec.symbol,
                rec.cmp,
            )

            tech = self._ta.build_snapshot(
                exchange=rec.exchange,
                symbol=rec.symbol,
                lookback_days=self._lookback_days,
            )

            cand = self._build_candidate(rec, tech, fscore)
            candidates.append(cand)

        if not candidates:
            logging.warning("No penny candidates found with current criteria.")
            return pd.DataFrame()

        df = pd.DataFrame([asdict(c) for c in candidates])
        df = df.sort_values("total_score", ascending=False).reset_index(drop=True)
        return df


def scan_penny_universe(
    fundamentals_path: Path | str = Path("data") / "penny_fundamentals.csv",
    eod_prices_path: Path | str = Path("data") / "eod_prices.csv",
    output_path: Path | str = Path("data") / "penny_scan_report.csv",
) -> pd.DataFrame:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    logging.info("Starting penny stock scan (SOLID + NSE/BSE EOD)...")

    fundamentals_repo = FundamentalsRepository(csv_path=fundamentals_path)
    price_source = NseBseEodCsvPriceDataSource(csv_path=eod_prices_path)
    ta_service = TechnicalAnalysisService(data_source=price_source)
    ffilter = PennyFundamentalFilter()

    scanner = PennyScannerService(
        fundamentals_repo=fundamentals_repo,
        price_source=price_source,
        ta_service=ta_service,
        fundamental_filter=ffilter,
        lookback_days=250,
    )

    df = scanner.scan()
    if df.empty:
        logging.warning("Scan complete: no candidates.")
        return df

    out_path = Path(output_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(out_path, index=False)
    logging.info("Scan complete. Report written to %s", out_path)
    logging.info("Top 5 candidates by total_score:")
    logging.info("\n%s", df[["symbol", "name", "cmp", "total_score", "risk_flag"]].head())

    return df


if __name__ == "__main__":
    scan_penny_universe()
