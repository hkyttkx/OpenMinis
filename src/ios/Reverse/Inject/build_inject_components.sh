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

  # 双架构：它在目标设备上以子进程运行，架构不匹配会直接起不来。
  KFD_TMP="$(mktemp -d)"
  for arch in arm64 arm64e; do
    xcrun -sdk "${sdk}" clang \
      -arch "${arch}" \
      -miphoneos-version-min="${min_ios}" \
      -fobjc-arc -fmodules \
      -I"${kfd_dir}" \
      -I"${script_dir}" \
      -framework Foundation -framework UIKit -framework IOKit -framework IOSurface \
      -lcompression \
      -Os -Wno-deprecated-declarations \
      "${script_dir}/FuckKfdHelper/FuckKfdHelper.m" \
      ${KFD_SOURCES} \
      -o "${KFD_TMP}/FuckKfdHelper-${arch}" 2>&1 || echo "[inject-build] KfdHelper ${arch} 失败"
  done
  if [ -f "${KFD_TMP}/FuckKfdHelper-arm64" ] && [ -f "${KFD_TMP}/FuckKfdHelper-arm64e" ]; then
    xcrun -sdk "${sdk}" lipo -create \
      "${KFD_TMP}/FuckKfdHelper-arm64" "${KFD_TMP}/FuckKfdHelper-arm64e" \
      -output "${out_dir}/FuckKfdHelper"
  elif [ -f "${KFD_TMP}/FuckKfdHelper-arm64" ]; then
    cp -f "${KFD_TMP}/FuckKfdHelper-arm64" "${out_dir}/FuckKfdHelper"
  fi
  rm -rf "${KFD_TMP}"

  echo "[inject-build] FuckKfdHelper: $(wc -c < "${out_dir}/FuckKfdHelper") bytes"
else
  echo "[inject-build] 跳过 FuckKfdHelper（源码不存在）"
fi

# ───────────────────────────────────────────────────────────────
# 2. FuckEngine.dylib
# ───────────────────────────────────────────────────────────────
if [ -f "${script_dir}/FuckEngine/FuckEngine.m" ]; then
  echo "[inject-build] 编译 FuckEngine.dylib（arm64 + arm64e）…"

  # 必须双架构：目标 App 可能是 arm64，也可能是 arm64e。
  # 只出 arm64 时，注入到 arm64e 进程会直接加载失败。
  # 越狱自带的 opainject 就是 universal 的，同一考虑。
  #
  # install_name 必须显式设成 @rpath/<name>：
  # 之前直接落盘，install_name 被写成构建机上的临时路径
  #   /Users/runner/work/_temp/inject-components/FuckEngine.dylib
  # 目标进程 dlopen 时会按这个名字回查自己，必然失败。

  ENGINE_SRC="${script_dir}/FuckEngine/FuckEngine.m"
  ENGINE_TMP="$(mktemp -d)"
  ENGINE_OK=1

  for arch_pair in "arm64" "arm64e"; do
    arch="${arch_pair}"
    if ! xcrun -sdk "${sdk}" clang \
        -arch "${arch}" \
        -miphoneos-version-min="${min_ios}" \
        -dynamiclib -fno-objc-arc \
        -framework Foundation -lobjc \
        -Os -fvisibility=hidden -Wl,-dead_strip \
        -Wno-deprecated-declarations \
        -install_name "@rpath/FuckEngine.dylib" \
        "${ENGINE_SRC}" \
        -o "${ENGINE_TMP}/FuckEngine-${arch}.dylib" 2>&1; then
      echo "[inject-build] ⚠️ FuckEngine ${arch} 编译失败"
      ENGINE_OK=0
      break
    fi
  done

  if [ "${ENGINE_OK}" = "1" ]; then
    xcrun -sdk "${sdk}" lipo -create \
      "${ENGINE_TMP}/FuckEngine-arm64.dylib" \
      "${ENGINE_TMP}/FuckEngine-arm64e.dylib" \
      -output "${out_dir}/FuckEngine.dylib"
  else
    # 双架构失败时退回单 arm64，至少不阻断构建
    echo "[inject-build] ⚠️ 退回单架构 arm64"
    cp -f "${ENGINE_TMP}/FuckEngine-arm64.dylib" "${out_dir}/FuckEngine.dylib" 2>/dev/null || true
  fi
  rm -rf "${ENGINE_TMP}"

  # 兜底：确保 install_name 正确（lipo 不会改它，但单独编译路径可能漏设）
  if [ -f "${out_dir}/FuckEngine.dylib" ]; then
    xcrun install_name_tool -id "@rpath/FuckEngine.dylib" "${out_dir}/FuckEngine.dylib" 2>/dev/null || true
    echo "[inject-build] FuckEngine.dylib: $(wc -c < "${out_dir}/FuckEngine.dylib") bytes"
    xcrun -sdk "${sdk}" lipo -info "${out_dir}/FuckEngine.dylib" || true
  fi
else
  echo "[inject-build] 跳过 FuckEngine.dylib（源码不存在）"
fi

# ───────────────────────────────────────────────────────────────
# 2.5 FuckInjectRunner（独立注入子进程，纯 ObjC，无 SwiftUI 生命周期）
#     以 root 身份被 spawn，入口极短，避免主程序自身启动时被 SIGHUP 打断
# ───────────────────────────────────────────────────────────────
if [ -f "${script_dir}/FuckInjectRunner.m" ]; then
  echo "[inject-build] 编译 FuckInjectRunner…"
  # 注意：两个 .m 必须**分别**编译成 .o 再链接。
  # 若把两个 .m 一起传给 clang，它们会被当作单个翻译单元处理，
  # FuckDynamicInjector.m 的 @implementation 块与 FuckInjectRunner.m 的
  # 文件级 main() 会互相破坏结构，报「use of undeclared identifier
  # 'injectDylib'」「expected '}'」「missing '@end'」等一串错误。
  # 同样双架构：它要能注入 arm64 与 arm64e 两类目标。
  TMPOBJ="$(mktemp -d)"
  for arch in arm64 arm64e; do
    xcrun -sdk "${sdk}" clang -c \
      -arch "${arch}" -miphoneos-version-min="${min_ios}" \
      -fobjc-arc -I"${script_dir}" \
      -Os -Wno-deprecated-declarations \
      "${script_dir}/FuckDynamicInjector.m" \
      -o "${TMPOBJ}/FuckDynamicInjector-${arch}.o" 2>&1 || { echo "[inject-build] ${arch} injector.o 失败"; }
    xcrun -sdk "${sdk}" clang -c \
      -arch "${arch}" -miphoneos-version-min="${min_ios}" \
      -fobjc-arc -I"${script_dir}" \
      -Os -Wno-deprecated-declarations \
      "${script_dir}/FuckInjectRunner.m" \
      -o "${TMPOBJ}/FuckInjectRunner-${arch}.o" 2>&1 || { echo "[inject-build] ${arch} runner.o 失败"; }
    xcrun -sdk "${sdk}" clang \
      -arch "${arch}" -miphoneos-version-min="${min_ios}" \
      -framework Foundation \
      "${TMPOBJ}/FuckDynamicInjector-${arch}.o" \
      "${TMPOBJ}/FuckInjectRunner-${arch}.o" \
      -o "${TMPOBJ}/FuckInjectRunner-${arch}" 2>&1 || { echo "[inject-build] ${arch} 链接失败"; }
  done
  if [ -f "${TMPOBJ}/FuckInjectRunner-arm64" ] && [ -f "${TMPOBJ}/FuckInjectRunner-arm64e" ]; then
    xcrun -sdk "${sdk}" lipo -create \
      "${TMPOBJ}/FuckInjectRunner-arm64" "${TMPOBJ}/FuckInjectRunner-arm64e" \
      -output "${out_dir}/FuckInjectRunner"
  elif [ -f "${TMPOBJ}/FuckInjectRunner-arm64" ]; then
    cp -f "${TMPOBJ}/FuckInjectRunner-arm64" "${out_dir}/FuckInjectRunner"
  fi
  rm -rf "${TMPOBJ}"
  chmod 0755 "${out_dir}/FuckInjectRunner"
  echo "[inject-build] FuckInjectRunner: $(wc -c < "${out_dir}/FuckInjectRunner") bytes"
else
  echo "[inject-build] 跳过 FuckInjectRunner（源码不存在）"
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
         cp mv rm mkdir chown cat FuckKfdHelper FuckInjectRunner cp-15 mv-15; do
  [ -f "${out_dir}/${f}" ] && chmod 0755 "${out_dir}/${f}"
done
for f in libcrypto.3.dylib libintl.8.dylib libiosexec.1.dylib libxar.1.dylib FuckEngine.dylib; do
  [ -f "${out_dir}/${f}" ] && chmod 0644 "${out_dir}/${f}"
done

echo "[inject-build] 产物清单："
ls -la "${out_dir}"

echo "[inject-build] 架构自检："
for f in FuckEngine.dylib FuckInjectRunner FuckKfdHelper opainject; do
  if [ -f "${out_dir}/${f}" ]; then
    printf '  %-22s ' "${f}"
    xcrun -sdk "${sdk}" lipo -info "${out_dir}/${f}" 2>/dev/null | sed 's/.*is architecture: //;s/.*are: //' || echo "(无法识别)"
  fi
done
if [ -f "${out_dir}/FuckEngine.dylib" ]; then
  echo "[inject-build] FuckEngine install_name 自检："
  xcrun otool -D "${out_dir}/FuckEngine.dylib" 2>/dev/null | tail -1
fi
echo "[inject-build] DONE"
