#!/usr/bin/env bash
###############################################################################
# Parallax Miner for HiveOS — Installer
#
# Downloads SRBMiner-Multi if not already present on the system.
# Override version:  export SRBMINER_VER=2.8.4 && bash h-install.sh
###############################################################################

MINER_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$MINER_DIR"

SRBMINER_VER="${SRBMINER_VER:-2.8.4}"
SRBMINER_TAG="${SRBMINER_VER//./-}"
LOCAL_DIR="$MINER_DIR/srbminer"
LOCAL_BIN="$LOCAL_DIR/SRBMiner-MULTI"

# ── Already installed locally? ───────────────────────────────────────────────
if [[ -x "$LOCAL_BIN" ]]; then
    echo "SRBMiner-Multi already installed at $LOCAL_BIN"
    exit 0
fi

# ── Check system-installed SRBMiner on HiveOS ────────────────────────────────
for sysdir in /hive/miners/srbminer-multi /hive/miners/srbminer; do
    if [[ -x "$sysdir/SRBMiner-MULTI" ]]; then
        echo "Found system SRBMiner at $sysdir — copying to local..."
        cp -a "$sysdir" "$LOCAL_DIR"
        chmod +x "$LOCAL_BIN"
        echo "Done."
        exit 0
    fi
done

# ── Download from GitHub ─────────────────────────────────────────────────────
ARCHIVE="SRBMiner-Multi-${SRBMINER_TAG}-Linux.tar.xz"
URL="https://github.com/doktor83/SRBMiner-Multi/releases/download/${SRBMINER_VER}/${ARCHIVE}"
EXTRACTED="SRBMiner-Multi-${SRBMINER_TAG}"

echo "==================================="
echo " Downloading SRBMiner-Multi ${SRBMINER_VER}"
echo "==================================="
echo "URL: $URL"
echo ""

wget -q --show-progress "$URL" -O "$ARCHIVE"
if [[ $? -ne 0 ]]; then
    echo ""
    echo "ERROR: Download failed!"
    echo ""
    echo "Possible fixes:"
    echo "  1. Check internet connectivity"
    echo "  2. Install SRBMiner via HiveOS miner manager (hiveos.farm → Miners)"
    echo "  3. Try a different version:"
    echo "       export SRBMINER_VER=2.7.9 && bash h-install.sh"
    echo ""
    rm -f "$ARCHIVE"
    exit 1
fi

echo "Extracting..."
tar -xf "$ARCHIVE"
if [[ $? -ne 0 ]]; then
    echo "ERROR: Extraction failed!"
    rm -f "$ARCHIVE"
    exit 1
fi

mkdir -p "$LOCAL_DIR"
if [[ -d "$EXTRACTED" ]]; then
    mv "$EXTRACTED"/* "$LOCAL_DIR/" 2>/dev/null
    rm -rf "$EXTRACTED"
else
    # Fallback: find the extracted directory
    for d in SRBMiner-Multi-*; do
        [[ -d "$d" ]] && mv "$d"/* "$LOCAL_DIR/" 2>/dev/null && rm -rf "$d" && break
    done
fi

rm -f "$ARCHIVE"
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
