#!/usr/bin/env bash
set -euo pipefail

# Build the pinned radare2 source for Alpine aarch64 inside an Alpine
# container. The output is an overlay consumed by prepare_alpine_rootfs.sh.
# This is a build-time operation; no package or network access is needed on
# the user's iPhone.

OUT="${1:-deps/resources/reverse-tools-overlay.tar.gz}"
VERSION="${R2_VERSION:-5.9.8}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$(dirname "$ROOT/$OUT")"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to build the aarch64 Alpine overlay" >&2
  exit 2
fi

ABS_OUT="$ROOT/$OUT"
OUT_REL="${OUT#"$ROOT/"}"
mkdir -p "$(dirname "$ABS_OUT")"

docker run --rm --platform linux/arm64 \
  -e R2_VERSION="$VERSION" \
  -e OUT_REL="$OUT_REL" \
  -v "$ROOT:/src" -w /src \
  alpine:3.21 sh -euxc '
    apk add --no-cache bash build-base git linux-headers pkgconf zlib-dev
    rm -rf /tmp/radare2 /tmp/overlay
    git clone --depth 1 --branch "$R2_VERSION" https://github.com/radareorg/radare2.git /tmp/radare2
    cd /tmp/radare2
    ./configure --prefix=/opt/minis-reverse-tools
    make -j"$(nproc)"
    make install
    mkdir -p /tmp/overlay/usr/local/bin /tmp/overlay/opt
    cp -a /opt/minis-reverse-tools /tmp/overlay/opt/
    # Alpine loader does not know the custom prefix. Keep the real binary
    # private and expose a wrapper with an explicit, relocatable library path.
    cat > /tmp/overlay/usr/local/bin/r2 <<WRAPPER
#!/bin/sh
set -eu
ROOT=/opt/minis-reverse-tools
export LD_LIBRARY_PATH="\$ROOT/lib:\${LD_LIBRARY_PATH:-}"
exec "\$ROOT/bin/r2" "\$@"
WRAPPER
    chmod 755 /tmp/overlay/usr/local/bin/r2
    cat > /tmp/overlay/usr/local/bin/rabin2 <<WRAPPER
#!/bin/sh
set -eu
ROOT=/opt/minis-reverse-tools
export LD_LIBRARY_PATH="\$ROOT/lib:\${LD_LIBRARY_PATH:-}"
exec "\$ROOT/bin/rabin2" "\$@"
WRAPPER
    chmod 755 /tmp/overlay/usr/local/bin/rabin2
    printf "%s\n" "{\"engine\":\"radare2\",\"version\":\"$R2_VERSION\",\"source\":\"https://github.com/radareorg/radare2\",\"runtimeDownload\":false,\"decompiler\":\"pdc\",\"libraryPath\":\"/opt/minis-reverse-tools/lib\"}" > /tmp/overlay/opt/minis-reverse-tools/manifest.json
    LD_LIBRARY_PATH=/opt/minis-reverse-tools/lib /opt/minis-reverse-tools/bin/r2 -q -c "?V" >/tmp/r2-version.txt
    test -s /tmp/r2-version.txt
    tar -czf "/src/$OUT_REL" -C /tmp/overlay .
  '

test -s "$ABS_OUT"
echo "embedded radare2 overlay: $ABS_OUT"
