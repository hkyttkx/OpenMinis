//
//  HookConfigBuilder.swift
//  KyTuT
//
//  Hook 配置生成与 dylib 产出服务。
//
//  设计说明（与原实现保持一致）：
//   FuckEngine.dylib 是一个**预编译好的通用 Hook 引擎**，其 __DATA,__fuckeng_hk
//   section 里内嵌了一个 64KB 的占位字符串 "@@FUCKENGINE_HOOKCONFIG@@"。
//   要产出一个可用的 Hook dylib，不需要任何编译器 —— 只需把引擎运行时读取的
//   JSON 配置原地覆盖进该 section 即可（模板容量足够，纯字节替换）。
//
//   同理 @@FUCKENGINE_COPYRIGHT@@ 与 @@FUCKENGINE_DELAY@@ 也是占位填充。
//
//   因此 App 内不依赖 clang，也不需要把源码编译成 Mach-O。
//

import Foundation

enum HookConfigBuilder {

    // MARK: 占位符与容量（与 FuckEngine.m 中的 section 声明一致）

    private static let markerHookConfig = "@@FUCKENGINE_HOOKCONFIG@@"
    private static let markerCopyright  = "@@FUCKENGINE_COPYRIGHT@@"
    private static let markerDelay      = "@@FUCKENGINE_DELAY@@"

    private static let capacityHookConfig = 65536
    private static let capacityCopyright  = 1024
    private static let capacityDelay      = 64

    // MARK: Hook 类型（与 FuckEngine 支持的 6 种一一对应）

    enum HookKind: String, Codable, CaseIterable {
        case methodSwizzle
        case flexOverride
        case modifyProperty
        case returnConstant
        case blockMethod
        case logMethod

        var title: String {
            switch self {
            case .methodSwizzle:  return "方法替换"
            case .flexOverride:   return "覆盖返回值"
            case .modifyProperty: return "修改属性"
            case .returnConstant: return "返回常量"
            case .blockMethod:    return "阻止执行"
            case .logMethod:      return "记录调用"
            }
        }
    }

    // MARK: Hook 条目

    struct Hook: Codable, Identifiable {
        var id: String = UUID().uuidString
        var className: String
        var methodName: String
        var isClassMethod: Bool = false
        var kind: HookKind
        var returnValue: String?
        var property: String?
        var argumentOverrides: [String: String]?
        var delay: Double?
        var enabled: Bool = true

        enum CodingKeys: String, CodingKey {
            case id, className, methodName, isClassMethod, kind
            case returnValue, property, argumentOverrides, delay, enabled
        }
    }

    // MARK: 产出结果

    struct BuildResult {
        var success: Bool
        var dylibPath: String?
        var message: String
    }

    // MARK: 构建

    /// 用 FuckEngine 模板产出一个注入了指定 Hook 配置的 dylib。
    /// - Parameters:
    ///   - hooks: Hook 列表
    ///   - name: 输出文件名（不含扩展名）
    ///   - hookDelay: 引擎加载后延迟多久生效（秒）
    static func build(hooks: [Hook],
                      name: String,
                      hookDelay: Double = 3.0) -> BuildResult {

        guard let templatePath = Bundle.main.path(forResource: "FuckEngine", ofType: "dylib")
                ?? Bundle.main.path(forResource: "FuckEngine", ofType: nil) else {
            return BuildResult(success: false, dylibPath: nil,
                               message: "找不到 FuckEngine.dylib 模板（应随 App 内置）")
        }

        guard var data = NSMutableData(contentsOfFile: templatePath) else {
            return BuildResult(success: false, dylibPath: nil,
                               message: "读取 FuckEngine.dylib 失败")
        }

        // 1. 生成 JSON 配置
        let configJSON: String
        do {
            configJSON = try buildJSON(hooks: hooks, hookDelay: hookDelay)
        } catch {
            return BuildResult(success: false, dylibPath: nil,
                               message: "生成 Hook 配置失败：\(error.localizedDescription)")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoderForCfg = encoder

        // 2. 依次替换三个占位符
        let ops: [(marker: String, capacity: Int, value: String)] = [
            (markerHookConfig, capacityHookConfig, configJSON),
            (markerCopyright,  capacityCopyright,
             "KyTuT HookEngine · \(hooks.count) hooks · \(ISO8601DateFormatter().string(from: Date()))"),
            (markerDelay,      capacityDelay, String(format: "%.2f", hookDelay)),
        ]

        for op in ops {
            guard let markerData = op.marker.data(using: .utf8) else {
                return BuildResult(success: false, dylibPath: nil,
                                   message: "占位符编码失败：\(op.marker)")
            }
            guard let valueData = op.value.data(using: .utf8) else {
                return BuildResult(success: false, dylibPath: nil,
                                   message: "配置内容编码失败")
            }
            guard valueData.count < op.capacity else {
                return BuildResult(success: false, dylibPath: nil,
                                   message: "配置过大（\(valueData.count) 字节），超出模板容量 \(op.capacity)")
            }

            let range = data.range(of: markerData)
            guard range.location != NSNotFound else {
                return BuildResult(success: false, dylibPath: nil,
                                   message: "模板中未找到占位符 \(op.marker)")
            }

            // 占位符 + 结尾 NUL 一起覆盖为目标内容 + NUL，其余保持原样（NUL 填充）
            var replacement = valueData
            replacement.append(0)

            // 占位符区（含其后的 NUL 填充）整体覆盖为目标内容 + NUL。
            // 模型是「模板里预留 capacity 字节的静区」，写入量不会超过该区，
            // 因为上面已经校验 valueData.count < op.capacity。
            let needed = max(replacement.count, op.marker.utf8.count + 1)
            let start = range.location
            guard start + needed <= data.length else {
                return BuildResult(success: false, dylibPath: nil,
                                   message: "模板剩余空间不足（需要 \(needed) 字节）")
            }

            var padded = replacement
            if padded.count < needed {
                padded.append(contentsOf: [UInt8](repeating: 0, count: needed - padded.count))
            }

            padded.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                data.replaceBytes(in: NSRange(location: start, length: needed), withBytes: base)
            }
        }

        // 3. 写入输出目录
        let outDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DynamicLibraries")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let fileName = sanitize(name) + ".dylib"
        let outURL = outDir.appendingPathComponent(fileName)

        do {
            try (data as Data).write(to: outURL)
            chmod(outURL.path, 0o755)
        } catch {
            return BuildResult(success: false, dylibPath: nil,
                               message: "写入产物失败：\(error.localizedDescription)")
        }

        return BuildResult(success: true, dylibPath: outURL.path,
                           message: "已生成 \(fileName)（\(hooks.count) 条 Hook）")
    }

    // MARK: JSON 组装

    private static func buildJSON(hooks: [Hook], hookDelay: Double) throws -> String {
        var hookArray: [[String: Any]] = []

        for h in hooks where h.enabled {
            var item: [String: Any] = [
                "className": h.className,
                "methodName": h.methodName,
                "isClassMethod": h.isClassMethod,
                "hookType": h.kind.rawValue,
                "enabled": true,
            ]
            if let rv = h.returnValue, !rv.isEmpty { item["returnValue"] = rv }
            if let p = h.property, !p.isEmpty { item["property"] = p }
            if let args = h.argumentOverrides, !args.isEmpty { item["argumentOverrides"] = args }
            if let d = h.delay { item["delay"] = d }
            hookArray.append(item)
        }

        let root: [String: Any] = [
            "version": 1,
            "hookDelay": hookDelay,
            "hooks": hookArray,
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.sortedKeys, .withoutEscapingSlashes])
        guard let json = String(data: jsonData, encoding: .utf8) else {
            throw NSError(domain: "HookConfigBuilder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "JSON 序列化失败"])
        }
        return json
    }

    private static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let s = String(cleaned)
        return s.isEmpty ? "HookDylib" : s
    }

    // MARK: 校验产物是否真的带上了配置

    /// 读取 dylib，确认占位符已被替换（用于自检）
    static func verify(dylibPath: String) -> String {
        guard let data = NSData(contentsOfFile: dylibPath) else { return "❌ 无法读取产物" }
        let marker = markerHookConfig.data(using: .utf8)!
        let stillPlaceholder = data.range(of: marker).location != NSNotFound
        if stillPlaceholder {
            return "❌ 占位符未被替换，配置注入失败"
        }
        return "✅ 配置已写入（文件 \(data.length) 字节）"
    }
}
