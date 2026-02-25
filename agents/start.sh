#!/bin/sh
# start.sh — container entrypoint.
#
# Runs two processes inside one container:
#   1. python main.py     — autonomous agents orchestrator (background)
#   2. uvicorn faucet_server:app — testnet wBTC faucet (foreground / PID-1 proxy)
#
# Signal handling:
#   Railway / Fly send SIGTERM to this script.  We forward it to both children
#   and exit cleanly.
#
# Port:
#   Railway sets $PORT automatically for web services.
#   Fly uses the internal_port declared in fly.toml.
#   Local dev falls back to FAUCET_PORT (default 8400).

set -e

HTTP_PORT="${PORT:-${FAUCET_PORT:-8400}}"

echo "[start] ── BTC Vault Agent Container ──"
echo "[start] HTTP port : $HTTP_PORT"
echo "[start] RPC       : ${STARKNET_RPC_URL:-not set}"

# ── 1. Launch agents orchestrator in background ────────────────────────────
echo "[start] Starting agents orchestrator …"
python main.py &
AGENTS_PID=$!

# ── 2. Forward SIGTERM / SIGINT to both processes ──────────────────────────
cleanup() {
    echo "[start] Shutdown signal received — stopping both processes …"
    kill "$AGENTS_PID" 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

# ── 3. Launch faucet HTTP server in foreground ─────────────────────────────
echo "[start] Starting faucet server on 0.0.0.0:$HTTP_PORT …"
uvicorn faucet_server:app \
    --host 0.0.0.0 \
    --port "$HTTP_PORT" \
    --log-level info

# Uvicorn exited (shouldn't happen normally) — also stop agents
echo "[start] Faucet server exited — stopping agents …"
kill "$AGENTS_PID" 2>/dev/null || true
