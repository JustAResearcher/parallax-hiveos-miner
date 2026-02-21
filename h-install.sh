#!/usr/bin/env bash
###############################################################################
# Parallax Miner for HiveOS — Installer  (v2.1)
#
# Downloads HashWarp GPU miner (CUDA 12 build for NVIDIA GPUs).
# If the system glibc is too old (HiveOS on Ubuntu 18/20), automatically
# downloads and bundles glibc compatibility libraries from Ubuntu 24.04.
#
# Override version:  export HASHWARP_VER=1.2.0 && bash h-install.sh
###############################################################################

MINER_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$MINER_DIR"

# Ensure all our scripts are executable
chmod +x "$MINER_DIR"/*.sh 2>/dev/null

HASHWARP_VER="${HASHWARP_VER:-1.2.0}"
LOCAL_BIN="$MINER_DIR/hashwarp"
LIBS_DIR="$MINER_DIR/libs"

# ── Already installed and working? ───────────────────────────────────────────
if [[ -x "$LOCAL_BIN" ]]; then
    # Test if it actually runs (might fail with GLIBC errors)
    if "$LOCAL_BIN" -V >/dev/null 2>&1; then
        echo "HashWarp already installed and working at $LOCAL_BIN"
        "$LOCAL_BIN" -V 2>/dev/null
        exit 0
    elif [[ -d "$LIBS_DIR" && -f "$LIBS_DIR/ld-linux-x86-64.so.2" ]]; then
        echo "HashWarp already installed (with glibc compat) at $LOCAL_BIN"
        exit 0
    fi
    echo "HashWarp binary exists but doesn't run — reinstalling..."
    rm -f "$LOCAL_BIN"
    rm -rf "$LIBS_DIR"
fi

# ── Download HashWarp from GitHub ────────────────────────────────────────────
ARCHIVE="hashwarp-v${HASHWARP_VER}-cuda12-linux.tar.xz"
URL="https://github.com/ParallaxProtocol/hashwarp/releases/download/v${HASHWARP_VER}/${ARCHIVE}"

echo "==================================="
echo " Downloading HashWarp v${HASHWARP_VER} (CUDA 12)"
echo "==================================="
echo "URL: $URL"
echo ""

wget -q --show-progress "$URL" -O "$ARCHIVE"
if [[ $? -ne 0 ]]; then
    echo "wget failed, trying curl..."
    curl -L -o "$ARCHIVE" "$URL"
fi

if [[ ! -s "$ARCHIVE" ]]; then
    echo ""
    echo "ERROR: Download failed!"
    echo "  1. Check internet connectivity"
    echo "  2. Download manually from: $URL"
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
    FOUND=$(find "$MINER_DIR" -name "hashwarp" -type f ! -name "*.sh" ! -name "*.tar*" 2>/dev/null | head -1)
    if [[ -n "$FOUND" && "$FOUND" != "$LOCAL_BIN" ]]; then
        mv "$FOUND" "$LOCAL_BIN"
        chmod +x "$LOCAL_BIN"
        EXTRACTED_DIR=$(dirname "$FOUND")
        [[ "$EXTRACTED_DIR" != "$MINER_DIR" ]] && rm -rf "$EXTRACTED_DIR"
    fi
fi

rm -f "$ARCHIVE"

if [[ ! -x "$LOCAL_BIN" ]]; then
    echo "ERROR: hashwarp binary not found after extraction!"
    ls -la "$MINER_DIR"
    exit 1
fi

# ── Test if HashWarp runs natively ───────────────────────────────────────────
echo ""
echo "Testing HashWarp binary..."

if "$LOCAL_BIN" -V >/dev/null 2>&1; then
    echo "HashWarp works natively!"
    "$LOCAL_BIN" -V
    exit 0
fi

# Check for GLIBC errors
ERROR_MSG=$("$LOCAL_BIN" -V 2>&1 || true)
if echo "$ERROR_MSG" | grep -qi "GLIBC"; then
    echo "HashWarp requires newer glibc than this system has."
    echo "Installing glibc compatibility libraries..."
    echo ""
else
    echo "HashWarp failed with unexpected error:"
    echo "$ERROR_MSG"
    echo ""
    echo "Attempting glibc compat fix anyway..."
fi

# ── Install glibc compatibility libraries ────────────────────────────────────
install_glibc_compat() {
    mkdir -p "$LIBS_DIR"

    local DEB_FILE="/tmp/libc6_compat_$$.deb"
    local TMPEXTRACT="/tmp/libc6_extract_$$"
    local DOWNLOADED=false

    # Method 1: Scrape Ubuntu archive for latest libc6 >= 2.38
    echo "  Searching Ubuntu archive for compatible glibc..."
    local PAGE
    PAGE=$(wget -q -O - "http://archive.ubuntu.com/ubuntu/pool/main/g/glibc/" 2>/dev/null)
    if [[ -n "$PAGE" ]]; then
        local DEB_NAME
        DEB_NAME=$(echo "$PAGE" | grep -oP 'libc6_2\.(3[89]|[4-9][0-9])-[^"]+_amd64\.deb' | sort -V | tail -1)
        if [[ -n "$DEB_NAME" ]]; then
            echo "  Found: $DEB_NAME"
            if wget -q "http://archive.ubuntu.com/ubuntu/pool/main/g/glibc/$DEB_NAME" -O "$DEB_FILE" 2>/dev/null && [[ -s "$DEB_FILE" ]]; then
                DOWNLOADED=true
            fi
        fi
    fi

    # Method 2: Try hardcoded URLs
    if ! $DOWNLOADED; then
        for url in \
            "http://archive.ubuntu.com/ubuntu/pool/main/g/glibc/libc6_2.39-0ubuntu8_amd64.deb" \
            "http://archive.ubuntu.com/ubuntu/pool/main/g/glibc/libc6_2.39-0ubuntu8.4_amd64.deb" \
            "http://mirrors.edge.kernel.org/ubuntu/pool/main/g/glibc/libc6_2.39-0ubuntu8_amd64.deb" \
            "http://archive.ubuntu.com/ubuntu/pool/main/g/glibc/libc6_2.40-1ubuntu1_amd64.deb"; do
            echo "  Trying: $url"
            if wget -q "$url" -O "$DEB_FILE" 2>/dev/null && [[ -s "$DEB_FILE" ]]; then
                DOWNLOADED=true
                break
            fi
        done
    fi

    if ! $DOWNLOADED || [[ ! -s "$DEB_FILE" ]]; then
        echo ""
        echo "ERROR: Could not download glibc compatibility libraries."
        echo ""
        echo "Solutions:"
        echo "  1. Update HiveOS to latest version:  hive-replace --stable"
        echo "  2. Check internet connectivity"
        rm -f "$DEB_FILE"
        return 1
    fi

    # Extract with dpkg-deb (always available on Debian/Ubuntu)
    echo "  Extracting glibc libraries..."
    rm -rf "$TMPEXTRACT"
    mkdir -p "$TMPEXTRACT"
    dpkg-deb -x "$DEB_FILE" "$TMPEXTRACT"

    # Copy only the libraries we need
    find "$TMPEXTRACT" -name "ld-linux-x86-64.so.2" -exec cp -fL {} "$LIBS_DIR/" \;
    find "$TMPEXTRACT" -name "libc.so.6"            -exec cp -fL {} "$LIBS_DIR/" \;
    find "$TMPEXTRACT" -name "libm.so.6"            -exec cp -fL {} "$LIBS_DIR/" \;
    find "$TMPEXTRACT" -name "librt.so.1"           -exec cp -fL {} "$LIBS_DIR/" \; 2>/dev/null
    find "$TMPEXTRACT" -name "libdl.so.2"           -exec cp -fL {} "$LIBS_DIR/" \; 2>/dev/null
    find "$TMPEXTRACT" -name "libpthread.so.0"      -exec cp -fL {} "$LIBS_DIR/" \; 2>/dev/null

    chmod +x "$LIBS_DIR"/* 2>/dev/null

    # Cleanup
    rm -rf "$TMPEXTRACT" "$DEB_FILE"

    # Verify
    if [[ ! -f "$LIBS_DIR/ld-linux-x86-64.so.2" ]]; then
        echo "ERROR: Failed to extract ld-linux-x86-64.so.2"
        return 1
    fi

    echo "  Compatibility libraries installed:"
    ls -la "$LIBS_DIR/"
    return 0
}

if ! install_glibc_compat; then
    exit 1
fi

# ── Test HashWarp with compat libraries ──────────────────────────────────────
echo ""
echo "Testing HashWarp with compatibility libraries..."

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
for p in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/local/lib /usr/lib; do
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

echo "  Library path: $LIB_PATH"

if "$LIBS_DIR/ld-linux-x86-64.so.2" --library-path "$LIB_PATH" "$LOCAL_BIN" -V >/dev/null 2>&1; then
    echo "HashWarp works with glibc compatibility libraries!"
    "$LIBS_DIR/ld-linux-x86-64.so.2" --library-path "$LIB_PATH" "$LOCAL_BIN" -V
else
    echo ""
    echo "ERROR: HashWarp still fails with compat libraries:"
    "$LIBS_DIR/ld-linux-x86-64.so.2" --library-path "$LIB_PATH" "$LOCAL_BIN" -V 2>&1 || true
    echo ""
    echo "Detected library search path:"
    echo "$LIB_PATH" | tr ':' '\n'
    echo ""
    echo "Looking for libcudart:"
    find / -name 'libcudart*' -type f 2>/dev/null | head -10
    echo ""
    echo "You may need to update HiveOS:  hive-replace --stable"
    exit 1
fi

echo ""
echo "Installation complete."
