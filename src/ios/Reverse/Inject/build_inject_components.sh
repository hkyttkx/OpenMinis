#!/usr/bin/env bash
#
# build_inject_components.sh
#
# 构建动态注入所需的可执行组件（在 CI 的 macOS runner 上运行）：
#   1. FuckKfdHelper —— 独立子进程，承担 kfd trustcache 注入（iOS 16.x 及以下兜底通道）
#   2. FuckEngine.dylib —— Hook 引擎模板（AI 生成的 Hook 配置编译产物）
#   3. opainject —— 动态注入 CLI（由主程序同款引擎编译成独立可执行文件）
#
# 用法: bash build_inject_components.sh [输出目录]
#
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"           # src/ios/Reverse/Inject
src_root="$(cd "${script_dir}/../.." && pwd)"          # src/ios
out_dir="${1:-${src_root}/Resources/Reverse}"

sdk="${SDK:-iphoneos}"
min_ios="${MIN_IOS:-15.0}"

mkdir -p "${out_dir}"

echo "[inject-build] sdk=${sdk} min_ios=${min_ios}"
echo "[inject-build] output=${out_dir}"

# ───────────────────────────────────────────────────────────────
# 1. FuckKfdHelper（需要 kfd 全部源码）
# ───────────────────────────────────────────────────────────────
if [ -f "${script_dir}/FuckKfdHelper/FuckKfdHelper.m" ]; then
  echo "[inject-build] 编译 FuckKfdHelper…"
  kfd_dir="${script_dir}/kfd"
  KFD_SOURCES=$(find "${kfd_dir}" -name "*.c" -o -name "*.m" | tr '\n' ' ')

  xcrun -sdk "${sdk}" clang \
    -arch arm64 \
    -miphoneos-version-min="${min_ios}" \
    -fobjc-arc -fmodules \
    -I"${kfd_dir}" \
    -I"${script_dir}" \
    -framework Foundation -framework UIKit -framework IOKit -framework IOSurface \
    -lcompression \
    -Os -Wno-deprecated-declarations \
    "${script_dir}/FuckKfdHelper/FuckKfdHelper.m" \
    ${KFD_SOURCES} \
    -o "${out_dir}/FuckKfdHelper"

  echo "[inject-build] FuckKfdHelper: $(wc -c < "${out_dir}/FuckKfdHelper") bytes"
else
  echo "[inject-build] 跳过 FuckKfdHelper（源码不存在）"
fi

# ───────────────────────────────────────────────────────────────
# 2. FuckEngine.dylib
# ───────────────────────────────────────────────────────────────
if [ -f "${script_dir}/FuckEngine/FuckEngine.m" ]; then
  echo "[inject-build] 编译 FuckEngine.dylib…"
  xcrun -sdk "${sdk}" clang \
    -arch arm64 \
    -miphoneos-version-min="${min_ios}" \
    -dynamiclib -fno-objc-arc \
    -framework Foundation -lobjc \
    -Os -fvisibility=hidden -Wl,-dead_strip \
    -Wno-deprecated-declarations \
    "${script_dir}/FuckEngine/FuckEngine.m" \
    -o "${out_dir}/FuckEngine.dylib"
  echo "[inject-build] FuckEngine.dylib: $(wc -c < "${out_dir}/FuckEngine.dylib") bytes"
else
  echo "[inject-build] 跳过 FuckEngine.dylib（源码不存在）"
fi

# ───────────────────────────────────────────────────────────────
# 3. opainject（注入 CLI，与主程序共用同一引擎源码）
#    这里只做存在性检查 —— 该二进制随仓库 Resources/Reverse 一起分发，
#    如需重新编译需要额外的 CLI main 包装，当前保持预编译产物。
# ───────────────────────────────────────────────────────────────
if [ -f "${out_dir}/opainject" ]; then
  chmod +x "${out_dir}/opainject"
  echo "[inject-build] opainject 已就位: $(wc -c < "${out_dir}/opainject") bytes"
else
  echo "[inject-build] ⚠️ opainject 缺失"
fi

# ───────────────────────────────────────────────────────────────
# 4. 统一权限：全部可执行 + 库文件可读
# ───────────────────────────────────────────────────────────────
echo "[inject-build] 修正权限…"
for f in opainject ldid ct_bypass insert_dylib install_name_tool optool trollstorehelper \
         cp mv rm mkdir chown cat FuckKfdHelper cp-15 mv-15; do
  [ -f "${out_dir}/${f}" ] && chmod 0755 "${out_dir}/${f}"
done
for f in libcrypto.3.dylib libintl.8.dylib libiosexec.1.dylib libxar.1.dylib FuckEngine.dylib; do
  [ -f "${out_dir}/${f}" ] && chmod 0644 "${out_dir}/${f}"
done

echo "[inject-build] 产物清单："
ls -la "${out_dir}"
echo "[inject-build] DONE"
