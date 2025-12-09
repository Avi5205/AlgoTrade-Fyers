#!/usr/bin/env bash
set -euo pipefail

##
# FYERS Auth Dashboard Updater
# - Updates backend FastAPI (main.py) with:
#     * Auth URL
#     * Exchange auth_code
#     * Save token & restart Docker
#     * Test profile
#     * List recommendations
#     * List executed trades
#     * Manual place-order
# - Updates frontend React (App.jsx + App.css) to expose all controls.
#
# Assumptions:
#   - This script lives in: outer/fyers-swing-docker/update_auth_dashboard.sh
#   - Project root is:      outer/fyers-swing-docker/fyers-swing-docker
##

# TOP_DIR = outer fyers-swing-docker
TOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROJECT_ROOT = inner fyers-swing-docker (where docker-compose.yml, data, config, auth-dashboard live)
PROJECT_ROOT="$TOP_DIR/fyers-swing-docker"

BACKEND_DIR="$PROJECT_ROOT/auth-dashboard/backend"
FRONTEND_DIR="$PROJECT_ROOT/auth-dashboard/frontend"
BACKEND_MAIN="$BACKEND_DIR/main.py"
FRONTEND_APP="$FRONTEND_DIR/src/App.jsx"
FRONTEND_CSS="$FRONTEND_DIR/src/App.css"

log() {
  echo "[auth-dashboard] $*"
}

ensure_structure() {
  log "TOP_DIR:        $TOP_DIR"
  log "PROJECT_ROOT:   $PROJECT_ROOT"
  log "BACKEND_DIR:    $BACKEND_DIR"
  log "FRONTEND_DIR:   $FRONTEND_DIR"

  if [[ ! -d "$PROJECT_ROOT" ]]; then
    log "ERROR: Project root not found at: $PROJECT_ROOT"
    exit 1
  fi

  if [[ ! -d "$BACKEND_DIR" ]]; then
    log "ERROR: Backend directory not found at: $BACKEND_DIR"
    exit 1
  fi
  if [[ ! -d "$FRONTEND_DIR/src" ]]; then
    log "ERROR: Frontend src directory not found at: $FRONTEND_DIR/src"
    exit 1
  fi
}

update_backend_main() {
  log "Updating backend main.py at: $BACKEND_MAIN"

  cat << 'EOF' > "$BACKEND_MAIN"
from __future__ import annotations

import os
import csv
import subprocess
from pathlib import Path
from dataclasses import dataclass
from typing import Optional, Literal

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from fyers_apiv3 import fyersModel

# ---------------------------------------------------------------------------
# Paths & config
# ---------------------------------------------------------------------------

# Project root: .../fyers-swing-docker (inner one)
BASE_DIR = Path(__file__).resolve().parents[2]

# Central credentials file used by bot + dashboard
CREDENTIALS_FILE = BASE_DIR / "config" / "credentials.env"

# Data files used by the penny auto-trader
DATA_DIR = BASE_DIR / "data"
RECOMMENDATIONS_FILE = DATA_DIR / "penny_recommendations.csv"
EXECUTED_FILE = DATA_DIR / "penny_trades_executed.csv"


@dataclass
class FyersConfig:
    client_id: str
    secret_key: str
    redirect_uri: str
    app_id_type: int


def load_dotenv_like(path: Path) -> dict:
    """
    Very small parser for KEY=VALUE lines (no export, no quotes).
    Used to read config/credentials.env.
    """
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip()
    return env


def get_fyers_config() -> FyersConfig:
    """
    Load FYERS config from environment variables first;
    if missing, fall back to config/credentials.env.
    """
    file_env = load_dotenv_like(CREDENTIALS_FILE)

    def get(key: str, default: str | None = None) -> str | None:
        return os.getenv(key) or file_env.get(key, default)

    client_id = get("FYERS_CLIENT_ID")
    secret_key = get("FYERS_SECRET_KEY")
    redirect_uri = get("FYERS_REDIRECT_URI")
    app_id_type = get("FYERS_APP_ID_TYPE")

    missing = [
        name
        for name, value in [
            ("FYERS_CLIENT_ID", client_id),
            ("FYERS_SECRET_KEY", secret_key),
            ("FYERS_REDIRECT_URI", redirect_uri),
            ("FYERS_APP_ID_TYPE", app_id_type),
        ]
        if not value
    ]
    if missing:
        raise RuntimeError(
            f"Missing keys in credentials.env ({CREDENTIALS_FILE}): {', '.join(missing)}"
        )

    return FyersConfig(
        client_id=client_id,
        secret_key=secret_key,
        redirect_uri=redirect_uri,
        app_id_type=int(app_id_type),
    )


def write_access_token(path: Path, new_token: str) -> None:
    """
    Update only FYERS_ACCESS_TOKEN line in credentials.env.
    Preserve all other lines as-is. If not present, append at the end.
    """
    lines: list[str] = []
    if path.exists():
        lines = path.read_text().splitlines()

    key = "FYERS_ACCESS_TOKEN"
    new_line = f"{key}={new_token}"

    found = False
    new_lines: list[str] = []
    for line in lines:
        if line.strip().startswith(f"{key}="):
            new_lines.append(new_line)
            found = True
        else:
            new_lines.append(line)

    if not found:
        if new_lines and new_lines[-1].strip():
            new_lines.append("")  # blank line before appending
        new_lines.append(new_line)

    path.write_text("\n".join(new_lines) + "\n")


def restart_docker_services() -> str:
    """
    Restart trading-related containers so they pick up the new token.
    Runs from the project root using docker compose.
    """
    try:
        completed = subprocess.run(
            ["docker", "compose", "up", "-d", "fyers-swing-bot", "penny-trader"],
            cwd=str(BASE_DIR),
            capture_output=True,
            text=True,
            check=True,
        )
        return completed.stdout.strip()
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(
            f"Failed to restart Docker services: {exc.stderr or exc.stdout}"
        ) from exc


def _get_current_token() -> str:
    """
    Helper: read FYERS_ACCESS_TOKEN from env or credentials.env.
    """
    file_env = load_dotenv_like(CREDENTIALS_FILE)
    token = os.getenv("FYERS_ACCESS_TOKEN") or file_env.get("FYERS_ACCESS_TOKEN")
    if not token:
        raise HTTPException(
            status_code=400,
            detail=f"FYERS_ACCESS_TOKEN missing in {CREDENTIALS_FILE}",
        )
    return token


# ---------------------------------------------------------------------------
# FastAPI app & CORS
# ---------------------------------------------------------------------------

app = FastAPI(title="FYERS Auth & Trading Dashboard API")

# Allow Vite dev server origin
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5173",
        "http://127.0.0.1:5173",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Pydantic Schemas
# ---------------------------------------------------------------------------

class AuthUrlResponse(BaseModel):
    login_url: str


class ExchangeRequest(BaseModel):
    auth_code: str


class ExchangeResponse(BaseModel):
    access_token: str
    refresh_token: Optional[str] = None
    raw: dict


class SaveTokenRequest(BaseModel):
    access_token: str
    restart_docker: bool = True


class SaveTokenResponse(BaseModel):
    message: str
    docker_output: Optional[str] = None


class ProfileResponse(BaseModel):
    ok: bool
    message: str
    raw: dict


class Recommendation(BaseModel):
    symbol: str
    fyers_symbol: Optional[str] = None
    qty: Optional[int] = None
    recommended_entry: Optional[float] = None
    stop_loss: Optional[float] = None
    target1: Optional[float] = None
    target2: Optional[float] = None


class ExecutedTrade(BaseModel):
    executed_date: str
    executed_time: Optional[str] = None
    symbol: str
    fyers_symbol: Optional[str] = None
    side: Optional[str] = None
    qty: Optional[int] = None
    price: Optional[float] = None
    status: Optional[str] = None


class PlaceOrderRequest(BaseModel):
    fyers_symbol: str
    qty: int = 1
    side: Literal["BUY", "SELL"] = "BUY"
    product_type: Literal["CNC", "INTRADAY"] = "CNC"


class PlaceOrderResponse(BaseModel):
    ok: bool
    message: str
    raw: dict


# ---------------------------------------------------------------------------
# Endpoints: Auth flow
# ---------------------------------------------------------------------------

@app.get("/api/auth-url", response_model=AuthUrlResponse)
def generate_auth_url() -> AuthUrlResponse:
    """
    Generate FYERS login URL using credentials from credentials.env.
    """
    cfg = get_fyers_config()

    session = fyersModel.SessionModel(
        client_id=cfg.client_id,
        secret_key=cfg.secret_key,
        redirect_uri=cfg.redirect_uri,
        response_type="code",
        grant_type="authorization_code",
    )

    login_url = session.generate_authcode()
    return AuthUrlResponse(login_url=login_url)


@app.post("/api/exchange", response_model=ExchangeResponse)
def exchange_auth_code(body: ExchangeRequest) -> ExchangeResponse:
    """
    Exchange auth_code for access_token/refresh_token.
    """
    cfg = get_fyers_config()

    session = fyersModel.SessionModel(
        client_id=cfg.client_id,
        secret_key=cfg.secret_key,
        redirect_uri=cfg.redirect_uri,
        response_type="code",
        grant_type="authorization_code",
    )

    auth_code = body.auth_code.strip()
    if not auth_code:
        raise HTTPException(status_code=400, detail="auth_code must not be empty")

    session.set_token(auth_code)
    resp = session.generate_token()

    if str(resp.get("s", "")).lower() != "ok":
        raise HTTPException(status_code=400, detail=f"Token exchange failed: {resp}")

    access_token = resp.get("access_token")
    if not access_token:
        raise HTTPException(status_code=400, detail=f"No access_token in response: {resp}")

    return ExchangeResponse(
        access_token=access_token,
        refresh_token=resp.get("refresh_token"),
        raw=resp,
    )


@app.post("/api/save-token", response_model=SaveTokenResponse)
def save_token(body: SaveTokenRequest) -> SaveTokenResponse:
    """
    Save access_token into credentials.env and optionally restart Docker services.
    """
    token = body.access_token.strip()
    if not token:
        raise HTTPException(status_code=400, detail="access_token must not be empty")

    write_access_token(CREDENTIALS_FILE, token)

    docker_output: Optional[str] = None
    if body.restart_docker:
        try:
            docker_output = restart_docker_services()
        except RuntimeError as exc:
            raise HTTPException(status_code=500, detail=str(exc)) from exc

    msg = "Token saved successfully"
    if body.restart_docker:
        msg += " and Docker services restarted."

    return SaveTokenResponse(
        message=msg,
        docker_output=docker_output,
    )


@app.get("/api/test-profile", response_model=ProfileResponse)
def test_profile() -> ProfileResponse:
    """
    Use current FYERS_ACCESS_TOKEN from credentials.env to call get_profile().
    """
    cfg = get_fyers_config()
    token = _get_current_token()

    f = fyersModel.FyersModel(client_id=cfg.client_id, token=token)
    resp = f.get_profile()

    ok = str(resp.get("s", "")).lower() == "ok" and resp.get("code") == 200
    msg = "Authenticated OK" if ok else f"Auth failed: {resp.get('message', 'Unknown error')}"

    return ProfileResponse(ok=ok, message=msg, raw=resp)


# ---------------------------------------------------------------------------
# Endpoints: Data views (recommendations, executed trades)
# ---------------------------------------------------------------------------

@app.get("/api/recommendations", response_model=list[Recommendation])
def list_recommendations() -> list[Recommendation]:
    """
    Read data/penny_recommendations.csv and return all rows
    with the key trading columns.
    """
    if not RECOMMENDATIONS_FILE.exists():
        raise HTTPException(
            status_code=404,
            detail=f"Recommendations file not found: {RECOMMENDATIONS_FILE}",
        )

    recs: list[Recommendation] = []
    with RECOMMENDATIONS_FILE.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            recs.append(
                Recommendation(
                    symbol=row.get("symbol", ""),
                    fyers_symbol=(row.get("fyers_symbol") or None),
                    qty=int(row["qty"]) if row.get("qty") else None,
                    recommended_entry=float(row["recommended_entry"])
                    if row.get("recommended_entry")
                    else None,
                    stop_loss=float(row["stop_loss"]) if row.get("stop_loss") else None,
                    target1=float(row["target1"]) if row.get("target1") else None,
                    target2=float(row["target2"]) if row.get("target2") else None,
                )
            )
    return recs


@app.get("/api/executed-trades", response_model=list[ExecutedTrade])
def list_executed_trades(limit: int = 50) -> list[ExecutedTrade]:
    """
    Read data/penny_trades_executed.csv and return the most recent trades.
    """
    if not EXECUTED_FILE.exists():
        # Empty log, return empty list rather than 404
        return []

    trades: list[ExecutedTrade] = []
    with EXECUTED_FILE.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            trades.append(
                ExecutedTrade(
                    executed_date=row.get("executed_date", ""),
                    executed_time=row.get("executed_time") or None,
                    symbol=row.get("symbol", ""),
                    fyers_symbol=row.get("fyers_symbol") or None,
                    side=row.get("side") or None,
                    qty=int(row["qty"]) if row.get("qty") else None,
                    price=float(row["price"]) if row.get("price") else None,
                    status=row.get("status") or None,
                )
            )

    trades_sorted = list(reversed(trades))
    return trades_sorted[:limit]


# ---------------------------------------------------------------------------
# Endpoints: Manual order placement
# ---------------------------------------------------------------------------

@app.post("/api/place-order", response_model=PlaceOrderResponse)
def place_order(body: PlaceOrderRequest) -> PlaceOrderResponse:
    """
    Place a simple market order (CNC or INTRADAY) via FYERS.
    Uses the same token & client_id as the trading bot.
    """
    cfg = get_fyers_config()
    token = _get_current_token()

    fy = fyersModel.FyersModel(client_id=cfg.client_id, token=token)

    order = {
        "symbol": body.fyers_symbol.strip(),
        "qty": int(body.qty),
        "type": 2,  # Market
        "side": 1 if body.side == "BUY" else -1,
        "productType": body.product_type,
        "limitPrice": 0,
        "stopPrice": 0,
        "validity": "DAY",
        "disclosedQty": 0,
        "offlineOrder": False,
        "orderTag": "dashmanual",  # distinguish dashboard orders
    }

    resp = fy.place_order(order)
    ok = str(resp.get("s", "")).lower() == "ok" and resp.get("code") == 1101
    msg = resp.get("message", "Order placed") if ok else f"Order error: {resp}"

    return PlaceOrderResponse(ok=ok, message=msg, raw=resp)
EOF
}

update_frontend_app() {
  log "Updating frontend App.jsx at: $FRONTEND_APP"

  cat << 'EOF' > "$FRONTEND_APP"
import { useState } from "react";
import "./App.css";

const API_BASE = "http://localhost:8000";

function App() {
  const [loginUrl, setLoginUrl] = useState("");
  const [authCode, setAuthCode] = useState("");
  const [exchangeResult, setExchangeResult] = useState(null);
  const [tokenToSave, setTokenToSave] = useState("");
  const [saveResult, setSaveResult] = useState(null);
  const [profileResult, setProfileResult] = useState(null);
  const [loading, setLoading] = useState(false);
  const [errorMsg, setErrorMsg] = useState("");

  const [recommendations, setRecommendations] = useState([]);
  const [executedTrades, setExecutedTrades] = useState([]);

  const [orderForm, setOrderForm] = useState({
    fyersSymbol: "",
    qty: 1,
    side: "BUY",
    productType: "CNC",
  });
  const [orderResult, setOrderResult] = useState(null);

  async function callApi(path, options) {
    setErrorMsg("");
    try {
      const resp = await fetch(`${API_BASE}${path}`, {
        headers: {
          "Content-Type": "application/json",
        },
        ...options,
      });
      if (!resp.ok) {
        let detail = "";
        try {
          const err = await resp.json();
          detail = err.detail || JSON.stringify(err);
        } catch {
          detail = resp.statusText;
        }
        throw new Error(detail || `HTTP ${resp.status}`);
      }
      return await resp.json();
    } catch (err) {
      setErrorMsg(String(err.message || err));
      throw err;
    }
  }

  async function handleGenerateAuthUrl() {
    setLoading(true);
    setLoginUrl("");
    try {
      const data = await callApi("/api/auth-url", { method: "GET" });
      setLoginUrl(data.login_url);
    } finally {
      setLoading(false);
    }
  }

  async function handleExchangeAuthCode() {
    if (!authCode.trim()) {
      setErrorMsg("Please paste an auth_code first.");
      return;
    }
    setLoading(true);
    setExchangeResult(null);
    try {
      const data = await callApi("/api/exchange", {
        method: "POST",
        body: JSON.stringify({ auth_code: authCode.trim() }),
      });
      setExchangeResult(data);
      setTokenToSave(data.access_token || "");
    } finally {
      setLoading(false);
    }
  }

  async function handleSaveToken() {
    if (!tokenToSave.trim()) {
      setErrorMsg("No access_token to save.");
      return;
    }
    setLoading(true);
    setSaveResult(null);
    try {
      const data = await callApi("/api/save-token", {
        method: "POST",
        body: JSON.stringify({
          access_token: tokenToSave.trim(),
          restart_docker: true,
        }),
      });
      setSaveResult(data);
    } finally {
      setLoading(false);
    }
  }

  async function handleTestProfile() {
    setLoading(true);
    setProfileResult(null);
    try {
      const data = await callApi("/api/test-profile", { method: "GET" });
      setProfileResult(data);
    } finally {
      setLoading(false);
    }
  }

  async function handleLoadRecommendations() {
    setLoading(true);
    try {
      const data = await callApi("/api/recommendations", { method: "GET" });
      setRecommendations(data);
    } finally {
      setLoading(false);
    }
  }

  async function handleLoadExecutedTrades() {
    setLoading(true);
    try {
      const data = await callApi("/api/executed-trades", { method: "GET" });
      setExecutedTrades(data);
    } finally {
      setLoading(false);
    }
  }

  async function handlePlaceOrder() {
    if (!orderForm.fyersSymbol.trim()) {
      setErrorMsg("Please enter a FYERS symbol (e.g., NSE:SYNCOMF-EQ).");
      return;
    }
    if (!orderForm.qty || orderForm.qty <= 0) {
      setErrorMsg("Quantity must be a positive number.");
      return;
    }
    setLoading(true);
    setOrderResult(null);
    try {
      const data = await callApi("/api/place-order", {
        method: "POST",
        body: JSON.stringify({
          fyers_symbol: orderForm.fyersSymbol.trim(),
          qty: Number(orderForm.qty),
          side: orderForm.side,
          product_type: orderForm.productType,
        }),
      });
      setOrderResult(data);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="App">
      <h1>FYERS Auth & Trading Dashboard</h1>

      {loading && <div className="banner banner-info">Working…</div>}
      {errorMsg && <div className="banner banner-error">Error: {errorMsg}</div>}

      <section className="card">
        <h2>1. Generate FYERS Login URL</h2>
        <p>
          This uses <code>FYERS_CLIENT_ID</code>, <code>FYERS_SECRET_KEY</code> and{" "}
          <code>FYERS_REDIRECT_URI</code> from <code>config/credentials.env</code>.
        </p>
        <button onClick={handleGenerateAuthUrl}>Generate Login URL</button>
        {loginUrl && (
          <div className="mt">
            <label>Login URL:</label>
            <textarea value={loginUrl} readOnly rows={3} />
            <p>
              Open this URL in your browser, log in, then copy the{" "}
              <code>auth_code</code> from the address bar.
            </p>
          </div>
        )}
      </section>

      <section className="card">
        <h2>2. Exchange Auth Code for Token</h2>
        <label>Auth Code (from redirect URL):</label>
        <textarea
          rows={3}
          value={authCode}
          onChange={(e) => setAuthCode(e.target.value)}
          placeholder="Paste auth_code=... here"
        />
        <button onClick={handleExchangeAuthCode}>Exchange Auth Code</button>

        {exchangeResult && (
          <div className="mt">
            <h3>Raw Exchange Response</h3>
            <pre>{JSON.stringify(exchangeResult, null, 2)}</pre>
          </div>
        )}
      </section>

      <section className="card">
        <h2>3. Save Access Token & Restart Trading Containers</h2>
        <p>
          This writes <code>FYERS_ACCESS_TOKEN</code> into{" "}
          <code>config/credentials.env</code> and runs{" "}
          <code>docker compose up -d fyers-swing-bot penny-trader</code> from the
          project root.
        </p>
        <label>Access Token to save:</label>
        <textarea
          rows={3}
          value={tokenToSave}
          onChange={(e) => setTokenToSave(e.target.value)}
          placeholder="Access token from exchange step"
        />
        <button onClick={handleSaveToken}>Save Token & Restart Docker</button>

        {saveResult && (
          <div className="mt">
            <h3>Save Result</h3>
            <pre>{JSON.stringify(saveResult, null, 2)}</pre>
          </div>
        )}
      </section>

      <section className="card">
        <h2>4. Test FYERS Profile (using current token)</h2>
        <p>
          This uses the <code>FYERS_ACCESS_TOKEN</code> currently stored in{" "}
          <code>config/credentials.env</code>, exactly like your trading bot containers.
        </p>
        <button onClick={handleTestProfile}>Test Profile</button>
        {profileResult && (
          <div className="mt">
            <h3>Status</h3>
            <p>{profileResult.message}</p>
            <pre>{JSON.stringify(profileResult.raw, null, 2)}</pre>
          </div>
        )}
      </section>

      <section className="card">
        <h2>5. Recommended Stocks (penny_recommendations.csv)</h2>
        <p>
          Loaded from <code>data/penny_recommendations.csv</code> in your{" "}
          <code>fyers-swing-docker</code> project.
        </p>
        <button onClick={handleLoadRecommendations}>Load Recommendations</button>
        {recommendations.length > 0 && (
          <div className="mt table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>Symbol</th>
                  <th>FYERS Symbol</th>
                  <th>Qty</th>
                  <th>Entry</th>
                  <th>SL</th>
                  <th>T1</th>
                  <th>T2</th>
                </tr>
              </thead>
              <tbody>
                {recommendations.map((r, idx) => (
                  <tr key={idx}>
                    <td>{r.symbol}</td>
                    <td>{r.fyers_symbol || "-"}</td>
                    <td>{r.qty ?? "-"}</td>
                    <td>{r.recommended_entry ?? "-"}</td>
                    <td>{r.stop_loss ?? "-"}</td>
                    <td>{r.target1 ?? "-"}</td>
                    <td>{r.target2 ?? "-"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="card">
        <h2>6. Executed Trades Log (penny_trades_executed.csv)</h2>
        <p>
          Shows the latest trades written by your <code>PennyAutoTrader</code> in{" "}
          <code>data/penny_trades_executed.csv</code>.
        </p>
        <button onClick={handleLoadExecutedTrades}>Load Executed Trades</button>
        {executedTrades.length > 0 && (
          <div className="mt table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>Date</th>
                  <th>Time</th>
                  <th>Symbol</th>
                  <th>FYERS Symbol</th>
                  <th>Side</th>
                  <th>Qty</th>
                  <th>Price</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {executedTrades.map((t, idx) => (
                  <tr key={idx}>
                    <td>{t.executed_date}</td>
                    <td>{t.executed_time || "-"}</td>
                    <td>{t.symbol}</td>
                    <td>{t.fyers_symbol || "-"}</td>
                    <td>{t.side || "-"}</td>
                    <td>{t.qty ?? "-"}</td>
                    <td>{t.price ?? "-"}</td>
                    <td>{t.status || "-"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="card">
        <h2>7. Quick Manual Order</h2>
        <p>
          Places a market order via FYERS using the current{" "}
          <code>FYERS_ACCESS_TOKEN</code>. Useful for quick testing or manual entries.
        </p>

        <div className="form-grid">
          <div>
            <label>FYERS Symbol</label>
            <input
              type="text"
              value={orderForm.fyersSymbol}
              onChange={(e) =>
                setOrderForm({ ...orderForm, fyersSymbol: e.target.value })
              }
              placeholder="e.g., NSE:SYNCOMF-EQ"
            />
          </div>
          <div>
            <label>Quantity</label>
            <input
              type="number"
              min="1"
              value={orderForm.qty}
              onChange={(e) =>
                setOrderForm({ ...orderForm, qty: Number(e.target.value) })
              }
            />
          </div>
          <div>
            <label>Side</label>
            <select
              value={orderForm.side}
              onChange={(e) =>
                setOrderForm({ ...orderForm, side: e.target.value })
              }
            >
              <option value="BUY">BUY</option>
              <option value="SELL">SELL</option>
            </select>
          </div>
          <div>
            <label>Product Type</label>
            <select
              value={orderForm.productType}
              onChange={(e) =>
                setOrderForm({ ...orderForm, productType: e.target.value })
              }
            >
              <option value="CNC">CNC</option>
              <option value="INTRADAY">INTRADAY</option>
            </select>
          </div>
        </div>

        <button onClick={handlePlaceOrder}>Place Order</button>

        {orderResult && (
          <div className="mt">
            <h3>Order Result</h3>
            <p>
              {orderResult.ok ? "Order placed successfully" : "Order failed"} –{" "}
              {orderResult.message}
            </p>
            <pre>{JSON.stringify(orderResult.raw, null, 2)}</pre>
          </div>
        )}
      </section>
    </div>
  );
}

export default App;
EOF
}

update_frontend_css() {
  log "Updating frontend App.css at: $FRONTEND_CSS"

  cat << 'EOF' > "$FRONTEND_CSS"
.App {
  max-width: 960px;
  margin: 0 auto;
  padding: 1.5rem;
  font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI",
    sans-serif;
}

h1 {
  margin-bottom: 1.5rem;
}

.card {
  border: 1px solid #ddd;
  border-radius: 8px;
  padding: 1rem 1.25rem;
  margin-bottom: 1.25rem;
  background: #fafafa;
}

.card h2 {
  margin-top: 0;
}

button {
  padding: 0.5rem 1rem;
  border-radius: 4px;
  border: 1px solid #555;
  background: #222;
  color: white;
  cursor: pointer;
}

button:hover {
  opacity: 0.9;
}

textarea,
input,
select {
  width: 100%;
  box-sizing: border-box;
  margin-top: 0.25rem;
  margin-bottom: 0.5rem;
  padding: 0.4rem;
  font-family: inherit;
}

.mt {
  margin-top: 0.75rem;
}

.banner {
  padding: 0.5rem 0.75rem;
  margin-bottom: 0.75rem;
  border-radius: 4px;
}

.banner-info {
  background: #e7f3ff;
  border: 1px solid #aac8ff;
}

.banner-error {
  background: #ffe7e7;
  border: 1px solid #ffaaaa;
}

.table-wrapper {
  overflow-x: auto;
}

table {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.85rem;
}

th,
td {
  border: 1px solid #ddd;
  padding: 0.35rem 0.5rem;
  text-align: left;
}

th {
  background: #f0f0f0;
}

.form-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: 0.75rem;
}
EOF
}

main() {
  ensure_structure
  update_backend_main
  update_frontend_app
  update_frontend_css

  log "Done. Next steps:"
  echo
  echo "  1) Backend:"
  echo "       cd \"$BACKEND_DIR\""
  echo "       python3 -m venv .venv  # if not created"
  echo "       source .venv/bin/activate"
  echo "       pip install -r requirements.txt"
  echo "       uvicorn main:app --reload --port 8000"
  echo
  echo "  2) Frontend:"
  echo "       cd \"$FRONTEND_DIR\""
  echo "       npm install   # if not already done"
  echo "       npm run dev   # opens http://localhost:5173"
}

main "$@"

