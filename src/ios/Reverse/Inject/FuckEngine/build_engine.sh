#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
src="${script_dir}/FuckEngine.m"
out="${1:-${project_root}/templates/FuckEngine.dylib}"
sdk="${SDK:-iphoneos}"
min_ios="${MIN_IOS:-15.0}"

echo "[build_engine] sdk=${sdk} min_ios=${min_ios} output=${out}"

xcrun -sdk "${sdk}" clang \
  -arch arm64 \
  -miphoneos-version-min="${min_ios}" \
  -dynamiclib \
  -fno-objc-arc \
  -framework Foundation \
  -lobjc \
  -Os \
  -fvisibility=hidden \
  -Wl,-dead_strip \
  -Wno-deprecated-declarations \
  "${src}" \
  -o "${out}"

echo "[build_engine] compiled: $(wc -c < "${out}") bytes"

# Verify sections exist
if xcrun otool -l "${out}" 2>/dev/null | grep -q '__fuckeng_cr'; then
  echo "[build_engine] __fuckeng_cr section: OK"
else
  echo "[build_engine] ERROR: __fuckeng_cr section NOT FOUND" >&2
  exit 1
fi

if xcrun otool -l "${out}" 2>/dev/null | grep -q '__fuckeng_hk'; then
  echo "[build_engine] __fuckeng_hk section: OK"
else
  echo "[build_engine] ERROR: __fuckeng_hk section NOT FOUND" >&2
  exit 1
fi

if xcrun otool -l "${out}" 2>/dev/null | grep -q '__fuckeng_dl'; then
  echo "[build_engine] __fuckeng_dl section: OK"
else
  echo "[build_engine] ERROR: __fuckeng_dl section NOT FOUND" >&2
  exit 1
fi

# Verify markers
if strings "${out}" | grep -q '@@FUCKENGINE_COPYRIGHT@@'; then
  echo "[build_engine] @@FUCKENGINE_COPYRIGHT@@ marker: OK"
else
  echo "[build_engine] ERROR: copyright marker NOT FOUND" >&2
  exit 1
fi

if strings "${out}" | grep -q '@@FUCKENGINE_HOOKCONFIG@@'; then
  echo "[build_engine] @@FUCKENGINE_HOOKCONFIG@@ marker: OK"
else
  echo "[build_engine] ERROR: hookconfig marker NOT FOUND" >&2
  exit 1
fi

if strings "${out}" | grep -q '@@FUCKENGINE_DELAY@@'; then
  echo "[build_engine] @@FUCKENGINE_DELAY@@ marker: OK"
else
  echo "[build_engine] ERROR: delay marker NOT FOUND" >&2
  exit 1
fi

echo "[build_engine] ALL CHECKS PASSED"
