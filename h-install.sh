#!/usr/bin/env bash
###############################################################################
# Parallax Miner for HiveOS — Installer
#
# Downloads HashWarp GPU miner (CUDA 12 build for NVIDIA GPUs).
# Override version:  export HASHWARP_VER=1.2.0 && bash h-install.sh
###############################################################################

MINER_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$MINER_DIR"

# Ensure all our scripts are executable (safety net for tar permission issues)
chmod +x "$MINER_DIR"/*.sh 2>/dev/null

HASHWARP_VER="${HASHWARP_VER:-1.2.0}"
LOCAL_BIN="$MINER_DIR/hashwarp"

# ── Already installed locally? ───────────────────────────────────────────────
if [[ -x "$LOCAL_BIN" ]]; then
    echo "HashWarp already installed at $LOCAL_BIN"
    "$LOCAL_BIN" -V 2>/dev/null || true
    exit 0
fi

# ── Download from GitHub ─────────────────────────────────────────────────────
ARCHIVE="hashwarp-v${HASHWARP_VER}-cuda12-linux.tar.xz"
URL="https://github.com/ParallaxProtocol/hashwarp/releases/download/v${HASHWARP_VER}/${ARCHIVE}"

echo "==================================="
echo " Downloading HashWarp v${HASHWARP_VER} (CUDA 12)"
echo "==================================="
echo "URL: $URL"
echo ""

wget -q --show-progress "$URL" -O "$ARCHIVE"
if [[ $? -ne 0 ]]; then
    # Fallback: try curl
    echo "wget failed, trying curl..."
    curl -L -o "$ARCHIVE" "$URL"
fi

if [[ ! -s "$ARCHIVE" ]]; then
    echo ""
    echo "ERROR: Download failed!"
    echo ""
    echo "Possible fixes:"
    echo "  1. Check internet connectivity"
    echo "  2. Download manually from:"
    echo "     $URL"
    echo "  3. Try a different version:"
    echo "       export HASHWARP_VER=1.2.0 && bash h-install.sh"
    echo ""
    rm -f "$ARCHIVE"
    exit 1
fi

echo "Extracting..."
tar -xJf "$ARCHIVE"
if [[ $? -ne 0 ]]; then
    echo "ERROR: Extraction failed!"
    rm -f "$ARCHIVE"
    exit 1
fi

# Find the extracted hashwarp binary
if [[ -f "$MINER_DIR/hashwarp" ]]; then
    chmod +x "$MINER_DIR/hashwarp"
else
    # Search for it in any extracted directory
    FOUND=$(find "$MINER_DIR" -name "hashwarp" -type f ! -name "*.sh" ! -name "*.tar*" 2>/dev/null | head -1)
    if [[ -n "$FOUND" && "$FOUND" != "$LOCAL_BIN" ]]; then
        mv "$FOUND" "$LOCAL_BIN"
        chmod +x "$LOCAL_BIN"
        # Clean up extracted directory
        EXTRACTED_DIR=$(dirname "$FOUND")
        [[ "$EXTRACTED_DIR" != "$MINER_DIR" ]] && rm -rf "$EXTRACTED_DIR"
    fi
fi

rm -f "$ARCHIVE"

if [[ -x "$LOCAL_BIN" ]]; then
    echo "HashWarp installed successfully!"
    "$LOCAL_BIN" -V 2>/dev/null || true
else
    echo "ERROR: hashwarp binary not found after extraction!"
    echo "Contents of $MINER_DIR:"
    ls -la "$MINER_DIR"
    exit 1
fi
chmod +x "$LOCAL_BIN" 2>/dev/null

if [[ -x "$LOCAL_BIN" ]]; then
    echo ""
    echo "SRBMiner-Multi ${SRBMINER_VER} installed successfully!"
    echo "Binary: $LOCAL_BIN"
else
    echo "ERROR: SRBMiner binary not found after extraction!"
    echo "Contents of $LOCAL_DIR:"
    ls -la "$LOCAL_DIR/"
    exit 1
fi

# Make all scripts executable (critical — tar on some systems drops +x)
chmod +x "$MINER_DIR"/*.sh "$MINER_DIR"/*.py 2>/dev/null
echo "Installation complete."
