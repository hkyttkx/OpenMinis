#!/bin/bash
set -e

# ============================================================================
# Alpine Linux aarch64 Rootfs Preparation Script for iSH-ARM64
# ============================================================================
# This script downloads Alpine Linux minirootfs (aarch64) and converts it to
# iSH's fakefs format for use as a sandboxed ARM64 Linux environment.
#
# Repository: https://github.com/OpenMinis/ish-arm64 (branch: feature-arm64)
#
# Prerequisites:
#   - Python 3 with meson (pip3 install meson)
#   - Ninja (brew install ninja)
#   - libarchive (brew install libarchive)
#
# Usage:
#   ./prepare_alpine_rootfs.sh [version]
#
# Output:
#   deps/resources/alpine-rootfs/  - fakefs formatted rootfs
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISH_DIR="$SCRIPT_DIR/ish"
OUTPUT_DIR="$SCRIPT_DIR/resources"
CACHE_DIR="$SCRIPT_DIR/.cache"

# Alpine configuration - aarch64 for ARM64 emulation
ALPINE_VERSION="${1:-3.21}"
ALPINE_MINOR="0"
ALPINE_ARCH="aarch64"  # ARM64 for iSH-ARM64 emulation
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
    exit 1
}

# ============================================================================
# Check Prerequisites
# ============================================================================
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v curl &> /dev/null; then
        log_error "curl is required"
    fi

    if ! command -v meson &> /dev/null; then
        log_error "Meson is required. Install with: pip3 install meson"
    fi

    if ! command -v ninja &> /dev/null; then
        log_error "Ninja is required. Install with: brew install ninja"
    fi

    # Check for libarchive
    LIBARCHIVE_FOUND=0
    for dir in "/opt/homebrew/opt/libarchive" "/usr/local/opt/libarchive" "/usr"; do
        if [ -f "$dir/lib/libarchive.dylib" ] || [ -f "$dir/lib/libarchive.a" ] || [ -f "$dir/lib/libarchive.so" ]; then
            LIBARCHIVE_FOUND=1
            break
        fi
    done

    if [ $LIBARCHIVE_FOUND -eq 0 ]; then
        log_error "libarchive is required. Install with: brew install libarchive"
    fi

    log_success "Prerequisites check passed"
}

# ============================================================================
# Download Alpine minirootfs
# ============================================================================
download_alpine() {
    log_info "Downloading Alpine Linux $ALPINE_VERSION.$ALPINE_MINOR for $ALPINE_ARCH..."

    mkdir -p "$CACHE_DIR"

    local ROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_MINOR}-${ALPINE_ARCH}.tar.gz"
    local ROOTFS_PATH="$CACHE_DIR/$ROOTFS_FILE"
    local ROOTFS_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/${ROOTFS_FILE}"

    if [ -f "$ROOTFS_PATH" ]; then
        log_info "Using cached rootfs: $ROOTFS_FILE"
    else
        log_info "Downloading from $ROOTFS_URL"
        curl -L -o "$ROOTFS_PATH" "$ROOTFS_URL" --progress-bar

        if [ ! -f "$ROOTFS_PATH" ]; then
            log_error "Failed to download rootfs"
        fi
    fi

    log_success "Alpine rootfs ready: $(du -h "$ROOTFS_PATH" | cut -f1)"
}

# ============================================================================
# Build fakefsify tool
# ============================================================================
build_fakefsify() {
    log_info "Building fakefsify tool..."

    local BUILD_DIR="$ISH_DIR/build-native"

    # Check if already built
    if [ -x "$BUILD_DIR/tools/fakefsify" ]; then
        log_info "fakefsify already built"
        return
    fi

    mkdir -p "$BUILD_DIR"
    cd "$ISH_DIR"

    # Configure for native build (not cross-compile)
    if [ ! -f "$BUILD_DIR/build.ninja" ]; then
        log_info "Configuring native meson build..."
        # Deliberately no -Db_ndebug here (unlike build_ish.sh, which disables
        # asserts for release). This build produces only tools/fakefsify, a
        # host-side tool that runs on this Mac and never ships to a device, so
        # a failed assert is a loud build failure rather than a user crash —
        # which is what we want while generating a rootfs.
        meson setup "$BUILD_DIR" \
            --buildtype=release \
            -Dlog="" \
            -Dkernel=ish \
            -Dengine=asbestos \
            -Dguest_arch=arm64
    fi

    # Build only fakefsify
    log_info "Building fakefsify..."
    ninja -C "$BUILD_DIR" tools/fakefsify

    if [ ! -x "$BUILD_DIR/tools/fakefsify" ]; then
        log_error "Failed to build fakefsify"
    fi

    cd "$SCRIPT_DIR"
    log_success "fakefsify built successfully"
}

# ============================================================================
# Create fakefs rootfs
# ============================================================================
create_fakefs() {
    log_info "Creating fakefs rootfs..."

    local ROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_MINOR}-${ALPINE_ARCH}.tar.gz"
    local ROOTFS_PATH="$CACHE_DIR/$ROOTFS_FILE"
    local FAKEFSIFY="$ISH_DIR/build-native/tools/fakefsify"
    local OUTPUT_ROOTFS="$OUTPUT_DIR/alpine-rootfs"

    # Remove existing rootfs
    if [ -d "$OUTPUT_ROOTFS" ]; then
        log_info "Removing existing rootfs..."
        rm -rf "$OUTPUT_ROOTFS"
    fi

    mkdir -p "$OUTPUT_DIR"

    # Convert to fakefs format
    log_info "Converting rootfs to fakefs format..."
    "$FAKEFSIFY" "$ROOTFS_PATH" "$OUTPUT_ROOTFS"

    if [ ! -d "$OUTPUT_ROOTFS/data" ] || [ ! -f "$OUTPUT_ROOTFS/meta.db" ]; then
        log_error "Failed to create fakefs rootfs"
    fi

    log_success "Fakefs rootfs created"
}

# ============================================================================
# Preinstall reverse-engineering toolchain into the rootfs
# ============================================================================
# Runs BETWEEN create_fakefs and configure_rootfs.
#
# Why this is here rather than installed by the app at runtime: the in-app
# installer had to reach the network on every attempt, and it kept failing
# partway — py3-lief / py3-keystone do not exist in Alpine's aarch64 repos at
# all, and one flaky mirror aborts the whole transaction. Baking the toolchain
# into the rootfs makes every tool present on first launch, offline, with no
# install step for the user.
#
# How the chroot works: the GitHub macOS runner is arm64 and Alpine's aarch64
# userland runs natively on it, so no QEMU emulation is involved.
#
# r2ghidra: Alpine ships radare2 5.9.8, so r2ghidra must come from the matching
# 5.9.8 tag (master requires r_core >= 6.1.4 and refuses to configure against
# 5.9.8). Its ghidra-native + pugixml sources are not part of the release
# tarball, so both are fetched explicitly.
#
# Every inner script is written to a file and run with `chroot ... /bin/sh FILE`
# rather than passed as a `-c` string: these bodies contain $(...), quotes and
# backslashes, and nesting them inside a single-quoted heredoc argument is what
# makes such scripts fragile to maintain and easy to break silently.

preinstall_tools() {
    log_info "Preinstalling reverse-engineering toolchain into rootfs..."

    local ROOTFS_DATA="$OUTPUT_DIR/alpine-rootfs/data"
    [ -d "$ROOTFS_DATA" ] || log_error "rootfs data dir missing — run create_fakefs first"

    # ------------------------------------------------------------------
    # chroot prerequisites
    # ------------------------------------------------------------------
    # The minirootfs tarball carries no device nodes, and a missing /dev/null
    # makes git and apk fail in ways that read like network errors ("could not
    # open /dev/null for reading and writing"). /dev/urandom is what git needs
    # for temp-file names.
    mkdir -p "$ROOTFS_DATA/dev" "$ROOTFS_DATA/tmp" "$ROOTFS_DATA/proc" "$ROOTFS_DATA/sys"
    rm -f "$ROOTFS_DATA/dev/null" "$ROOTFS_DATA/dev/urandom" \
          "$ROOTFS_DATA/dev/random" "$ROOTFS_DATA/dev/zero" "$ROOTFS_DATA/dev/tty"
    mknod -m 666 "$ROOTFS_DATA/dev/null"    c 1 3 || log_error "mknod /dev/null failed"
    mknod -m 666 "$ROOTFS_DATA/dev/urandom" c 1 9 || log_error "mknod /dev/urandom failed"
    mknod -m 666 "$ROOTFS_DATA/dev/random"  c 1 8 || true
    mknod -m 666 "$ROOTFS_DATA/dev/zero"    c 1 5 || true
    mknod -m 666 "$ROOTFS_DATA/dev/tty"     c 5 0 || true
    chmod 1777 "$ROOTFS_DATA/tmp"

    cp /etc/resolv.conf "$ROOTFS_DATA/etc/resolv.conf" 2>/dev/null || \
        printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' > "$ROOTFS_DATA/etc/resolv.conf"

    cat > "$ROOTFS_DATA/etc/apk/repositories" << EOF
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community
EOF

    # ------------------------------------------------------------------
    # Step 1 — runtime toolchain
    # ------------------------------------------------------------------
    # Verified against the aarch64 v3.21 APKINDEX:
    #   radare2 / capstone / py3-capstone  present (community)
    #   radare2-dev / binutils / file / sqlite / python3  present (main)
    #   py3-lief / py3-keystone  DO NOT EXIST for aarch64
    # lief is pip-only and pip has no musl wheel, so it is deliberately omitted
    # instead of being allowed to fail the whole apk transaction.
    log_info "Step 1/3: installing radare2 + capstone + binutils + file + sqlite + python3..."
    cat > "$ROOTFS_DATA/root/step1.sh" << 'STEP1'
set -e
apk update
apk add --no-cache \
    radare2 radare2-dev \
    capstone capstone-dev \
    binutils binutils-dev \
    file sqlite python3 py3-pip \
    zip unzip git
rm -rf /var/cache/apk/*
STEP1

    if ! chroot "$ROOTFS_DATA" /bin/sh /root/step1.sh; then
        log_error "step 1 failed — base toolchain could not be installed"
    fi

    # ------------------------------------------------------------------
    # Step 2 — r2ghidra (pseudo-C decompiler plugin)
    # ------------------------------------------------------------------
    # Built against the exact radare2 tag Alpine ships. A failure here is
    # non-fatal: r2's built-in `pdc` still produces usable pseudo-C, so the
    # rootfs stays shippable without the plugin.
    log_info "Step 2/3: building r2ghidra 5.9.8 (pseudo-C decompiler)..."
    local R2G_TAG="5.9.8"

    mkdir -p "$ROOTFS_DATA/opt/r2ghidra-src"
    cat > "$ROOTFS_DATA/root/step2_fetch.sh" << STEP2FETCH
set -e
cd /opt/r2ghidra-src
rm -rf r2ghidra pugixml ghidra-native
curl -fsSL -o r2g.tar.gz "https://github.com/radareorg/r2ghidra/archive/refs/tags/${R2G_TAG}.tar.gz"
tar -xzf r2g.tar.gz
mv "r2ghidra-${R2G_TAG}" r2ghidra
curl -fsSL -o pugixml.tar.gz "https://github.com/zeux/pugixml/archive/refs/heads/master.tar.gz"
tar -xzf pugixml.tar.gz
rm -rf r2ghidra/third-party/pugixml
mv pugixml-master r2ghidra/third-party/pugixml
curl -fsSL -o ghidra-native.tar.gz "https://github.com/radareorg/ghidra-native/archive/refs/heads/master.tar.gz"
tar -xzf ghidra-native.tar.gz
rm -rf r2ghidra/ghidra-native
mv ghidra-native-master r2ghidra/ghidra-native
rm -f ./*.tar.gz
STEP2FETCH

    if ! chroot "$ROOTFS_DATA" /bin/sh /root/step2_fetch.sh; then
        log_warning "r2ghidra source fetch failed — skipping plugin build"
    else
        cat > "$ROOTFS_DATA/root/step2_build.sh" << 'STEP2BUILD'
set -e
apk add --no-cache meson ninja pkgconf zlib-dev zlib-static
cd /opt/r2ghidra-src/r2ghidra
meson setup build . --buildtype=release -Dwerror=false
ninja -C build
ninja -C build install
STEP2BUILD
        if ! chroot "$ROOTFS_DATA" /bin/sh /root/step2_build.sh; then
            log_warning "r2ghidra build failed — r2 pdc fallback remains available"
        fi
    fi

    # ------------------------------------------------------------------
    # Step 3 — cleanup + verification
    # ------------------------------------------------------------------
    # The r2ghidra source tree, compiler toolchain and apk cache are dead
    # weight once the plugin is installed.
    log_info "Step 3/3: cleaning build artifacts and verifying..."
    cat > "$ROOTFS_DATA/root/step3_clean.sh" << 'STEP3CLEAN'
rm -rf /opt/r2ghidra-src
rm -rf /root/.cache
rm -f /root/step1.sh /root/step2_fetch.sh /root/step2_build.sh
apk del --no-cache \
    meson ninja pkgconf zlib-dev zlib-static \
    radare2-dev capstone-dev binutils-dev git 2>/dev/null || true
rm -rf /var/cache/apk/*
mkdir -p /root/.local/share/radare2/plugins
STEP3CLEAN
    chroot "$ROOTFS_DATA" /bin/sh /root/step3_clean.sh || log_warning "cleanup incomplete (non-fatal)"

    # Loud on purpose: a silently toolchain-less rootfs is exactly the failure
    # this whole change exists to prevent, so print what actually landed.
    cat > "$ROOTFS_DATA/root/step3_verify.sh" << 'STEP3VERIFY'
echo "--- rootfs toolchain ---"
printf '  r2:       %s\n' "$(r2 -v 2>/dev/null | head -1)"
printf '  capstone: %s\n' "$(python3 -c 'import capstone;print(capstone.__version__)' 2>/dev/null)"
printf '  nm:       %s\n' "$(command -v nm || echo MISSING)"
printf '  objdump:  %s\n' "$(command -v objdump || echo MISSING)"
printf '  strings:  %s\n' "$(command -v strings || echo MISSING)"
printf '  file:     %s\n' "$(file --version 2>/dev/null | head -1)"
printf '  sqlite3:  %s\n' "$(sqlite3 --version 2>/dev/null)"
printf '  python3:  %s\n' "$(python3 --version 2>/dev/null)"
if r2 -qc 'Lc' -- 2>/dev/null | grep -qi ghidra; then
    echo "  r2ghidra: loaded"
else
    echo "  r2ghidra: NOT loaded (r2 pdc fallback)"
fi
STEP3VERIFY
    chroot "$ROOTFS_DATA" /bin/sh /root/step3_verify.sh || log_warning "verification had errors"
    rm -f "$ROOTFS_DATA/root/step3_verify.sh"

    log_success "Toolchain preinstall complete ($(du -sh "$ROOTFS_DATA" | cut -f1))"
}

# ============================================================================
# Configure rootfs for iSH
# ============================================================================
configure_rootfs() {
    log_info "Configuring rootfs for iSH..."

    local ROOTFS_DATA="$OUTPUT_DIR/alpine-rootfs/data"

    # Create necessary directories
    mkdir -p "$ROOTFS_DATA/dev"
    mkdir -p "$ROOTFS_DATA/proc"
    mkdir -p "$ROOTFS_DATA/sys"
    mkdir -p "$ROOTFS_DATA/tmp"
    mkdir -p "$ROOTFS_DATA/run"
    mkdir -p "$ROOTFS_DATA/root"
    mkdir -p "$ROOTFS_DATA/home"

    # Configure /etc/passwd - set root shell
    if [ -f "$ROOTFS_DATA/etc/passwd" ]; then
        # Ensure root has /bin/sh as shell
        sed -i.bak 's|^root:.*|root:x:0:0:root:/root:/bin/sh|' "$ROOTFS_DATA/etc/passwd"
        rm -f "$ROOTFS_DATA/etc/passwd.bak"
    fi

    # Configure /etc/profile for better shell experience
    cat >> "$ROOTFS_DATA/etc/profile" << 'EOF'

# MinisApp iSH Configuration
export PS1='\u@minis:\w\$ '
export TERM=xterm-256color
export HOME=/root
export LANG=C.UTF-8
export CHARSET=UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin

# Aliases
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'

cd ~
EOF

    # Create /etc/motd
    cat > "$ROOTFS_DATA/etc/motd" << 'EOF'

  __  __ _       _        _    _ _
 |  \/  (_)_ __ (_)___   | |  (_) |_ ___
 | |\/| | | '_ \| / __|  | |  | | __/ _ \
 | |  | | | | | | \__ \  | |__| | ||  __/
 |_|  |_|_|_| |_|_|___/  |____|_|\__\___|

 Welcome to MinisApp Linux Shell
 Alpine Linux aarch64 on iSH-ARM64 Emulator

EOF

    # Configure /etc/inittab for single user mode (iSH handles tty)
    cat > "$ROOTFS_DATA/etc/inittab" << 'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

    # Configure resolv.conf for DNS
    cat > "$ROOTFS_DATA/etc/resolv.conf" << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

    # Configure APK repositories
    cat > "$ROOTFS_DATA/etc/apk/repositories" << EOF
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community
EOF

    log_success "Rootfs configured"
}

# ============================================================================
# Create ZIP Archive
# ============================================================================
create_zip_archive() {
    log_info "Creating ZIP archive..."

    local ROOTFS_DIR="$OUTPUT_DIR/alpine-rootfs"
    local ZIP_FILE="$OUTPUT_DIR/alpine-rootfs.zip"

    # Remove existing zip
    rm -f "$ZIP_FILE"

    # Create zip (exclude WAL files)
    cd "$OUTPUT_DIR"
    zip -r "alpine-rootfs.zip" "alpine-rootfs" \
        -x "*.db-shm" \
        -x "*.db-wal" \
        > /dev/null

    cd "$SCRIPT_DIR"

    if [ ! -f "$ZIP_FILE" ]; then
        log_error "Failed to create ZIP archive"
    fi

    log_success "ZIP archive created: $(du -h "$ZIP_FILE" | cut -f1)"
}

# ============================================================================
# Print Summary
# ============================================================================
print_summary() {
    local ROOTFS_DIR="$OUTPUT_DIR/alpine-rootfs"
    local ZIP_FILE="$OUTPUT_DIR/alpine-rootfs.zip"

    echo ""
    echo "============================================================"
    echo -e "${GREEN}🎉 Alpine Rootfs Preparation Complete!${NC}"
    echo "============================================================"
    echo ""
    echo "Output files:"
    echo "  📁 $ROOTFS_DIR"
    echo "  📦 $ZIP_FILE"
    echo ""
    echo "Sizes:"
    echo "  Data:     $(du -sh "$ROOTFS_DIR/data" | cut -f1)"
    echo "  Database: $(du -h "$ROOTFS_DIR/meta.db" | cut -f1)"
    echo "  ZIP:      $(du -h "$ZIP_FILE" | cut -f1)"
    echo ""
    echo "To use in MinisApp:"
    echo "  1. Add alpine-rootfs.zip to Xcode project resources"
    echo "  2. Extract to Documents on first launch"
    echo "  3. Use mount_root(&fakefs, path_to_data)"
    echo ""
    echo "============================================================"
}

# ============================================================================
# Clean
# ============================================================================
clean() {
    log_info "Cleaning..."

    rm -rf "$OUTPUT_DIR/alpine-rootfs"
    rm -rf "$ISH_DIR/build-native"
    rm -rf "$CACHE_DIR"

    log_success "Clean completed"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo ""
    echo "============================================================"
    echo "  Alpine Linux aarch64 Rootfs Preparation for iSH-ARM64"
    echo "  Version: $ALPINE_VERSION.$ALPINE_MINOR ($ALPINE_ARCH)"
    echo "============================================================"
    echo ""

    check_prerequisites
    download_alpine
    build_fakefsify
    create_fakefs
    preinstall_tools
    configure_rootfs
    create_zip_archive
    print_summary
}

# Parse arguments
case "${1:-}" in
    clean)
        clean
        exit 0
        ;;
    --help|-h)
        echo "Usage: $0 [version|clean]"
        echo ""
        echo "Arguments:"
        echo "  version    Alpine version (default: 3.21)"
        echo "  clean      Remove all generated files"
        echo ""
        echo "Examples:"
        echo "  $0           # Use default version 3.21"
        echo "  $0 3.18      # Use Alpine 3.18"
        echo "  $0 clean     # Clean all files"
        exit 0
        ;;
    *)
        main
        ;;
esac
