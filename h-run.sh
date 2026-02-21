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

# ── GPU auto-tuning ──────────────────────────────────────────────────────────
# Detect GPU model and set optimal HashWarp CUDA parameters.
# The HiveOS package uses the CUDA build — use --cu-grid-size / --cu-block-size.
# (OpenCL flags like --cl-global-work are NOT supported in CUDA mode.)
# User can override via extra_args in flight sheet Extra Config JSON.

if [[ -z "$EXTRA_ARGS" ]] || ! echo "$EXTRA_ARGS" | grep -qE "cu-grid-size|cu-block-size|cuda"; then
    # No user-specified tuning — auto-detect GPU and apply optimal CUDA settings
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | xargs)

    # Probe which CUDA tuning flags HashWarp accepts
    HASHWARP_HELP=$("$HASHWARP" --help 2>&1 || true)
    HAS_CU_GRID=false
    HAS_CU_BLOCK=false
    HAS_NOEVAL=false
    echo "$HASHWARP_HELP" | grep -q "cu-grid-size"  && HAS_CU_GRID=true
    echo "$HASHWARP_HELP" | grep -q "cu-block-size"  && HAS_CU_BLOCK=true
    echo "$HASHWARP_HELP" | grep -q "noeval"          && HAS_NOEVAL=true

    # CUDA tuning:
    #   --cu-grid-size  = number of CUDA blocks (more = more parallelism)
    #   --cu-block-size = threads per block (128 is usually optimal)
    GRID=8192
    BLOCK=128

    case "$GPU_NAME" in
        *5090*)
            GRID=16384; BLOCK=256 ;;
        *5080*)
            GRID=8192;  BLOCK=256 ;;
        *4090*)
            GRID=16384; BLOCK=256 ;;
        *"4070 Ti Super"*|*"4070 SUPER Ti"*)
            GRID=8192;  BLOCK=128 ;;
        *"4070 Ti"*)
            GRID=8192;  BLOCK=128 ;;
        *4070*Super*|*4070*SUPER*)
            GRID=4096;  BLOCK=128 ;;
        *4070*)
            GRID=4096;  BLOCK=128 ;;
        *4060*Ti*|*4060*TI*)
            GRID=4096;  BLOCK=128 ;;
        *4060*)
            GRID=2048;  BLOCK=128 ;;
        *3090*|*3080*)
            GRID=8192;  BLOCK=128 ;;
        *3070*|*3060*Ti*)
            GRID=4096;  BLOCK=128 ;;
        *3060*)
            GRID=2048;  BLOCK=128 ;;
    esac

    TUNING=""
    $HAS_CU_GRID  && TUNING="$TUNING --cu-grid-size $GRID"
    $HAS_CU_BLOCK && TUNING="$TUNING --cu-block-size $BLOCK"
    $HAS_NOEVAL   && TUNING="$TUNING --noeval"

    if [[ -n "$GPU_NAME" ]]; then
        echo "GPU detected:  $GPU_NAME"
    fi
    if [[ -n "$TUNING" ]]; then
        echo "Auto-tuning:   $TUNING"
        EXTRA_ARGS="$TUNING $EXTRA_ARGS"
    else
        echo "No tuning flags available in this HashWarp build — using defaults"
    fi
    echo ""
else
    echo "Using user-specified tuning from extra_args"
    echo ""
fi

# ── Launch HashWarp in foreground ────────────────────────────────────────────
# --HWMON 1    → report GPU temp & fan (needed for HiveOS stats)
# --nocolor    → clean log output
# --syslog     → strip timestamps (HiveOS adds its own)
# --api-port   → API for h-stats.sh to query
# --farm-recheck 200 → check for new work every 200ms (responsive to new blocks)
# --report-hashrate → report hashrate back to node

FARM_OPTS="--farm-recheck 200 --report-hashrate"

LIBS_DIR="$MINER_DIR/libs"
if [[ -d "$LIBS_DIR" && -f "$LIBS_DIR/ld-linux-x86-64.so.2" ]]; then
    # ── Glibc compat mode: run via bundled dynamic linker ────────────────
    # Build comprehensive library path: bundled glibc + ALL system lib dirs
    LIB_PATH="$LIBS_DIR"

    # Read all paths from system ldconfig config (covers CUDA, NVIDIA, etc.)
    if [[ -d /etc/ld.so.conf.d ]]; then
        while IFS= read -r line; do
            line="${line%%#*}"  # strip comments
            line="${line// /}"  # strip whitespace
            [[ -d "$line" ]] && LIB_PATH="$LIB_PATH:$line"
        done < <(cat /etc/ld.so.conf.d/*.conf 2>/dev/null)
    fi

    # HiveOS-specific library paths (CUDA libs live here)
    for p in /hive/lib /hive/lib64; do
        [[ -d "$p" ]] && LIB_PATH="$LIB_PATH:$p"
    done

    # Add well-known paths that may not be in ldconfig
    for p in \
        /usr/lib/x86_64-linux-gnu \
        /lib/x86_64-linux-gnu \
        /usr/local/lib \
        /usr/lib; do
        [[ -d "$p" ]] && LIB_PATH="$LIB_PATH:$p"
    done

    # Glob for all CUDA toolkit versions
    for cuda in /usr/local/cuda*/lib64 /usr/local/cuda*/lib; do
        [[ -d "$cuda" ]] && LIB_PATH="$LIB_PATH:$cuda"
    done

    # Glob for all NVIDIA driver library directories
    for nv in \
        /usr/lib/x86_64-linux-gnu/nvidia/current \
        /usr/lib/nvidia-* \
        /usr/lib/x86_64-linux-gnu/nvidia-* \
        /usr/lib64/nvidia; do
        [[ -d "$nv" ]] && LIB_PATH="$LIB_PATH:$nv"
    done

    echo "Using bundled glibc compatibility libraries"
    echo ""
    "$LIBS_DIR/ld-linux-x86-64.so.2" --library-path "$LIB_PATH" \
        "$HASHWARP" \
        -P "$CONNECT_URL" \
        --api-port "$API_PORT" \
        --HWMON 1 \
        --nocolor \
        --syslog \
        $FARM_OPTS \
        $EXTRA_ARGS
else
    # ── Native mode: system glibc is new enough ─────────────────────────
    "$HASHWARP" \
        -P "$CONNECT_URL" \
        --api-port "$API_PORT" \
        --HWMON 1 \
        --nocolor \
        --syslog \
        $FARM_OPTS \
        $EXTRA_ARGS
fi
