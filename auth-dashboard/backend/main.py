from __future__ import annotations

import os
import subprocess
from pathlib import Path
from dataclasses import dataclass
from typing import Optional, List

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from fyers_apiv3 import fyersModel

# BASE_DIR -> /.../fyers-swing-docker
BASE_DIR = Path(__file__).resolve().parents[2]
CREDENTIALS_FILE = BASE_DIR / "config" / "credentials.env"


@dataclass
class FyersConfig:
    client_id: str
    secret_key: str
    redirect_uri: str
    app_id_type: int


def load_dotenv_like(path: Path) -> dict:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip()
    return env


def get_fyers_config() -> FyersConfig:
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
            new_lines.append("")
        new_lines.append(new_line)

    path.write_text("\n".join(new_lines) + "\n")


def restart_docker_services() -> str:
    try:
        cp = subprocess.run(
            ["docker", "compose", "up", "-d", "fyers-swing-bot", "penny-trader"],
            cwd=str(BASE_DIR),
            capture_output=True,
            text=True,
            check=True,
        )
        return cp.stdout.strip()
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(
            f"Failed to restart Docker services: {exc.stderr or exc.stdout}"
        ) from exc


def run_scanner_job() -> subprocess.CompletedProcess:
    """
    Run the penny scanner inside fyers-swing-bot:
      docker compose run --rm fyers-swing-bot python scripts/penny_scanner.py
    """
    try:
        cp = subprocess.run(
            [
                "docker",
                "compose",
                "run",
                "--rm",
                "fyers-swing-bot",
                "python",
                "scripts/penny_scanner.py",
            ],
            cwd=str(BASE_DIR),
            capture_output=True,
            text=True,
        )
        return cp
    except FileNotFoundError as exc:
        raise RuntimeError("docker not found on PATH") from exc


# ---------- FastAPI app ----------

app = FastAPI(title="FYERS Auth Dashboard API")

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

# ---------- Schemas ----------

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


class RecommendationsResponse(BaseModel):
    rows: List[dict]


class ExecutedTradesResponse(BaseModel):
    rows: List[dict]


class ClearExecutedResponse(BaseModel):
    message: str
    removed_rows: int


class PlaceOrderRequest(BaseModel):
    fyers_symbol: str
    side: str  # BUY / SELL
    qty: int


class PlaceOrderResponse(BaseModel):
    ok: bool
    message: str
    raw: dict


class RunScannerResponse(BaseModel):
    ok: bool
    message: str
    stdout: Optional[str] = None
    stderr: Optional[str] = None
    return_code: int


# ---------- Endpoints ----------

@app.get("/api/auth-url", response_model=AuthUrlResponse)
def generate_auth_url() -> AuthUrlResponse:
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

    return SaveTokenResponse(
        message="Token saved successfully" + (" and Docker services restarted." if body.restart_docker else "."),
        docker_output=docker_output,
    )


@app.get("/api/test-profile", response_model=ProfileResponse)
def test_profile() -> ProfileResponse:
    cfg = get_fyers_config()
    file_env = load_dotenv_like(CREDENTIALS_FILE)
    token = os.getenv("FYERS_ACCESS_TOKEN") or file_env.get("FYERS_ACCESS_TOKEN")

    if not token:
        raise HTTPException(
            status_code=400,
            detail="FYERS_ACCESS_TOKEN missing in credentials.env",
        )

    f = fyersModel.FyersModel(client_id=cfg.client_id, token=token)
    resp = f.get_profile()

    ok = str(resp.get("s", "")).lower() == "ok" and resp.get("code") == 200
    msg = "Authenticated OK" if ok else f"Auth failed: {resp.get('message', 'Unknown error')}"

    return ProfileResponse(ok=ok, message=msg, raw=resp)


@app.get("/api/recommendations", response_model=RecommendationsResponse)
def list_recommendations() -> RecommendationsResponse:
    import pandas as pd

    path = BASE_DIR / "data" / "penny_recommendations.csv"
    if not path.exists():
        return RecommendationsResponse(rows=[])

    df = pd.read_csv(path)
    return RecommendationsResponse(rows=df.to_dict(orient="records"))


@app.get("/api/executed", response_model=ExecutedTradesResponse)
def list_executed() -> ExecutedTradesResponse:
    import pandas as pd

    path = BASE_DIR / "data" / "penny_trades_executed.csv"
    if not path.exists():
        return ExecutedTradesResponse(rows=[])

    df = pd.read_csv(path)
    return ExecutedTradesResponse(rows=df.to_dict(orient="records"))


@app.post("/api/clear-error-executions", response_model=ClearExecutedResponse)
def clear_error_executions() -> ClearExecutedResponse:
    """
    Keep only successful/OK executions in penny_trades_executed.csv.
    """
    import pandas as pd

    path = BASE_DIR / "data" / "penny_trades_executed.csv"
    if not path.exists():
        return ClearExecutedResponse(message="File not found; nothing to clear.", removed_rows=0)

    df = pd.read_csv(path)
    if "status" not in df.columns:
        return ClearExecutedResponse(message="No 'status' column; nothing to clear.", removed_rows=0)

    before = len(df)
    keep_mask = df["status"].astype(str).str.lower().isin(["ok", "success", "filled", "completed"])
    df_clean = df[keep_mask].copy()
    removed = before - len(df_clean)
    df_clean.to_csv(path, index=False)

    return ClearExecutedResponse(
        message=f"Removed {removed} non-success rows; kept {len(df_clean)} successful executions.",
        removed_rows=removed,
    )


@app.post("/api/place-order", response_model=PlaceOrderResponse)
def place_order(body: PlaceOrderRequest) -> PlaceOrderResponse:
    cfg = get_fyers_config()
    file_env = load_dotenv_like(CREDENTIALS_FILE)
    token = os.getenv("FYERS_ACCESS_TOKEN") or file_env.get("FYERS_ACCESS_TOKEN")

    if not token:
        raise HTTPException(
            status_code=400,
            detail="FYERS_ACCESS_TOKEN missing in credentials.env",
        )

    fy = fyersModel.FyersModel(client_id=cfg.client_id, token=token)

    side = body.side.upper()
    if side not in ("BUY", "SELL"):
        raise HTTPException(status_code=400, detail="side must be BUY or SELL")

    order = {
        "symbol": body.fyers_symbol.strip(),
        "qty": int(body.qty),
        "type": 2,  # market
        "side": 1 if side == "BUY" else -1,
        "productType": "CNC",
        "limitPrice": 0,
        "stopPrice": 0,
        "validity": "DAY",
        "disclosedQty": 0,
        "offlineOrder": False,
        "orderTag": "dashboard",
    }

    resp = fy.place_order(order)
    ok = str(resp.get("s", "")).lower() == "ok"

    return PlaceOrderResponse(
        ok=ok,
        message=resp.get("message", ""),
        raw=resp,
    )


@app.post("/api/run-scanner", response_model=RunScannerResponse)
def run_scanner() -> RunScannerResponse:
    """
    Run scripts/penny_scanner.py inside fyers-swing-bot via docker compose.
    """
    try:
        cp = run_scanner_job()
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    ok = cp.returncode == 0
    msg = "Scanner completed successfully." if ok else "Scanner failed."

    return RunScannerResponse(
        ok=ok,
        message=msg,
        stdout=cp.stdout or "",
        stderr=cp.stderr or "",
        return_code=cp.returncode,
    )
