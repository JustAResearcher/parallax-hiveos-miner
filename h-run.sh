#!/usr/bin/env bash
###############################################################################
# Parallax Miner for HiveOS — Runner
#
# Two modes (auto-detected from Pool URL):
#
#   GETWORK MODE  (Pool URL = http://IP:8545)
#     Starts an embedded stratum-to-getwork proxy that connects to your
#     prlx full node, then launches SRBMiner pointing at the local proxy.
#     Each rig is fully self-contained — no separate proxy process needed.
#
#   STRATUM MODE  (Pool URL = IP:PORT or stratum+tcp://IP:PORT)
#     Connects SRBMiner directly to an external stratum proxy or pool.
#
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
WALLET=$(jq -r     '.wallet     // ""'       config.json)
WORKER=$(jq -r     '.worker     // "worker"' config.json)
POOL_URL=$(jq -r   '.pool_url   // ""'       config.json)
MODE=$(jq -r       '.mode       // "getwork"' config.json)
PROXY_PORT=$(jq -r '.proxy_port // 4444'     config.json)
API_PORT=$(jq -r   '.api_port   // 21550'   config.json)
EXTRA_ARGS=$(jq -r '.extra_args // ""'       config.json)

# ── Locate SRBMiner ──────────────────────────────────────────────────────────
SRBMINER=""
for sp in \
    "$MINER_DIR/srbminer/SRBMiner-MULTI" \
    "/hive/miners/srbminer-multi/SRBMiner-MULTI" \
    "/hive/miners/srbminer/SRBMiner-MULTI"; do
    if [[ -x "$sp" ]]; then
        SRBMINER="$sp"
        break
    fi
done

if [[ -z "$SRBMINER" ]]; then
    echo "SRBMiner-Multi not found — running installer..."
    bash h-install.sh
    SRBMINER="$MINER_DIR/srbminer/SRBMiner-MULTI"
    if [[ ! -x "$SRBMINER" ]]; then
        echo "FATAL: Could not find or install SRBMiner-Multi!"
        echo "Install it manually: hive-miners-install srbminer"
        exit 1
    fi
fi

echo "SRBMiner: $SRBMINER"
echo ""

# ── Cleanup handler ──────────────────────────────────────────────────────────
PROXY_PID=""
cleanup() {
    echo "Stopping parallax miner..."
    [[ -n "$PROXY_PID" ]] && kill "$PROXY_PID" 2>/dev/null
    pkill -f "xhash_stratum_proxy" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT INT TERM

# ── Kill lingering processes from previous runs ──────────────────────────────
pkill -f "xhash_stratum_proxy" 2>/dev/null
sleep 0.5

# ── Determine pool connection ────────────────────────────────────────────────
if [[ "$MODE" == "getwork" ]]; then
    ###########################################################################
    # GETWORK MODE — embedded stratum proxy → prlx node RPC
    ###########################################################################
    echo "╔══════════════════════════════════════════════╗"
    echo "║   Parallax Solo Miner — HiveOS              ║"
    echo "║   Mode: Self-contained (embedded proxy)     ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║   Node:   $POOL_URL"
    echo "║   Proxy:  localhost:$PROXY_PORT"
    echo "║   Wallet: ${WALLET:0:12}...${WALLET: -6}"
    echo "║   Worker: $WORKER"
    echo "╚══════════════════════════════════════════════╝"
    echo ""

    # Start embedded stratum proxy
    echo "Starting stratum proxy → $POOL_URL ..."
    python3 "$MINER_DIR/xhash_stratum_proxy.py" \
        --rpc-url "$POOL_URL" \
        --host 127.0.0.1 \
        --port "$PROXY_PORT" \
        --poll 0.5 \
        --log-level INFO \
        >> "$MINER_DIR/proxy.log" 2>&1 &
    PROXY_PID=$!

    sleep 3
    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        echo "FATAL: Stratum proxy failed to start!"
        echo "--- last 30 lines of proxy.log ---"
        tail -30 "$MINER_DIR/proxy.log"
        echo "---"
        echo ""
        echo "Check that your prlx node is running and accessible at $POOL_URL"
        echo "Node must be started with: --http --http.addr 0.0.0.0 --mine"
        exit 1
    fi
    echo "Proxy running (PID $PROXY_PID)"
    echo ""

    POOL_CONNECT="stratum+tcp://127.0.0.1:${PROXY_PORT}"
else
    ###########################################################################
    # STRATUM MODE — connect SRBMiner directly to external stratum
    ###########################################################################
    echo "╔══════════════════════════════════════════════╗"
    echo "║   Parallax Solo Miner — HiveOS              ║"
    echo "║   Mode: Direct stratum                      ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║   Pool:   $POOL_URL"
    echo "║   Wallet: ${WALLET:0:12}...${WALLET: -6}"
    echo "║   Worker: $WORKER"
    echo "╚══════════════════════════════════════════════╝"
    echo ""

    if [[ "$POOL_URL" == stratum* ]]; then
        POOL_CONNECT="$POOL_URL"
    else
        POOL_CONNECT="stratum+tcp://${POOL_URL}"
    fi
fi

# ── Launch SRBMiner-Multi ────────────────────────────────────────────────────
echo "Starting SRBMiner-Multi (algorithm: xhash)"
echo "  Pool:    $POOL_CONNECT"
echo "  Wallet:  $WALLET"
echo "  Worker:  $WORKER"
echo "  API:     http://localhost:$API_PORT"
[[ -n "$EXTRA_ARGS" ]] && echo "  Extra:   $EXTRA_ARGS"
echo ""

# Run SRBMiner in foreground — HiveOS manages the process lifecycle
"$SRBMINER" \
    --algorithm xhash \
    --pool "$POOL_CONNECT" \
    --wallet "$WALLET" \
    --worker "$WORKER" \
    --api-enable \
    --api-port "$API_PORT" \
    --disable-cpu \
    $EXTRA_ARGS
