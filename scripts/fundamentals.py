import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

import pandas as pd


@dataclass
class FundamentalRecord:
    symbol: str
    name: str
    cmp: float
    pe: Optional[float]
    mar_cap_cr: Optional[float]
    div_yld_pct: Optional[float]
    np_qtr_cr: Optional[float]
    qtr_profit_var_pct: Optional[float]
    sales_qtr_cr: Optional[float]
    qtr_sales_var_pct: Optional[float]
    roce_pct: Optional[float]
    debt_eq: Optional[float]
    yf_symbol: Optional[str]
    fyers_symbol: Optional[str]
    exchange: str  # 'NSE' or 'BSE'


class FundamentalsRepository:
    """
    Single Responsibility:
      - Load and validate fundamentals from CSV
      - Provide domain objects to the scanner
    """

    def __init__(
        self,
        csv_path: Path | str = Path("data") / "penny_fundamentals.csv",
    ) -> None:
        self._path = Path(csv_path)
        self._records: Dict[str, FundamentalRecord] = {}

    def load(self) -> List[FundamentalRecord]:
        if not self._path.exists():
            raise FileNotFoundError(
                f"Fundamentals file not found: {self._path}. "
                f"Expected columns: symbol,name,cmp,pe,mar_cap_cr,div_yld_pct,"
                f"np_qtr_cr,qtr_profit_var_pct,sales_qtr_cr,qtr_sales_var_pct,"
                f"roce_pct,debt_eq,yf_symbol,fyers_symbol"
            )

        df = pd.read_csv(self._path)

        def safe_float(v):
            try:
                if v == "" or v is None:
                    return None
                return float(v)
            except Exception:
                return None

        records: List[FundamentalRecord] = []

        for _, row in df.iterrows():
            symbol = str(row.get("symbol", "")).strip().upper()
            if not symbol:
                continue

            name = str(row.get("name", "")).strip()
            cmp_val = safe_float(row.get("cmp"))
            if cmp_val is None:
                logging.warning(
                    "Skipping %s because CMP is missing/invalid in fundamentals.", symbol
                )
                continue

            fyers_symbol = str(row.get("fyers_symbol") or "").strip() or None
            yf_symbol = str(row.get("yf_symbol") or "").strip() or None

            # Infer exchange if not explicitly present
            exchange = str(row.get("exchange") or "").strip().upper()
            if not exchange:
                if fyers_symbol and fyers_symbol.upper().startswith("NSE:"):
                    exchange = "NSE"
                elif fyers_symbol and fyers_symbol.upper().startswith("BSE:"):
                    exchange = "BSE"
                elif yf_symbol:
                    if yf_symbol.upper().endswith(".NS"):
                        exchange = "NSE"
                    elif yf_symbol.upper().endswith(".BO"):
                        exchange = "BSE"
                if not exchange:
                    exchange = "NSE"

            rec = FundamentalRecord(
                symbol=symbol,
                name=name,
                cmp=cmp_val,
                pe=safe_float(row.get("pe")),
                mar_cap_cr=safe_float(row.get("mar_cap_cr")),
                div_yld_pct=safe_float(row.get("div_yld_pct")),
                np_qtr_cr=safe_float(row.get("np_qtr_cr")),
                qtr_profit_var_pct=safe_float(row.get("qtr_profit_var_pct")),
                sales_qtr_cr=safe_float(row.get("sales_qtr_cr")),
                qtr_sales_var_pct=safe_float(row.get("qtr_sales_var_pct")),
                roce_pct=safe_float(row.get("roce_pct")),
                debt_eq=safe_float(row.get("debt_eq")),
                yf_symbol=yf_symbol,
                fyers_symbol=fyers_symbol,
                exchange=exchange,
            )
            records.append(rec)

        self._records = {r.symbol: r for r in records}
        logging.info("Loaded %d fundamental records from %s", len(records), self._path)
        return records

    def get_all(self) -> List[FundamentalRecord]:
        if not self._records:
            return self.load()
        return list(self._records.values())

    def get(self, symbol: str) -> Optional[FundamentalRecord]:
        if not self._records:
            self.load()
        return self._records.get(symbol.upper())
