#!/bin/sh
# Run ONLY inside an Alpine 3.21 aarch64 Linux container, never macOS.
set -eux
[ "$(uname -s)" = Linux ]
[ "$(apk --print-arch)" = aarch64 ]
export HOME=/root
apk add --no-cache radare2=5.9.8-r0 py3-capstone capstone binutils file sqlite python3 libstdc++ zlib llvm19
apk add --no-cache --virtual .reverse-build build-base git curl ca-certificates radare2-dev zlib-dev clang19 lld patch pkgconf
mkdir -p /opt/reverse-build /opt/minis-reverse
cp /root/test-reverse.py /opt/minis-reverse/test_reverse_toolchain.py
cd /opt/reverse-build
# The release's Makefile.acr pins ghidra-native to 0.5.0. Do not use master.
git clone --depth 1 --branch 5.9.8 --recurse-submodules https://github.com/radareorg/r2ghidra.git
cd r2ghidra
git clone --depth 1 --branch 0.5.0 https://github.com/radareorg/ghidra-native.git
(
    cd ghidra-native
    for p in $(ls patches/*.patch | sort -n); do
        case "$p" in
            */0055-datatype-clone.patch) ;; # Applied semantically below: upstream context is stale.
            *) patch -p1 < "$p" ;;
        esac
    done
    python3 - <<'PY'
from pathlib import Path
p = Path('src/decompiler/type.hh')
s = p.read_text()
start = s.index('  virtual Datatype *clone(void) const=0;')
end = s.index('\n', start) + 1
line = s[start:end]
s = s[:start] + s[end:]
public = s.index('public:', start) + len('public:\n')
s = s[:public] + line + s[public:]
p.write_text(s)
PY
    touch patch.done
)
./configure --prefix=/usr
printf 'AARCH64\nARM\nx86\n' > ghidra-processors.txt
make -j2
make install
# Keep one system plugin copy; duplicated user/system plugins cause load errors.
export SLEIGHHOME=/usr/lib/radare2/5.9.8/r2ghidra_sleigh
printf 'int test_add(int x) { return x * 7 + 3; }\nint main(void) { return test_add(6); }\n' > /opt/minis-reverse/smoke.c
cc -O0 -g /opt/minis-reverse/smoke.c -o /opt/minis-reverse/smoke-elf
clang-19 -target arm64-apple-ios14.0 -fno-stack-protector -c -O0 /opt/minis-reverse/smoke.c -o /opt/minis-reverse/smoke-macho.o
# Use a linked Mach-O executable, not MH_OBJECT; no Apple SDK or libraries needed.
ld64.lld -arch arm64 -platform_version ios 14.0 14.0 -e _main -o /opt/minis-reverse/smoke-macho /opt/minis-reverse/smoke-macho.o
# Test runtime features; stdout AND stderr are kept even when an assertion fails.
python3 /opt/minis-reverse/test_reverse_toolchain.py before-cleanup
# Remove build dependencies, then check runtime again to catch missing libraries.
apk del .reverse-build
python3 /opt/minis-reverse/test_reverse_toolchain.py after-cleanup
rm -rf /opt/reverse-build /root/.cache /var/cache/apk/*
rm -f /opt/minis-reverse/smoke.c
printf 'reverse-toolchain-v2\n' > /opt/minis-reverse/version
r2 -v > /opt/minis-reverse/versions.txt
apk info -v >> /opt/minis-reverse/versions.txt
printf '\nTOOLCHAIN_SMOKE_TESTS_PASSED\n'
