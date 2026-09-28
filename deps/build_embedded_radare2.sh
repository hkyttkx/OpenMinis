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
    ln -s /opt/minis-reverse-tools/bin/r2 /tmp/overlay/usr/local/bin/r2
    ln -s /opt/minis-reverse-tools/bin/rabin2 /tmp/overlay/usr/local/bin/rabin2
    printf "%s\n" "{\"engine\":\"radare2\",\"version\":\"$R2_VERSION\",\"source\":\"https://github.com/radareorg/radare2\",\"runtimeDownload\":false,\"decompiler\":\"pdc\"}" > /tmp/overlay/opt/minis-reverse-tools/manifest.json
    tar -czf "/src/$OUT_REL" -C /tmp/overlay .
  '

test -s "$ABS_OUT"
echo "embedded radare2 overlay: $ABS_OUT"
