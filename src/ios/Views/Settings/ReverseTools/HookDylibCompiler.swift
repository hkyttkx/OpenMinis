//
//  HookDylibCompiler.swift
//  KyTuT
//
//  Hook 源码 → dylib 编译服务。
//
//  用途：AI 分析目标 App 后生成 Hook 源码（Objective-C），
//  这里把它编译成可注入的 .dylib，然后由 UI 询问用户是否立即注入。
//
//  编译在 App 内置的 Alpine 沙盒里用 clang 完成（SandboxRunner），
//  与已有的 radare2 / binutils 工具链同一套环境。
//

import Foundation

enum HookDylibCompiler {

    struct CompileResult {
        var success: Bool
        var dylibPath: String?
        var output: String
        var error: String?
    }

    /// 编译 Hook 源码为 dylib
    /// - Parameters:
    ///   - source: Objective-C 源码（AI 生成的 hook 实现）
    ///   - name: 输出文件名（不含扩展名）
    ///   - deployTarget: 最低系统版本
    static func compile(source: String,
                        name: String,
                        deployTarget: String = "15.0") async -> CompileResult {

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("hook_build_\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            return CompileResult(success: false, output: "", error: "创建编译目录失败：\(error.localizedDescription)")
        }

        let srcPath = workDir.appendingPathComponent("\(name).m")
        let outPath = workDir.appendingPathComponent("\(name).dylib")

        do {
            try source.write(to: srcPath, atomically: true, encoding: .utf8)
        } catch {
            return CompileResult(success: false, output: "", error: "写入源码失败：\(error.localizedDescription)")
        }

        // 沙盒内的路径（Alpine 侧通过 /var/minis 共享目录访问）
        let sharedDir = "/var/minis/workspace/hookbuild_\(name)"
        _ = try? await SandboxRunner.run("mkdir -p '\(sharedDir)'", timeout: 30)

        // 把源码搬到共享目录，供 Alpine 侧读取
        let sharedSrc = "\(sharedDir)/\(name).m"
        _ = try? await SandboxRunner.run(
            "cat > '\(sharedSrc)' << 'HOOKSRC_EOF'\n\(source)\nHOOKSRC_EOF",
            timeout: 60
        )

        let cmd = """
        cd '\(sharedDir)' && \
        xcrun_ok=0; \
        if command -v clang >/dev/null 2>&1; then \
          clang -arch arm64 -miphoneos-version-min=\(deployTarget) \
            -dynamiclib -fobjc-arc -fmodules \
            -framework Foundation -lobjc \
            -O2 -fvisibility=hidden -Wl,-dead_strip \
            -Wno-deprecated-declarations \
            '\(name).m' -o '\(name).dylib' 2>&1; \
        else \
          echo "NO_CLANG"; \
        fi
        """

        let (output, code) = (try? await SandboxRunner.run(cmd, timeout: 300)) ?? ("", -1)

        // 判断产物
        let check = try? await SandboxRunner.run(
            "test -f '\(sharedDir)/\(name).dylib' && echo OK || echo MISSING",
            timeout: 30
        )
        let produced = check?.output.contains("OK") == true

        if produced && code == 0 {
            // 复制到 App 的动态库目录
            let destDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DynamicLibraries")
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            let dest = destDir.appendingPathComponent("\(name).dylib")

            // 经由共享目录回传
            let localShared = URL(fileURLWithPath: "\(sharedDir)/\(name).dylib")
            if fm.fileExists(atPath: localShared.path) {
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: localShared, to: dest)
                chmod(dest.path, 0o755)
                return CompileResult(success: true, dylibPath: dest.path, output: output, error: nil)
            }
            return CompileResult(success: false, output: output,
                                 error: "编译产物存在但未能回传到 App 目录")
        }

        let hint = output.contains("NO_CLANG")
            ? "沙盒内没有 clang（需确认逆向工具链已内置）"
            : "编译未通过"
        return CompileResult(success: false, output: output, error: hint)
    }

    /// 生成一个最小可用的 Hook 模板（供 AI 生成失败时兜底）
    static func minimalHookTemplate(bundleID: String, className: String, methodName: String) -> String {
        return """
        // 自动生成的 Hook 模板
        // 目标：\(bundleID)
        #import <Foundation/Foundation.h>
        #import <objc/runtime.h>

        __attribute__((constructor))
        static void hook_entry(void) {
            NSLog(@"[HookDylib] loaded into %@", [[NSBundle mainBundle] bundleIdentifier]);
            Class cls = objc_getClass("\(className)");
            if (!cls) return;
            SEL sel = NSSelectorFromString(@"\(methodName)");
            if (![cls instancesRespondToSelector:sel]) return;
            NSLog(@"[HookDylib] target method found: %@ -%@", NSStringFromClass(cls), @"\(methodName)");
        }
        """
    }
}
