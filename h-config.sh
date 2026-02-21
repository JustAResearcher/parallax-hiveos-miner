#!/usr/bin/env bash
###############################################################################
# Parallax Miner for HiveOS -- Configuration Generator  (v2.0 — HashWarp)
#
# Flight sheet fields:
#   Pool URL        -> prlx node RPC  (e.g. http://192.168.1.100:8545)
#   Wallet/Worker   -> %WAL%.%WORKER_NAME%
#   Extra Config    -> JSON: {"extra_args":"--cl-global-work 4194304", "api_port": 21550}
#
# Pool URL is persisted to /tmp/ so it survives HiveOS wiping the miner
# directory between h-config.sh calls.
###############################################################################

MINER_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$MINER_DIR"

# Persistent storage OUTSIDE miner dir (survives miner reinstalls)
SAVED_URL_FILE="/tmp/parallax_saved_pool_url"

echo "=== h-config.sh v2.0 (HashWarp) ==="

# Source HiveOS rig config for CUSTOM_* variables
[[ -f /hive-config/rig.conf ]] && source /hive-config/rig.conf

echo "  CUSTOM_URL='$CUSTOM_URL'"
echo "  CUSTOM_TEMPLATE='$CUSTOM_TEMPLATE'"

# Debug: dump all CUSTOM_ vars from rig.conf
echo "  --- All CUSTOM_ vars in rig.conf ---"
grep -i "CUSTOM" /hive-config/rig.conf 2>/dev/null || echo "  (none found)"
echo "  --- end ---"

# -- Pool / node URL --
POOL_URL="$CUSTOM_URL"

# -- Parse wallet & worker from template (kept for future pool support) --
WALLET=$(echo "$CUSTOM_TEMPLATE" | cut -d'.' -f1)
WORKER=$(echo "$CUSTOM_TEMPLATE" | cut -d'.' -f2-)
[[ -z "$WORKER" || "$WORKER" == "$WALLET" ]] && WORKER="${WORKER_NAME:-$(hostname)}"

# ── PERSIST / RECOVER ────────────────────────────────────────────────────────
# Save to /tmp/ which is OUTSIDE the miner directory and won't be wiped.
if [[ -n "$POOL_URL" ]]; then
    echo "$POOL_URL" > "$SAVED_URL_FILE"
    echo "  Saved pool URL to $SAVED_URL_FILE: $POOL_URL"
elif [[ -s "$SAVED_URL_FILE" ]]; then
    POOL_URL=$(cat "$SAVED_URL_FILE")
    echo "  Recovered pool URL from $SAVED_URL_FILE: $POOL_URL"
else
    # Last resort: grep rig.conf for any http URL with :8545
    GREP_URL=$(grep -oP 'http://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:8545' /hive-config/rig.conf 2>/dev/null | head -1)
    if [[ -n "$GREP_URL" ]]; then
        POOL_URL="$GREP_URL"
        echo "  Recovered pool URL by grep from rig.conf: $POOL_URL"
    else
        echo "  WARNING: No pool URL found anywhere — using localhost default"
        POOL_URL="http://127.0.0.1:8545"
    fi
fi

# -- Parse optional extra config JSON --
API_PORT=21550
EXTRA_ARGS=""

if [[ -n "$CUSTOM_USER_CONFIG" ]]; then
    API_PORT=$(echo "$CUSTOM_USER_CONFIG"   | jq -r '.api_port   // 21550' 2>/dev/null || echo 21550)
    EXTRA_ARGS=$(echo "$CUSTOM_USER_CONFIG" | jq -r '.extra_args // ""'    2>/dev/null || echo "")
fi

# -- Write config.json --
cat > config.json <<EOF
{
    "pool_url":   "${POOL_URL}",
    "wallet":     "${WALLET}",
    "worker":     "${WORKER}",
    "api_port":   ${API_PORT},
    "algo":       "xhash",
    "extra_args": "${EXTRA_ARGS}"
}
EOF

echo "Parallax miner config generated:"
cat config.json
