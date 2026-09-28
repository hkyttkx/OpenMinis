//
//  InstalledAppsService.swift
//  KyTuT
//
//  已安装 App 枚举：通过 LSApplicationWorkspace（私有类，NSClassFromString 动态调用）
//  列出全部应用及各自的 Bundle / 数据容器路径。
//  依赖 TrollStore 签发的扩展 entitlements（no-sandbox / container-manager /
//  MobileContainerManager.allowed 等，见 Minis-Extended.entitlements）。
//

import Foundation
import UIKit

private let appsLogger = AppLogger(category: "Frida")

struct InstalledAppInfo: Identifiable {
    var id: String { bundleId }
    let bundleId: String
    let name: String
    let version: String
    let bundleURL: URL          // /var/containers/Bundle/Application/<UUID>/X.app
    let dataContainerURL: URL?  // /var/mobile/Containers/Data/Application/<UUID>
    let isSystem: Bool
    let icon: UIImage?

    /// 主二进制是否仍带 FairPlay 加密（App Store 包未砸壳）。
    var isEncrypted: Bool {
        guard let exe = mainExecutableURL,
              let info = MachOInspector.inspect(url: exe) else { return false }
        return info.cryptid != 0
    }

    var mainExecutableURL: URL? {
        guard let plist = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist")),
              let exe = plist["CFBundleExecutable"] as? String else { return nil }
        return bundleURL.appendingPathComponent(exe)
    }

    /// Bundle 目录大小（含资源），单位字节。
    var bundleSize: Int64 {
        FileManager.default.accumulatedFileSize(of: bundleURL)
    }
}

enum InstalledAppsService {

    /// LSApplicationWorkspace 是 MobileCoreServices 里的私有类。
    /// 先 dlopen 确保框架在进程内，再 NSClassFromString 取类，
    /// 全程 perform/KVC 动态调用，无编译期依赖。
    static func listApps(includeSystem: Bool = false) -> [InstalledAppInfo] {
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY)
        guard
            let wsClass = NSClassFromString("LSApplicationWorkspace"),
            let workspace = (wsClass as AnyObject)
                .perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject,
            let rawApps = workspace
                .perform(NSSelectorFromString("allApplications"))?.takeUnretainedValue() as? [NSObject]
        else {
            appsLogger.error("LSApplicationWorkspace 不可用（权限不足或框架加载失败）")
            return []
        }

        var result: [InstalledAppInfo] = []
        for proxy in rawApps {
            guard let bundleId = kvcString(proxy, "bundleIdentifier"),
                  let bundleURL = kvcURL(proxy, "bundleURL") else { continue }

            let path = bundleURL.path
            let isSystem = !path.contains("/containers/Bundle/Application/")
            if isSystem && !includeSystem { continue }
            if bundleId.hasPrefix("com.apple.") && isSystem && !includeSystem { continue }

            let name = kvcString(proxy, "localizedName")
                ?? (NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist"))?["CFBundleDisplayName"] as? String)
                ?? bundleId
            let version = kvcString(proxy, "shortVersionString") ?? ""
            let container = kvcURL(proxy, "dataContainerURL")

            result.append(InstalledAppInfo(
                bundleId: bundleId,
                name: name,
                version: version,
                bundleURL: bundleURL,
                dataContainerURL: container,
                isSystem: isSystem,
                icon: loadIcon(bundleURL: bundleURL)
            ))
        }
        appsLogger.info("已列出 \(result.count) 个 App（含系统: \(includeSystem)）")
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - 私有属性动态读取

    private static func kvcString(_ obj: NSObject, _ key: String) -> String? {
        (try? obj.value(forKey: key)) as? String
    }

    private static func kvcURL(_ obj: NSObject, _ key: String) -> URL? {
        (try? obj.value(forKey: key)) as? URL
    }

    // MARK: - 图标

    /// 从 Bundle 的 Info.plist CFBundleIcons 读图标文件。
    /// 未命中（纯 asset catalog 图标等）返回 nil，UI 显示占位。
    private static func loadIcon(bundleURL: URL) -> UIImage? {
        guard let plist = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist")) else { return nil }
        let candidates: [String] = {
            var names: [String] = []
            if let icons = plist["CFBundleIcons"] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
               let files = primary["CFBundleIconFiles"] as? [String] {
                names.append(contentsOf: files)
            }
            if let legacy = plist["CFBundleIconFiles"] as? [String] {
                names.append(contentsOf: legacy)
            }
            return names
        }()
        // CFBundleIconFiles 按尺寸升序，末尾最大；优先无后缀名条目补 @3x/@2x
        for base in candidates.reversed() {
            for suffix in ["@3x.png", "@2x.png", ".png", ""] {
                let p = bundleURL.appendingPathComponent(base + suffix).path
                if let img = UIImage(contentsOfFile: p) { return img }
            }
        }
        return nil
    }
}

// MARK: - Mach-O 只读检查

/// 轻量 Mach-O 头解析：只读用途（加密状态检测）。
enum MachOInspector {
    struct Info {
        let ncmds: UInt32
        let sizeofcmds: UInt32
        let cryptid: UInt32
    }

    static func inspect(url: URL) -> Info? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data)
    }

    static func parse(data: Data) -> Info? {
        guard data.count >= 32 else { return nil }
        let magic = data.readLE32(0)
        guard magic == 0xFEEDFACF else { return nil } // 仅支持 thin arm64
        let ncmds = data.readLE32(16)
        let sizeofcmds = data.readLE32(20)

        var cryptid: UInt32 = 0
        var off = 32
        for _ in 0..<Int(ncmds) {
            guard off + 8 <= data.count else { break }
            let cmd = data.readLE32(off)
            let cmdsize = Int(data.readLE32(off + 4))
            guard cmdsize >= 8 else { break }
            if cmd == 0x2C /* LC_ENCRYPTION_INFO_64 */, off + 20 <= data.count {
                cryptid = data.readLE32(off + 16)
            }
            off += cmdsize
        }
        return Info(ncmds: ncmds, sizeofcmds: sizeofcmds, cryptid: cryptid)
    }
}

// MARK: - 小工具

private extension Data {
    func readLE32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let i = startIndex + offset
        return UInt32(self[i]) | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 3]) << 24)
    }
}

extension FileManager {
    /// 递归累计目录大小（字节）。读不到按 0。
    func accumulatedFileSize(of url: URL) -> Int64 {
        guard let en = enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                  options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in en {
            if let size = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               size.isRegularFile == true {
                total += Int64(size.fileSize ?? 0)
            }
        }
        return total
    }
}
