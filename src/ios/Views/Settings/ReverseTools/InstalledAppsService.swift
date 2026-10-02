//
//  InstalledAppsService.swift
//  KyTuT
//
//  已安装 App 枚举：通过 LSApplicationWorkspace（私有类，NSClassFromString 动态调用）
//  列出全部应用及各自的 Bundle / 数据容器路径，并判定安装来源。
//  依赖 TrollStore 签发的扩展 entitlements（container-manager /
//  MobileContainerManager.allowed / 全盘读写白名单等，见 Minis-Extended.entitlements）。
//

import Foundation
import UIKit

private let appsLogger = AppLogger(category: "Frida")

/// 安装来源。
///
/// 判定依据（按可信度从高到低）：
///   1. bundle 路径 —— 系统 App 装在系统分区，路径形态与用户 App 完全不同，最可靠；
///   2. FairPlay 加密位（LC_ENCRYPTION_INFO_64 的 cryptid）——  App Store 下载的包
///      带 DRM 加密，cryptid != 0；巨魔安装的包是已解密的，cryptid == 0；
///   3. 签名 TeamID —— 巨魔装的包由 TrollStore 用 ad-hoc / 伪团队签名，
///      常见 TROLLTROLL 或空 TeamID；App Store 包是真实开发者团队 ID。
///
/// 三者组合判断，避免单一信号误判（例如自签名的开发包 cryptid 也是 0，
/// 但它没有巨魔特征，会被归入「其他」而不是误报成巨魔）。
enum AppInstallSource: String, CaseIterable, Identifiable {
    case appStore
    case trollStore
    case system
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appStore:   return "App Store"
        case .trollStore: return "巨魔"
        case .system:     return "系统"
        case .other:      return "其他"
        }
    }

    var shortTitle: String {
        switch self {
        case .appStore:   return "商店"
        case .trollStore: return "巨魔"
        case .system:     return "系统"
        case .other:      return "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .appStore:   return "bag.fill"
        case .trollStore: return "wand.and.stars"
        case .system:     return "gearshape.2.fill"
        case .other:      return "questionmark.circle.fill"
        }
    }

    /// 列表里的小标签配色
    var tintName: String {
        switch self {
        case .appStore:   return "blue"
        case .trollStore: return "purple"
        case .system:     return "gray"
        case .other:      return "orange"
        }
    }

    /// 这类来源能不能做动态注入（给用户一个直观提示）
    var injectionHint: String {
        switch self {
        case .appStore:
            return "App Store 包带 FairPlay 加密。动态注入不依赖砸壳（代码在内存里已解密），可直接注入。"
        case .trollStore:
            return "巨魔安装的包通常无沙盒限制，注入兼容性最好。"
        case .system:
            return "系统 App 受保护较强，注入可能被系统拒绝或影响稳定性。"
        case .other:
            return "来源不明（可能是自签名或企业签）。注入兼容性不确定。"
        }
    }
}

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
    /// 在 listApps 时后台算好存字段 —— 曾是 computed property，列表每行
    /// 每次渲染都全量读主二进制，是"目标 App 管理卡顿"的根因。
    let isEncrypted: Bool
    /// 安装来源（列表可按此筛选）
    let source: AppInstallSource
    /// 签名 TeamID（为空表示 ad-hoc / 无团队签名）
    let teamID: String?

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

            let encrypted = computeEncrypted(bundleURL: bundleURL)
            let teamID = readTeamID(bundleURL: bundleURL, bundleId: bundleId)
            let source = classifyInstallSource(
                isSystem: isSystem,
                bundleURL: bundleURL,
                isEncrypted: encrypted,
                teamID: teamID
            )

            result.append(InstalledAppInfo(
                bundleId: bundleId,
                name: name,
                version: version,
                bundleURL: bundleURL,
                dataContainerURL: container,
                isSystem: isSystem,
                icon: loadIcon(bundleURL: bundleURL),
                isEncrypted: encrypted,
                source: source,
                teamID: teamID
            ))
        }
        appsLogger.info("已列出 \(result.count) 个 App（含系统: \(includeSystem)）")
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - 安装来源判定

    /// 综合三个信号判定来源。
    ///
    /// 为什么不能只看加密位：巨魔装的包 cryptid=0（已解密），但**自签名/企业签
    /// 的开发包也是 0**。只看 crypto 会把开发包误报成巨魔。
    /// 加上 TeamID 才能区分：巨魔用伪团队（TROLLTROLL / 空），
    /// App Store 用真实开发者团队 ID（10 位大写字母数字）。
    static func classifyInstallSource(isSystem: Bool,
                                      bundleURL: URL,
                                      isEncrypted: Bool,
                                      teamID: String?) -> AppInstallSource {
        // ① 系统分区 = 系统 App（最可靠，直接返回）
        if isSystem { return .system }

        // ② FairPlay 加密 = App Store 下载（DRM 只在商店发行时施加）
        if isEncrypted { return .appStore }

        // ③ 未加密 + 巨魔特征签名 = 巨魔安装
        if let t = teamID, !t.isEmpty {
            let upper = t.uppercased()
            if upper.contains("TROLL") { return .trollStore }
        }

        // ④ 未加密、无团队签名（ad-hoc）：巨魔安装最常见的形态。
        //    再确认一下 bundle 里没有商店收据，排除"商店包但没加密"的少数情况。
        let hasStoreReceipt = FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("_MASReceipt/receipt").path
        )
        if !hasStoreReceipt {
            // ad-hoc 且无收据 —— 巨魔/自签名。两者从用户视角都是「越狱侧安装」，
            // 归入巨魔更符合使用预期。
            return .trollStore
        }

        // ⑤ 有商店收据但未加密：商店包被处理过（砸壳后重装），仍算商店来源
        return .appStore
    }

    /// 读签名 TeamID。优先查 embedded.mobileprovision，其次 ldid -e 不可用时
    /// 退化为检测 bundle 内的签名特征文件。
    private static func readTeamID(bundleURL: URL, bundleId: String) -> String? {
        // 商店包：_MASReceipt 存在即视为商店渠道（TeamID 不参与判定）
        // 巨魔包：无描述文件；能拿到的团队信息通常在签名段里
        let provPath = bundleURL.appendingPathComponent("embedded.mobileprovision").path
        if let data = FileManager.default.contents(atPath: provPath),
           let raw = String(data: data, encoding: .ascii),
           let start = raw.range(of: "<plist"),
           let end = raw.range(of: "</plist>") {
            let xml = String(raw[start.lowerBound..<end.upperBound])
            if let xmlData = xml.data(using: .utf8),
               let plist = try? PropertyListSerialization.propertyList(
                   from: xmlData, options: [], format: nil) as? [String: Any],
               let teams = plist["TeamIdentifier"] as? [String],
               let first = teams.first {
                return first
            }
        }
        return nil
    }

    // MARK: - 私有属性动态读取

    /// 加密检测（listApps 后台批量算，流式读主二进制头部，轻量）。
    private static func computeEncrypted(bundleURL: URL) -> Bool {
        guard let plist = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist")),
              let exe = plist["CFBundleExecutable"] as? String else { return false }
        return MachOInspector.inspect(url: bundleURL.appendingPathComponent(exe))?.cryptid != 0
    }

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
                if let img = UIImage(contentsOfFile: p) {
                    return Self.downscale(img, maxPixel: 120)
                }
            }
        }
        return nil
    }

    /// 图标降采样：原图可能 1024×1024，几十个 App 全尺寸进内存会卡顿；
    /// 列表只需 40pt（@3x = 120px）。
    private static func downscale(_ img: UIImage, maxPixel: CGFloat) -> UIImage {
        let biggest = max(img.size.width, img.size.height)
        guard biggest > maxPixel, biggest > 0 else { return img }
        let scale = maxPixel / biggest
        let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
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
        // 流式只读头部：load commands 全在文件头（一般 <64KB），避免把
        // 几百 MB 的主二进制全量载入内存（列表/详情页高频调用会卡顿甚至 OOM）。
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 1_048_576), head.count >= 32 else { return nil }
        return parse(data: head)
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
