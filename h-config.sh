#!/usr/bin/env bash
###############################################################################
# Parallax Miner for HiveOS — Configuration Generator
#
# Reads HiveOS flight sheet variables and writes config.json
#
# Flight sheet fields:
#   Pool URL        → prlx node RPC  (e.g. http://192.168.1.100:8545)
#                     OR stratum proxy (e.g. 192.168.1.100:4444)
#   Wallet/Worker   → %WAL%.%WORKER_NAME%
#   Extra Config    → JSON: {"extra_args":"--gpu-id 0", "api_port": 21550}
###############################################################################

MINER_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$MINER_DIR"

# Source HiveOS rig config for CUSTOM_* variables
[[ -f /hive-config/rig.conf ]] && source /hive-config/rig.conf

# ── Parse wallet & worker from template ──────────────────────────────────────
WALLET=$(echo "$CUSTOM_TEMPLATE" | cut -d'.' -f1)
WORKER=$(echo "$CUSTOM_TEMPLATE" | cut -d'.' -f2-)
[[ -z "$WORKER" || "$WORKER" == "$WALLET" ]] && WORKER="${WORKER_NAME:-$(hostname)}"

# ── Pool / node URL ─────────────────────────────────────────────────────────
POOL_URL="${CUSTOM_URL:-http://127.0.0.1:8545}"

# Auto-detect mode from URL scheme
#   http://...  → "getwork"  (run embedded stratum proxy + SRBMiner)
#   anything else → "stratum" (connect SRBMiner directly)
if [[ "$POOL_URL" == http://* || "$POOL_URL" == https://* ]]; then
    MODE="getwork"
else
    MODE="stratum"
fi

# ── Parse optional extra config JSON ─────────────────────────────────────────
API_PORT=21550
PROXY_PORT=4444
EXTRA_ARGS=""

if [[ -n "$CUSTOM_USER_CONFIG" ]]; then
    API_PORT=$(echo "$CUSTOM_USER_CONFIG"   | jq -r '.api_port   // 21550' 2>/dev/null || echo 21550)
    PROXY_PORT=$(echo "$CUSTOM_USER_CONFIG" | jq -r '.proxy_port // 4444'  2>/dev/null || echo 4444)
    EXTRA_ARGS=$(echo "$CUSTOM_USER_CONFIG" | jq -r '.extra_args // ""'    2>/dev/null || echo "")
fi

# ── Write config.json ────────────────────────────────────────────────────────
cat > config.json <<EOF
{
    "wallet":     "${WALLET}",
    "worker":     "${WORKER}",
    "pool_url":   "${POOL_URL}",
    "mode":       "${MODE}",
    "proxy_port": ${PROXY_PORT},
    "api_port":   ${API_PORT},
    "algo":       "xhash",
    "extra_args": "${EXTRA_ARGS}"
}
EOF

echo "Parallax miner config generated:"
cat config.json
