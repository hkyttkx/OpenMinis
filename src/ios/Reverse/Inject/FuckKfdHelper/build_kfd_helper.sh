#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
out="${1:-${project_root}/templates/FuckKfdHelper}"
sdk="${SDK:-iphoneos}"
min_ios="${MIN_IOS:-15.0}"
kfd_dir="${project_root}/code/FuckInject/kfd"

echo "[build_kfd_helper] sdk=${sdk} min_ios=${min_ios} output=${out}"

mkdir -p "$(dirname "${out}")"

# 收集所有 kfd 源文件
KFD_SOURCES=$(find "${kfd_dir}" -name "*.c" -o -name "*.m" | tr '\n' ' ')
echo "[build_kfd_helper] kfd sources: $(echo ${KFD_SOURCES} | wc -w | tr -d ' ') files"

xcrun -sdk "${sdk}" clang \
  -arch arm64 \
  -miphoneos-version-min="${min_ios}" \
  -fobjc-arc \
  -fmodules \
  -I"${kfd_dir}" \
  -I"${project_root}/code/FuckInject" \
  -framework Foundation \
  -framework UIKit \
  -framework IOKit \
  -framework IOSurface \
  -lcompression \
  -Os \
  -Wno-deprecated-declarations \
  "${script_dir}/FuckKfdHelper.m" \
  ${KFD_SOURCES} \
  -o "${out}"

echo "[build_kfd_helper] compiled: $(wc -c < "${out}") bytes"
echo "[build_kfd_helper] DONE"
