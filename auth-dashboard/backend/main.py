# auth-dashboard/backend/main.py
from __future__ import annotations

import os
import subprocess
from pathlib import Path
from dataclasses import dataclass
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from fyers_apiv3 import fyersModel

BASE_DIR = Path(__file__).resolve().parents[2]  # .../fyers-swing-docker
CREDENTIALS_FILE = BASE_DIR / "config" / "credentials.env"


@dataclass
class FyersConfig:
    client_id: str
    secret_key: str
    redirect_uri: str
    app_id_type: int


def load_dotenv_like(path: Path) -> dict:
    """Very small parser for KEY=VALUE lines (no export, no quotes)."""
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
    Load FYERS config from environment variables first.
    If missing, fall back to credentials.env in the project root.
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


# def get_fyers_config() -> dict[str, str]:
#     env = read_env(ENV_PATH)
#     required = ["FYERS_CLIENT_ID", "FYERS_SECRET_KEY", "FYERS_REDIRECT_URI", "FYERS_APP_ID_TYPE"]
#     missing = [k for k in required if not env.get(k)]
#     if missing:
#         raise RuntimeError(f"Missing keys in credentials.env: {', '.join(missing)}")
#     return env


def restart_docker_services() -> str:
    """
    Restart only the trading-related containers so they pick up the new token.
    Assumes this script is run on the host machine with docker available.
    """
    try:
        # Run from project root
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


# ---------- FastAPI app ----------

app = FastAPI(title="FYERS Auth Dashboard API")

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


# ---------- Endpoints ----------

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

    return SaveTokenResponse(
        message="Token saved successfully" + (" and Docker services restarted." if body.restart_docker else "."),
        docker_output=docker_output,
    )


@app.get("/api/test-profile", response_model=ProfileResponse)
def test_profile() -> ProfileResponse:
    """
    Use current FYERS_ACCESS_TOKEN from credentials.env to call get_profile().
    """
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
