#!/bin/sh
# Run ONLY inside an Alpine 3.21 aarch64 Linux container, never macOS.
set -eu
[ "$(uname -s)" = Linux ]
[ "$(apk --print-arch)" = aarch64 ]
export HOME=/root
apk add --no-cache radare2=5.9.8-r0 py3-capstone capstone binutils file sqlite python3 libstdc++ zlib llvm19
apk add --no-cache --virtual .reverse-build build-base git curl ca-certificates radare2-dev zlib-dev clang19 patch pkgconf
mkdir -p /opt/reverse-build /opt/minis-reverse
cd /opt/reverse-build
# The release's Makefile.acr pins ghidra-native to 0.5.0. Do not use master.
git clone --depth 1 --branch 5.9.8 --recurse-submodules https://github.com/radareorg/r2ghidra.git
cd r2ghidra
git clone --depth 1 --branch 0.5.0 https://github.com/radareorg/ghidra-native.git
(cd ghidra-native; for p in $(ls patches/*.patch | sort -n); do patch -p1 < "$p"; done; touch patch.done)
./configure --prefix=/usr
printf 'AARCH64\nARM\nx86\n' > ghidra-processors.txt
make -j2
make install
# Upstream builds a default SLEIGH path under the user's plugin directory.
make user-install
printf 'int test_add(int x) { return x * 7 + 3; }\nint main(void) { return test_add(6); }\n' > /opt/minis-reverse/smoke.c
cc -O0 -g /opt/minis-reverse/smoke.c -o /opt/minis-reverse/smoke-elf
clang-19 -target arm64-apple-ios14.0 -c -O0 /opt/minis-reverse/smoke.c -o /opt/minis-reverse/smoke-macho.o
# Real functions, not just --version. Save reports for the Actions artifact.
r2 -q -e scr.color=0 -c 'aa; s sym.test_add; pdg' /opt/minis-reverse/smoke-elf > /opt/minis-reverse/pdg-elf.txt 2>&1
grep -q 'test_add' /opt/minis-reverse/pdg-elf.txt
grep -q 'return' /opt/minis-reverse/pdg-elf.txt
r2 -q -e scr.color=0 -c 'aa; s sym._test_add; pdg' /opt/minis-reverse/smoke-macho.o > /opt/minis-reverse/pdg-macho.txt 2>&1
grep -q 'return' /opt/minis-reverse/pdg-macho.txt
file /opt/minis-reverse/smoke-macho.o | grep 'Mach-O'
/usr/lib/llvm19/bin/llvm-nm /opt/minis-reverse/smoke-macho.o | grep _test_add
/usr/lib/llvm19/bin/llvm-objdump --section-headers /opt/minis-reverse/smoke-macho.o
python3 -c 'import capstone; d=capstone.Cs(capstone.CS_ARCH_ARM64,capstone.CS_MODE_ARM); assert list(d.disasm(bytes.fromhex("c0035fd6"),0))[0].mnemonic == "ret"'
[ "$(sqlite3 :memory: 'select 6*7;')" = 42 ]
# Remove build dependencies, then check runtime again to catch missing libraries.
apk del .reverse-build
r2 -q -e scr.color=0 -c 'aa; s sym._test_add; pdg' /opt/minis-reverse/smoke-macho.o > /opt/minis-reverse/pdg-macho.txt 2>&1
grep -q return /opt/minis-reverse/pdg-macho.txt
python3 -c 'import capstone; print(capstone.__version__)'
rm -rf /opt/reverse-build /root/.cache /var/cache/apk/*
rm -f /opt/minis-reverse/smoke.c
printf 'reverse-toolchain-v2\n' > /opt/minis-reverse/version
r2 -v > /opt/minis-reverse/versions.txt
apk info -v >> /opt/minis-reverse/versions.txt
printf '\nTOOLCHAIN_SMOKE_TESTS_PASSED\n'
