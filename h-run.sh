#!/usr/bin/env bash
###############################################################################
# Parallax Miner for HiveOS — Runner  (v2.0 — HashWarp)
#
# HashWarp connects directly to the prlx node via getwork — no stratum
# proxy needed. Much simpler than the previous SRBMiner setup.
#
# Flight sheet Pool URL:  http://192.168.x.x:8545  (your prlx node RPC)
###############################################################################

MINER_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$MINER_DIR"

# Source rig config
[[ -f /hive-config/rig.conf ]] && source /hive-config/rig.conf

# Generate config if missing
if [[ ! -f config.json ]]; then
    bash h-config.sh
fi

# ── Read config ──────────────────────────────────────────────────────────────
POOL_URL=$(jq -r   '.pool_url   // ""'       config.json)
API_PORT=$(jq -r   '.api_port   // 21550'    config.json)
EXTRA_ARGS=$(jq -r '.extra_args // ""'       config.json)

# ── Safety net: recover pool URL if config has localhost default ──────────────
SAVED_URL_FILE="/tmp/parallax_saved_pool_url"

if [[ "$POOL_URL" == "http://127.0.0.1:8545" || -z "$POOL_URL" ]]; then
    echo "WARNING: config.json has default/empty pool_url ($POOL_URL)"
    # Try /tmp/ saved file first (most reliable)
    if [[ -s "$SAVED_URL_FILE" ]]; then
        POOL_URL=$(cat "$SAVED_URL_FILE")
        echo "  Recovered from $SAVED_URL_FILE: $POOL_URL"
    else
        # Try rig.conf
        [[ -f /hive-config/rig.conf ]] && source /hive-config/rig.conf
        if [[ -n "$CUSTOM_URL" ]]; then
            POOL_URL="$CUSTOM_URL"
            echo "  Recovered from rig.conf CUSTOM_URL: $POOL_URL"
        else
            # Last resort: grep for any http URL with :8545 in rig.conf
            GREP_URL=$(grep -oP 'http://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:8545' /hive-config/rig.conf 2>/dev/null | head -1)
            if [[ -n "$GREP_URL" ]]; then
                POOL_URL="$GREP_URL"
                echo "  Recovered by grep from rig.conf: $POOL_URL"
            else
                echo "FATAL: No valid pool URL found anywhere!"
                echo "  config.json pool_url: $(jq -r '.pool_url' config.json 2>/dev/null)"
                echo "  $SAVED_URL_FILE: not found"
                echo "  CUSTOM_URL from rig.conf: ''"
                echo "  grep rig.conf for :8545: no match"
                echo "Set Pool URL in your HiveOS flight sheet to your prlx node RPC (e.g. http://192.168.1.100:8545)"
                exit 1
            fi
        fi
    fi
    # Save it so future restarts work
    echo "$POOL_URL" > "$SAVED_URL_FILE"
fi

# ── Convert URL to HashWarp getwork format ───────────────────────────────────
# Flight sheet URL: http://192.168.x.x:8545 → getwork://192.168.x.x:8545
if [[ "$POOL_URL" == http://* ]]; then
    CONNECT_URL="getwork://${POOL_URL#http://}"
elif [[ "$POOL_URL" == https://* ]]; then
    CONNECT_URL="getwork://${POOL_URL#https://}"
elif [[ "$POOL_URL" == getwork://* || "$POOL_URL" == stratum* ]]; then
    CONNECT_URL="$POOL_URL"
else
    # Bare IP:PORT
    CONNECT_URL="getwork://${POOL_URL}"
fi

# ── Locate HashWarp ──────────────────────────────────────────────────────────
HASHWARP="$MINER_DIR/hashwarp"

if [[ ! -x "$HASHWARP" ]]; then
    echo "HashWarp not found — running installer..."
    bash h-install.sh
    if [[ ! -x "$HASHWARP" ]]; then
        echo "FATAL: Could not find or install HashWarp!"
        exit 1
    fi
fi

# ── Banner ───────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════╗"
echo "║   Parallax Solo Miner — HiveOS (HashWarp)   ║"
echo "╠══════════════════════════════════════════════╣"
echo "║   Node:   $POOL_URL"
echo "║   Connect: $CONNECT_URL"
echo "║   API:    http://localhost:$API_PORT"
echo "╚══════════════════════════════════════════════╝"
echo ""

echo "Starting HashWarp..."
echo "  Pool:    $CONNECT_URL"
echo "  API:     http://localhost:$API_PORT"
[[ -n "$EXTRA_ARGS" ]] && echo "  Extra:   $EXTRA_ARGS"
echo ""

# ── Launch HashWarp in foreground ────────────────────────────────────────────
# --HWMON 1    → report GPU temp & fan (needed for HiveOS stats)
# --nocolor    → clean log output
# --syslog     → strip timestamps (HiveOS adds its own)
# --api-port   → API for h-stats.sh to query
"$HASHWARP" \
    -P "$CONNECT_URL" \
    --api-port "$API_PORT" \
    --HWMON 1 \
    --nocolor \
    --syslog \
    $EXTRA_ARGS
