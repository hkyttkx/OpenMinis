//
//  IPAInjector.swift
//  KyTuT
//
//  Gadget 注入管线（TrollStore 模式）：
//    输入（二选一）
//      a. 已安装且已解密的 App —— 直接克隆其 .app（TrollStore 装的 App 磁盘上即解密）
//      b. 已解密的 IPA 文件     —— 沙盒 unzip 展开
//    注入
//      1. 复制 FridaGadget.dylib 进 .app
//      2. 生成 frida-loader.js（日志桥 + 全部已启用脚本串联）
//      3. 写 FridaGadget.config（script 交互模式）
//      4. MachOPatcher 向主二进制追加 LC_LOAD_DYLIB
//    打包
//      沙盒 zip 压缩为 IPA（宿主无 zip 工具，沙盒有）
//    安装
//      apple-magnifier://install?url= 交给 TrollStore（安装时统一重签）
//

import Foundation
import UIKit

private let injLogger = AppLogger(category: "Frida")

enum IPAInjectError: Error, LocalizedError {
    case gadgetNotBundled
    case sandboxFailed(String)
    case appNotFound

    var errorDescription: String? {
        switch self {
        case .gadgetNotBundled: return "FridaGadget.dylib 未打包进 App（CI 下载失败？请重新构建）"
        case .sandboxFailed(let m): return "沙盒执行失败：\(m)"
        case .appNotFound: return "未找到 Payload 里的 .app"
        }
    }
}

enum IPAInjector {

    static let gadgetName = "FridaGadget"
    static let guestInjectDir = SandboxRunner.guestSharedDir + "/inject"
    static var hostInjectDir: URL {
        SandboxRunner.hostSharedDir.appendingPathComponent("inject", isDirectory: true)
    }

    /// 宿主内 FridaGadget.dylib 位置（CI 打包时拷入 .app 根目录）。
    static var bundledGadgetURL: URL? {
        Bundle.main.url(forResource: "FridaGadget", withExtension: "dylib")
            ?? Bundle.main.bundleURL.appendingPathComponent("FridaGadget.dylib")
    }

    // MARK: - 主流程

    /// 对一个已展开的 .app 目录执行注入，返回生成的 IPA 路径。
    /// - Parameter appURL: 工作目录 Payload/ 下的 .app
    static func injectGadget(intoApp appURL: URL,
                             scripts: [FridaScript],
                             onProgress: @escaping (String) -> Void) async throws -> URL {
        onProgress("① 检查 Gadget…")
        guard let gadget = bundledGadgetURL, FileManager.default.fileExists(atPath: gadget.path) else {
            throw IPAInjectError.gadgetNotBundled
        }

        // 主二进制
        guard let plist = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
              let exeName = plist["CFBundleExecutable"] as? String else {
            throw IPAInjectError.appNotFound
        }
        let exeURL = appURL.appendingPathComponent(exeName)

        onProgress("② 检测加密状态…")
        guard let info = MachOInspector.inspect(url: exeURL) else {
            throw MachOPatchError.notMachO64
        }
        if info.cryptid != 0 {
            throw MachOPatchError.encrypted
        }

        // 1. 复制 Gadget
        onProgress("③ 复制 FridaGadget.dylib…")
        let dstGadget = appURL.appendingPathComponent("\(gadgetName).dylib")
        try? FileManager.default.removeItem(at: dstGadget)
        try FileManager.default.copyItem(at: gadget, to: dstGadget)

        // 2. 生成 loader（日志桥 + 已启用脚本串联）
        onProgress("④ 生成脚本加载器（\(scripts.count) 个脚本）…")
        let loader = buildLoaderJS(scripts: scripts)
        try loader.data(using: .utf8)?.write(to: appURL.appendingPathComponent("frida-loader.js"))

        // 3. Gadget 配置：script 交互模式，启动即跑 loader。
        //    on_load=resume prevents a loader/configuration failure from
        //    holding or aborting the target before its main entry point.
        let config: [String: Any] = [
            "interaction": [
                "type": "script",
                "path": "frida-loader.js",
                "on_change": "reload",
                // The documented Gadget key is on_load. "resume" lets the
                // target continue even if the script cannot be loaded.
                "on_load": "resume",
            ]
        ]
        let cfgData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        try cfgData.write(to: appURL.appendingPathComponent("\(gadgetName).config"))

        // 4. 修改主二进制加载命令
        onProgress("⑤ 注入 LC_LOAD_DYLIB…")
        try MachOPatcher.insertLoadDylib(at: exeURL, dylibName: "\(gadgetName).dylib")

        onProgress("注入完成 ✓")
        injLogger.info("已注入 \(appURL.lastPathComponent)（\(scripts.count) 个脚本）")
        return exeURL
    }

    /// 工作目录里找 Payload/*.app。
    static func findAppBundle(inWorkDir work: URL) throws -> URL {
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: payload.path) else {
            throw IPAInjectError.appNotFound
        }
        guard let appName = items.first(where: { $0.hasSuffix(".app") }) else {
            throw IPAInjectError.appNotFound
        }
        return payload.appendingPathComponent(appName, isDirectory: true)
    }

    // MARK: - 打包 & 安装

    /// 沙盒 zip 压缩 work/Payload → inject/out.ipa，返回宿主侧 IPA URL。
    static func zipWorkDir(onLine: ((String) -> Void)?) async throws -> URL {
        let cmd = "apk add --no-cache zip unzip >/dev/null 2>&1; " +
            "cd \(guestInjectDir)/work && rm -f ../out.ipa && " +
            "zip -qry ../out.ipa Payload && echo ZIP_OK_$(du -h ../out.ipa | cut -f1)"
        let (out, code) = try await SandboxRunner.run(cmd, timeout: 570, onLine: onLine)
        guard code == 0, out.contains("ZIP_OK") else {
            throw IPAInjectError.sandboxFailed(out.isEmpty ? "exit \(code)" : String(out.suffix(400)))
        }
        return hostInjectDir.appendingPathComponent("out.ipa")
    }

    /// 沙盒 unzip 展开 inject/in.ipa → inject/work/Payload。
    static func unzipIPA(onLine: ((String) -> Void)?) async throws -> URL {
        let cmd = "apk add --no-cache zip unzip >/dev/null 2>&1; " +
            "cd \(guestInjectDir) && rm -rf work && mkdir -p work && " +
            "cd work && unzip -q ../in.ipa && echo UNZIP_OK"
        let (out, code) = try await SandboxRunner.run(cmd, timeout: 570, onLine: onLine)
        guard code == 0, out.contains("UNZIP_OK") else {
            throw IPAInjectError.sandboxFailed(out.isEmpty ? "exit \(code)" : String(out.suffix(400)))
        }
        return hostInjectDir.appendingPathComponent("work", isDirectory: true)
    }

    /// 调 TrollStore URL Scheme 安装。
    static func installViaTrollStore(ipaURL: URL) {
        guard let url = URL(string: "apple-magnifier://install?url=" +
                ipaURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!) else { return }
        UIApplication.shared.open(url)
        injLogger.info("已调起 TrollStore 安装: \(ipaURL.lastPathComponent)")
    }

    // MARK: - Loader 脚本生成

    /// 日志桥 + 全部已启用脚本串联为单文件。
    /// 目标 App 内的输出写到 /var/tmp/kytuT-frida.log，
    /// 宿主 App（有 no-sandbox 权限）在 Frida 日志页尾随读取同一文件。
    static func buildLoaderJS(scripts: [FridaScript]) -> String {
        var js = """
        // KyTuT Frida loader. Keep Gadget startup independent from scripts.
        (function () {
          var __f = null;
          try { __f = new File("/var/tmp/kytuT-frida.log", "a"); } catch (e) {}
          globalThis.kylog = function (msg) {
            try {
              if (__f) { __f.write(new Date().toISOString() + " " + msg + "\\n"); __f.flush(); }
            } catch (e) {}
            try { console.log(msg); } catch (e) {}
          };
          kylog("=== KyTuT Frida Gadget loaded (__TOTAL__ scripts) ===");
        })();

        """
        js = js.replacingOccurrences(of: "__TOTAL__", with: String(scripts.count))

        // Delay hooks until the target has completed its earliest startup. A
        // bad hook must be observable in the log, never a launch-time crash.
        js += "\nsetTimeout(function () {\n"
        for s in scripts {
            let safeName = s.name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            js += "\n// script: \(safeName)\n"
            js += "try {\n"
            js += s.code
            js += "\n} catch (e) {\ntry { kylog(\"[\(safeName)] script error: \" + e); } catch (_) {}\n}\n"
        }
        if scripts.isEmpty {
            js += "kylog(\"warning: no enabled scripts; Gadget only\");\n"
        }
        js += "}, 250);\n"
        return js
    }

    // MARK: - 一站式入口

    /// 克隆一个已安装（且磁盘上已解密）的 App → 注入 → 打包 → TrollStore 安装。
    static func cloneAndInject(app: InstalledAppInfo,
                               scripts: [FridaScript],
                               onProgress: @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        let work = hostInjectDir.appendingPathComponent("work", isDirectory: true)
        let payloadDir = work.appendingPathComponent("Payload", isDirectory: true)

        onProgress("① 清理工作目录并克隆 App…")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try fm.copyItem(at: app.bundleURL, to: payloadDir.appendingPathComponent(app.bundleURL.lastPathComponent))

        let appURL = try findAppBundle(inWorkDir: work)
        _ = try await injectGadget(intoApp: appURL, scripts: scripts, onProgress: onProgress)

        onProgress("⑥ 沙盒打包 IPA…")
        _ = try await zipWorkDir(onLine: nil)

        onProgress("⑦ 调起 TrollStore 安装…")
        let ipa = hostInjectDir.appendingPathComponent("out.ipa")
        try? fm.removeItem(at: hostInjectDir.appendingPathComponent("in.ipa"))
        installViaTrollStore(ipaURL: ipa)
    }

    /// 导入外部 IPA 文件 → 沙盒解包 → 注入 → 打包 → TrollStore 安装。
    static func importAndInject(ipaURL: URL,
                                scripts: [FridaScript],
                                onProgress: @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        let secured = ipaURL.startAccessingSecurityScopedResource()
        defer { if secured { ipaURL.stopAccessingSecurityScopedResource() } }

        onProgress("① 复制 IPA 到共享目录…")
        try? fm.removeItem(at: hostInjectDir.appendingPathComponent("in.ipa"))
        try fm.createDirectory(at: hostInjectDir, withIntermediateDirectories: true)
        try fm.copyItem(at: ipaURL, to: hostInjectDir.appendingPathComponent("in.ipa"))

        onProgress("② 沙盒解包…")
        let work = try await unzipIPA(onLine: nil)

        let appURL = try findAppBundle(inWorkDir: work)
        _ = try await injectGadget(intoApp: appURL, scripts: scripts, onProgress: onProgress)

        onProgress("⑥ 沙盒打包 IPA…")
        _ = try await zipWorkDir(onLine: nil)

        onProgress("⑦ 调起 TrollStore 安装…")
        installViaTrollStore(ipaURL: hostInjectDir.appendingPathComponent("out.ipa"))
    }
}
