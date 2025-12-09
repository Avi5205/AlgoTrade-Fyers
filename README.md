# AlgoTrade-Fyers

# Fyers Swing Docker – Full Technical Specification & Runbook

> NOTE: This document is written to enable a future engineer to recreate the **`fyers-swing-docker`** project on a clean machine as closely as possible to the original behavior observed in this ChatGPT session.  
> Some details of the original repository structure are not visible inside this environment; those are marked explicitly as **TODO (fill in from local repo)** and should be completed by the project owner.

---

## 1. Project Overview

### 1.1 Name

- **Project name:** `fyers-swing-docker`
- **Short name:** “Fyers Swing Bot” / “Penny Trader”

### 1.2 Purpose

This project runs a **fully automated penny‑stock swing trading workflow** against the **FYERS** Indian brokerage API. It:

1. Scans NSE/BSE stocks and generates penny‑stock recommendations.
2. Enriches them with fundamentals and technical metrics.
3. Writes recommendations into CSV files under `data/`.
4. Periodically runs an **auto‑trader** that places CNC market orders via FYERS for recommended symbols that:
   - Have a valid FYERS symbol mapping, and
   - Have not already been traded successfully on the current trading day.
5. Persists executions and errors for auditability and de‑duplication.

### 1.3 Business Problem

Retail traders often want **disciplined, repeatable penny‑stock entries** but do not have the time to:

- Scan markets manually.
- Apply consistent filters.
- Place orders reliably during trading hours.

This project automates that pipeline end‑to‑end, so that once configured, it can:

- Run continuously via Docker.
- Place orders via FYERS during Indian cash‑market hours.
- Avoid duplicate trades for the same symbol in the same session.

### 1.4 Primary Users / Systems

- **Primary user:** Individual trader (you) who owns the FYERS account.
- **External system:** FYERS trading platform via the **`fyers_apiv3`** Python SDK.
- **Runtime host:** Local development machine (macOS in this session) running Docker.

### 1.5 High‑Level Components

1. **Dockerized penny‑trader service (`penny-trader`)**
   - Python 3.11 container
   - Runs the penny auto‑trader loop on a schedule.
2. **Optional additional service (`fyers-swing-bot`)**
   - Another Python service image built from the same repo (not deeply inspected here).
3. **Data layer (`data/` directory)**
   - CSV and JSON files representing scan results, fundamentals, recommendations, executed trades, and open positions.
4. **Configuration & secrets**
   - `.env` file and/or environment variables for FYERS credentials.
5. **Shell helper scripts** (local)
   - Used earlier in this session to patch, clean, and inspect the project. These are not intended to be part of the stable “product” but are documented where relevant.

---

## 2. Environment & Stack

### 2.1 Languages & Runtimes

- **Python:** 3.11 (from `python:3.11-slim` Docker base image)
- **Shell:** `bash` / `sh` (for local helper scripts and Docker entrypoints)

### 2.2 Frameworks, Libraries & SDKs (Python)

From observed usage and Docker image behavior:

- **Core:**
  - `fyers-apiv3` – FYERS trading API SDK.
  - `pandas` – CSV I/O and DataFrame transforms.
  - `python-dateutil` or stdlib `datetime` – for date/timestamps.
  - `zoneinfo` (stdlib in Python 3.11) – for India Standard Time (IST) timezone handling.
- **Likely dependencies in `requirements.txt` (exact versions must be taken from repo):**
  - `requests`
  - `numpy`
  - Logging is done via Python stdlib `logging` module.

> TODO (fill in from local `requirements.txt`):
>
> ```text
> fyers-apiv3==x.y.z
> pandas==x.y.z
> numpy==x.y.z
> requests==x.y.z
> ...
> ```

### 2.3 OS & Hardware Assumptions

- **Dev host:** macOS (Apple Silicon or Intel; session was from macOS 10.15.7 on Intel).
- **Runtime environment:** Docker containers based on `python:3.11-slim` (Debian/Ubuntu‑like userspace, x86_64).
- **No direct Windows assumptions**; Windows users should use WSL2 + Docker or a Linux host.

### 2.4 Tools & Services

- **Docker Engine + Docker Compose**
  - Project uses `docker-compose.yml` with `version` key (Compose v2 warns it is obsolete; safe to ignore).
- **External SaaS / APIs**
  - FYERS trading API via `fyers-apiv3`.
- **Storage:**
  - Local filesystem mounted into container (e.g. `./data` → `/app/data`).
- **No central database, queue, or cache** is used. All persistence is via files.

> TODO: Confirm if there is any CI/CD, cloud deployment, or remote scheduler (e.g., cron on a VPS). If yes, document here.

---

## 3. Repository & Project Structure

> Warning: Only a subset of files and folders were visible in this session. The structure below combines what was observed with reasonable, clearly marked placeholders.

### 3.1 High‑Level Directory Tree (approximate)

```text
fyers-swing-docker/
├─ Dockerfile
├─ docker-compose.yml
├─ requirements.txt
├─ .env.example
├─ .env                  # NOT committed; local only
├─ scripts/
│  ├─ penny_auto_trader.py
│  └─ (other helper/cron scripts)        # TODO: list from repo
├─ data/
│  ├─ penny_recommendations.csv
│  ├─ penny_trades_executed.csv
│  ├─ penny_executed_log.csv
│  ├─ penny_fundamentals.csv
│  ├─ penny_scan_report.csv
│  ├─ profitability_report_yf.csv
│  ├─ penny_open_positions.json
│  └─ (backups) *.bak
├─ logs/
│  └─ (runtime logs from containers)     # volume or bind-mount target
└─ (other project files as per repo)     # TODO: fill in full tree
```

### 3.2 Folder Purposes

- **Root (`fyers-swing-docker/`)**
  - Docker and Compose definitions.
  - Global Python package requirements.
  - Global `.env` holding API credentials and configuration.

- **`scripts/`**
  - All business logic Python modules.
  - `penny_auto_trader.py`: orchestrates recommendation reading and order placement.
  - Additional modules may exist for scanning, fundamentals, and data generation (not fully visible here).

- **`data/`**
  - All runtime CSV/JSON artifacts:
    - Scan outputs, fundamentals, recommendations, executions, open positions.
  - Intended to be bind‑mounted into the container so that runs are persistent.

- **`logs/`**
  - Target for container logs, if configured as a volume. In this session logs were accessed via `docker logs` instead.

### 3.3 Key Files

#### 3.3.1 `Dockerfile` (for `penny-trader` and `fyers-swing-bot` images)

Approximate behavior based on build logs:

- `FROM python:3.11-slim`
- `RUN apt-get update && apt-get install -y --no-install-recommends [...]`
- `WORKDIR /app`
- `COPY requirements.txt /app/requirements.txt`
- `RUN pip install --no-cache-dir -r requirements.txt`
- `COPY . /app`
- `RUN mkdir -p /app/logs /app/data`
- `CMD` entrypoint likely runs the main Python module (e.g., a scheduler script or `penny_auto_trader.py`).

> TODO: Paste full Dockerfile content here from local repo.

#### 3.3.2 `docker-compose.yml`

Observations:

- Contains at least two services:
  - `penny-trader`
  - `fyers-swing-bot`
- Uses default network `fyers-swing-docker_default` (auto‑created).
- Emits a warning: `the attribute 'version' is obsolete, it will be ignored`.
- Binds project directory into `/app` and likely maps `./data` and `./logs` to container paths.

> TODO: Paste exact `docker-compose.yml` content here, including ports, volumes, and environment sections.

#### 3.3.3 `scripts/penny_auto_trader.py`

This is the core module observed in detail. The key pieces are:

- **Dataclass `TradeInstruction`**
  - Fields:
    - `symbol: str`
    - `fyers_symbol: str`
    - `exchange: str`
    - `name: str`
    - `side: str` (`"BUY"` or `"SELL"`, though current version effectively uses `"BUY"` only)
    - `qty: int`
    - `price: float`
    - `stop_loss: float`
    - `target1: float`
    - `target2: float`

- **Class `FyersTradingClient`**
  - Wraps FYERS SDK:
    - Constructor checks `FYERS_CLIENT_ID` and `FYERS_ACCESS_TOKEN` env vars; raises `ValueError` if missing.
    - `place_market_order(self, instr: TradeInstruction) -> dict`:
      - Constructs order dict:
        ```python
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
            "orderTag": "pennyauto",  # patched from 'penny-auto'
        }
        ```
      - Calls `self._client.place_order(order)` and logs response.
      - Returns FYERS raw response dict.

- **Class `PennyAutoTrader`**
  - Constructor parameters:
    - `fyers_client: FyersTradingClient`
    - `recommendations_path: Path` → default `data/penny_recommendations.csv`
    - `executed_log_path: Path` → default `data/penny_trades_executed.csv`
  - Methods:
    - `_load_executed_today()`
      - Reads `penny_trades_executed.csv` if exists.
      - Validates required columns: `"symbol", "executed_date"`.
      - If missing: logs a warning and returns an empty DataFrame with those columns.
      - Filters to rows where `executed_date == date.today()`.
    - `_append_executed(instr, resp, status)`
      - Appends a new row with:
        - `executed_date` – `date.today().isoformat()`
        - `executed_time` – `datetime.now().isoformat(timespec="seconds")`
        - `symbol`, `fyers_symbol`, `side`, `qty`, `price`
        - `status` – `"ok" | "error" | "exception"`
        - `raw_response` – `str(resp)`
      - Concatenates with existing CSV if readable; otherwise overwrites.
    - `_build_instructions()`
      - Loads `penny_recommendations.csv`.
      - If missing or empty: logs warning, returns `[]`.
      - Calls `_load_executed_today()` to get today’s executed trades.
      - Defines helper `_is_success(row)` (intended semantics – see note below):
        ```python
        def _is_success(row) -> bool:
            status = str(row.get("status", "")).lower()
            return status in ("ok", "success", "filled", "completed")
        ```
      - Builds set `already` of symbols meeting `_is_success(row)` and logged for today.
      - Iterates over recommendation rows:
        - If symbol in `already`: logs `"Trade for %s already executed today; skipping."`
        - If `fyers_symbol` missing/blank: warns and skips.
        - If `qty <= 0`: warns and skips.
        - Computes `price` from `recommended_entry` or `cmp`.
        - Computes default `stop_loss`, `target1`, `target2` if not present.
        - Creates `TradeInstruction` with side `"BUY"` and appends to list.
      - Returns `List[TradeInstruction]`.

    - `run_once()`
      - Logs that it is loading recommendations.
      - Builds instructions via `_build_instructions()`.
      - If no instructions: logs warning and returns.
      - For each instruction:
        - Calls `fyers_client.place_market_order(instr)`.
        - Sets `status = "ok"` if `resp.get("s").lower() == "ok"`; else `"error"`.
        - Logs success or error.
        - `_append_executed(instr, resp, status)`.
      - Catches exceptions, logs stack trace, and appends `status="exception"` entries.

- **`main()` function** (patched in this session)
  - Configures logging:
    ```python
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )
    ```
  - Applies trading‑hours guard for NSE cash market using IST timezone:
    ```python
    from datetime import datetime, time
    from zoneinfo import ZoneInfo

    now_ist = datetime.now(ZoneInfo("Asia/Kolkata"))
    market_open = time(9, 15)
    market_close = time(15, 30)

    if not (market_open <= now_ist.time() <= market_close):
        logging.info(
            "Outside NSE cash-market hours (09:15:00–15:30:00 IST); "
            "skipping auto-trades. Current IST time: %s",
            now_ist.time(),
        )
        return
    ```
  - Instantiates `FyersTradingClient` from env vars.
  - Instantiates `PennyAutoTrader` and calls `run_once()`.
  - Logs completion message.

> IMPORTANT BEHAVIOR TO PRESERVE:
>
> - `orderTag` **must be alphanumeric only**; `pennyauto` works, `penny-auto` fails at FYERS API level.
> - The de‑duplication relies on `penny_trades_executed.csv` having successful rows for the current date.
> - Recommendations without `fyers_symbol` or `qty` are skipped and must not crash the loop.

#### 3.3.4 Data Files

- **`data/penny_recommendations.csv`**
  - Contains one row per recommended penny stock.
  - Columns (as seen in this session, example row):
    ```text
    symbol,exchange,name,fyers_symbol,cmp,prev_close,day_high,day_low,52w_low,52w_high,
    target1,target2,risk_per_share,qty,position_value,stop_loss_pct,upside_pct,
    downside_pct,rr,conviction,trend_label,recommendation_time
    ```
  - Example (PREMIERPOLYFILM row after patch):
    ```text
    PREMIERPOLYFILM,NSE,Premier Polyfilm,NSE:PREMIERPOL-EQ,44.4,42.18,45.29,44.4,
    35.52,49.73,55.5,8.88,2,88.8,17.76,1.25,12.0,0.0,12.0,High,
    No trend (no EOD data),2025-12-08T17:49:29
    ```

- **`data/penny_trades_executed.csv`**
  - Execution log; columns:
    ```text
    executed_date,executed_time,symbol,fyers_symbol,side,qty,price,status,raw_response
    ```
  - Example rows (before cleanup and after API issues):
    - `status="error"` rows produced for authentication or `orderTag` validation errors.
    - After a successful patch, rows with `status="ok"` and FYERS order IDs are recorded.

- **`data/penny_executed_log.csv`**
  - A simplified log used earlier; current logic is compatible with `penny_trades_executed.csv` by checking `status` for success.
  - Columns (header):
    ```text
    symbol,executed_date,qty,fyers_symbol,order_id,status
    ```

- **`data/penny_fundamentals.csv`**, **`data/penny_scan_report.csv`**, **`data/profitability_report_yf.csv`**
  - Input data for signals and risk calculations (not fully documented here). They are read by upstream scanner/fundamental modules to generate recommendations.

- **`data/penny_open_positions.json`**
  - JSON object representing open positions; example content observed:
    ```json
    {}
    ```

---

## 4. Configuration & Secrets

### 4.1 Environment Variables

Primary secrets:

- `FYERS_CLIENT_ID`
- `FYERS_ACCESS_TOKEN`

Typical `.env` file (do not commit to VCS):

```env
FYERS_CLIENT_ID=F08DGQJ3AM-100
FYERS_ACCESS_TOKEN=eyJhbGciOiJIUzI1NiIsInR5c...
```

> Use a **dummy value** in documentation; never store real tokens.

Additional config env vars (if present in repo) should be documented here:

> TODO: Add any additional env vars used in code (e.g., log level, poll interval, symbol filters).

### 4.2 Environment‑Specific Configs

At present, the project appears to have a **single `.env`** used for both local and “production” (local machine) since everything runs via Docker on your Mac.

If introducing multiple environments, recommended pattern:

- `.env.local`
- `.env.prod`

And specify `env_file` in `docker-compose.yml` per service scoped to environment.

### 4.3 Secret Storage & Injection

- Secrets are stored in `.env` file at repo root.
- Docker Compose reads `.env` automatically and provides values as container environment.
- Python code reads via `os.getenv("FYERS_CLIENT_ID")` and `os.getenv("FYERS_ACCESS_TOKEN")`.

---

## 5. Data & Integrations

### 5.1 FYERS API Integration

- **Python SDK:** `fyers_apiv3.fyersModel.FyersModel`
- **Authentication:**
  - Provided via `client_id` and `access_token` when instantiating `FyersModel`.
- **Order Placement:**
  - Method: `place_order(order_dict)`
  - Important order fields:
    - `symbol`: e.g. `"NSE:SYNCOMF-EQ"`
    - `qty`: integer, number of shares.
    - `type`: `2` for **Market** order.
    - `side`: `1` for BUY, `-1` for SELL.
    - `productType`: `"CNC"` (delivery).
    - `validity`: `"DAY"`.
    - `offlineOrder`: `False`.
    - `orderTag`: `"pennyauto"` **(must be alphanumeric)**.

- **Response formats (examples):**
  - Success:
    ```json
    {
      "code": 1101,
      "message": "Successfully placed order",
      "s": "ok",
      "id": "25120800401919"
    }
    ```
  - Error – invalid `orderTag` (non‑alphanumeric):
    ```json
    {
      "code": -50,
      "message": "orderTag: Only alphanumeric characters allowed",
      "s": "error"
    }
    ```
  - Error – invalid symbol:
    ```json
    {
      "code": -50,
      "message": "The input symbol is invalid.",
      "s": "error"
    }
    ```

- **Failure handling in code:**
  - Treats `"s": "ok"` as success, everything else as `status="error"`.
  - Errors are logged and persisted in `penny_trades_executed.csv`.
  - De‑duplication logic will **not** count error rows as “executed”; retries may occur in future runs until error fixed.

### 5.2 Data Schemas

Documented above in §3.3.4. For exact field types, treat all CSV fields as strings initially; cast to numeric/float as needed in code (e.g., `qty`, `price`, `stop_loss`, etc.).

---

## 6. Execution Workflows

### 6.1 Local (non‑Docker) Workflow (optional)

Although the primary path is via Docker, it is possible to run locally (if Python 3.11 and dependencies are installed). Generic steps:

1. Create virtualenv and install dependencies:
   ```bash
   python3.11 -m venv .venv
   source .venv/bin/activate
   pip install -r requirements.txt
   ```
2. Set env vars:
   ```bash
   export FYERS_CLIENT_ID=...
   export FYERS_ACCESS_TOKEN=...
   ```
3. Ensure `data/` contains valid CSVs (see §3.3.4).
4. Run auto‑trader once:
   ```bash
   python scripts/penny_auto_trader.py
   ```

> Note: The trading‑hours guard uses system time and `Asia/Kolkata` timezone; ensure your system has it configured correctly.

### 6.2 Docker / Compose Workflow (primary)

#### 6.2.1 Build

From repository root:

```bash
docker compose build penny-trader
# Optionally:
docker compose build fyers-swing-bot
```

#### 6.2.2 Run

```bash
docker compose up -d penny-trader
```

View logs:

```bash
docker logs --since 5m -f fyers-penny-trader
```

Observed logs when outside market hours:

```text
[INFO] Outside NSE cash-market hours (09:15:00–15:30:00 IST); skipping auto-trades. Current IST time: 18:15:02.147164
```

Observed logs when orders are successfully placed:

```text
[INFO] Placing BUY order: {... 'symbol': 'NSE:SYNCOMF-EQ', 'qty': 8, ..., 'orderTag': 'pennyauto'}
[INFO] Order response for NSE:SYNCOMF-EQ: {'code': 1101, 'message': 'Successfully placed order', 's': 'ok', 'id': '25120800403268'}
[INFO] Order placed successfully for SYNCOMF
```

#### 6.2.3 Stop & Cleanup

Stop services:

```bash
docker compose down
```

Prune containers and images (careful – removes other local Docker artifacts too):

```bash
docker system prune -a
```

---

## 7. Core Logic & Important Modules

Summarized earlier in §3.3.3. Key invariants to preserve:

- **De‑duplication:** Only successful trades (`status in ("ok", "success", "filled", "completed")`) block further trades for that symbol on the same day.
- **Trading hours:** Guard must prevent orders outside NSE cash‑market hours (09:15–15:30 IST).
- **Error resilience:** Missing columns in old CSVs should not crash; return safe defaults and log warnings.
- **Symbol validity:**
  - `fyers_symbol` must be present for auto‑trade.
  - Format like `"NSE:PREMIERPOL-EQ"` must be correct for FYERS API.

---

## 8. State, Storage & Persistence

- All persistent state is stored in `data/`:
  - Executed trades log.
  - Recommendations and scan outputs.
  - Fundamentals and profitability reports.
  - Open positions JSON.
- No relational or NoSQL database is used.
- Backups:
  - In this session, manual backup was created as `*.csv.bak` before patching (e.g., `penny_recommendations.csv.bak`).
  - Recommended practice:
    - Regularly copy `data/` to a timestamped backup directory.
- Storage assumptions:
  - `data/` directory is writable by the user and by the container via a bind mount or Docker volume.
  - No special filesystem features required.

---

## 9. Build, Run & Deployment Commands

### 9.1 Prerequisites

- Docker Engine + Docker Compose v2 installed.
- Python 3.11 (only needed if running locally without Docker).
- Valid FYERS account, client ID, and access token.

### 9.2 End‑to‑End Setup on a Clean Machine (Local + Docker)

1. **Clone repository:**
   ```bash
   git clone <REPO_URL> fyers-swing-docker
   cd fyers-swing-docker
   ```
2. **Create `.env` from template:**
   ```bash
   cp .env.example .env
   # Edit .env and fill FYERS_CLIENT_ID and FYERS_ACCESS_TOKEN
   ```
3. **Prepare data directory (first‑time):**
   - Create `data/` if missing.
   - Place initial CSVs or let upstream scan jobs generate them.
   - At minimum, ensure `penny_recommendations.csv` has the correct header.
4. **Build image:**
   ```bash
   docker compose build penny-trader
   ```
5. **Run penny‑trader:**
   ```bash
   docker compose up -d penny-trader
   ```
6. **Verify logs:**
   ```bash
   docker logs --since 5m -f fyers-penny-trader
   ```
   - During market hours: expect actual order placement.
   - Outside market hours: expect “Outside NSE cash-market hours” messages only.

### 9.3 CI/CD (if any)

> TODO: Document any GitHub Actions, GitLab CI, or other pipelines if the project is deployed to a remote server. Include build and deploy steps.

---

## 10. Testing, Logging & Observability

### 10.1 Testing

No automated tests were run in this session for this repo, but recommended structure:

- `tests/` directory with unit tests for:
  - CSV parsing.
  - De‑duplication logic.
  - Order creation logic (`FyersTradingClient.place_market_order`).
- Command to run tests (if `pytest` configured):
  ```bash
  docker compose run --rm penny-trader pytest
  ```

### 10.2 Logging

- Uses Python `logging` with `INFO` level and format:
  ```text
  %(asctime)s [%(levelname)s] %(message)s
  ```
- Logs are visible via `docker logs fyers-penny-trader`.
- Key log events:
  - Start/stop of auto‑trader run.
  - Trading hour guard messages.
  - Decisions to skip already executed symbols.
  - Order placement requests and responses.
  - Exceptions and errors.

### 10.3 Metrics & Dashboards

None implemented in this session. Future enhancements could include:

- Exporting metrics to Prometheus.
- Dashboards (e.g., Grafana) for symbol‑level performance.

---

## 11. Security & Access

- Auth is purely via **FYERS API token** and client ID in env vars.
- No additional user authentication or web interface is present.
- Network security is handled by host; container only egresses to FYERS API.

Best practices:

- Ensure `.env` is not committed to Git.
- Rotate FYERS tokens regularly.
- Restrict access to the host machine running the trader.

---

## 12. Operational Knowledge

### 12.1 Common Tasks

#### Restart penny‑trader

```bash
docker compose restart penny-trader
```

#### Update code and redeploy

```bash
git pull origin main
docker compose build penny-trader
docker compose up -d penny-trader
```

#### Flush executed trades log (e.g. for testing)

```bash
# Reset to header only (dangerous; do not do in production without backup)
cp data/penny_trades_executed.csv data/penny_trades_executed.csv.bak_$(date +%Y%m%d_%H%M%S)
echo "executed_date,executed_time,symbol,fyers_symbol,side,qty,price,status,raw_response" \
  > data/penny_trades_executed.csv
```

### 12.2 Known Failure Modes & Fixes

1. **`Could not authenticate the user`**
   - Root cause: invalid or expired `FYERS_ACCESS_TOKEN` or `FYERS_CLIENT_ID`.
   - Fix:
     - Refresh FYERS access token following broker’s auth flow.
     - Update `.env` and restart containers.

2. **`orderTag: Only alphanumeric characters allowed`**
   - Root cause: `orderTag` contained hyphen (`"penny-auto"`).
   - Fix:
     - Patch code to use `"pennyauto"` (no hyphen).
     - Rebuild Docker image and restart service.

3. **`The input symbol is invalid.`**
   - Root cause: invalid or `nan` `fyers_symbol` value (e.g., missing mapping in recommendations CSV).
   - Fix:
     - Correct `fyers_symbol` in `penny_recommendations.csv` (e.g., `NSE:PREMIERPOL-EQ`).
     - Ensure upstream scanners correctly populate this column.

4. **Multiple repeated error orders for same symbol**
   - Root cause: de‑duplication only considers successful statuses; error rows do not block retries.
   - Fix:
     - Either fix the underlying cause (token, orderTag, symbol).
     - Or temporarily remove invalid rows from `penny_recommendations.csv` if you want to stop retrying.

### 12.3 Performance Characteristics

- Lightweight; CPU and memory usage are minimal for the auto‑trader.
- Critical time‑sensitive step is invoking the FYERS API; latency depends on network.

---

## 13. Known Issues, TODOs & Quirks

- De‑duplication does not treat `error` rows as “executed.” This is usually desired but can cause repeated error logs for broken symbols.
- CSV schemas must match expected headers; manual edits must keep field names intact.
- The system currently only supports **BUY** CNC market orders; SELL logic or more advanced order types would require code changes.

---

## 14. Replication & Automation Requirements

To replicate the project 1:1 on a new machine, ensure the following:

1. You have:
   - A FYERS account with API access.
   - Client ID and access token.
   - Docker + Docker Compose.
2. You can access the private repository and clone it.
3. You can create or copy the following:
   - `.env` with valid credentials.
   - `data/` directory with either sample or real CSVs.
4. You follow the exact steps in §9.2 (“End‑to‑End Setup on a Clean Machine”).

Any additional manual steps specific to your environment (e.g., obtaining tokens from a web UI) should be documented as a numbered checklist below:

> TODO: Add step‑by‑step FYERS token acquisition instructions here.

---

## 15. Textual Architecture Diagram (for Redrawing Later)

You can recreate the architecture diagram as follows:

1. **User / Machine**
   - Box: “Trader’s Mac (Docker host)”
   - Inside: Docker Engine + `docker-compose`.

2. **Container: `penny-trader`**
   - Arrows:
     - Reads from `./data` (bind‑mounted to `/app/data`).
     - Reads `.env` → env vars.
     - Calls FYERS API over HTTPS.

3. **Data Storage**
   - Folder: “data/”
     - Files: `penny_recommendations.csv`, `penny_trades_executed.csv`, `penny_fundamentals.csv`, `penny_scan_report.csv`, `penny_open_positions.json`.

4. **External Service**
   - Box: “FYERS Trading API”
     - Arrow back to container for responses.
     - Created orders visible in FYERS frontend.

This completes the self‑contained documentation for recreating and understanding the `fyers-swing-docker` project as observed in this session.
