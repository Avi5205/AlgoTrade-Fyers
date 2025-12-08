#!/usr/bin/env bash
set -euo pipefail

echo "==============================================================="
echo " Wiring penny-reco service into docker-compose.yml"
echo "==============================================================="

# Resolve project root as the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "ERROR: $COMPOSE_FILE not found in $SCRIPT_DIR"
  exit 1
fi

echo "[1/3] Backing up existing docker-compose.yml to docker-compose.yml.bak ..."
cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"

echo "[2/3] Checking if 'penny-reco' service is already present ..."
if grep -q "penny-reco:" "$COMPOSE_FILE"; then
  echo "INFO: 'penny-reco' service already exists in $COMPOSE_FILE. No changes made."
else
  echo "INFO: Appending 'penny-reco' service definition to $COMPOSE_FILE ..."

  cat << 'EOF' >> "$COMPOSE_FILE"

  penny-reco:
    build: .
    container_name: fyers-penny-reco
    env_file:
      - ./config/credentials.env
    environment:
      # Capital & risk for the penny engine
      - PENNY_TEST_CAPITAL=500        # total capital for penny testing
      - PENNY_MAX_RISK_PCT=0.05       # 5% risk per trade
    volumes:
      - ./logs:/app/logs
      - ./data:/app/data
    command: ["python", "scripts/penny_reco_scheduler.py"]
    restart: unless-stopped
EOF

  echo "INFO: 'penny-reco' service appended successfully."
fi

echo "[3/3] Validating docker compose configuration (basic syntax check) ..."
if command -v docker-compose >/dev/null 2>&1; then
  docker-compose config >/dev/null && echo "docker-compose.yml looks valid."
elif command -v docker >/dev/null 2>&1; then
  docker compose config >/dev/null && echo "docker-compose.yml looks valid."
else
  echo "WARNING: docker / docker-compose not found in PATH. Skipping validation."
fi

echo "==============================================================="
echo " Done. You can now run:"
echo "   docker compose build"
echo "   docker compose up -d penny-reco"
echo "==============================================================="

