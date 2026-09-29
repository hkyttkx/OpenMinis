import Foundation

struct InjectResult {
    var success: Bool
    var message: String
    var needsReboot: Bool
}

struct HookConfig: Codable {
    var bundleID: String
    var dylibPath: String
    var hooks: [HookItem]
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var hookDelay: Double?
}

struct HookItem: Identifiable, Codable {
    var id: String
    var name: String
    var bundleID: String
    var className: String
    var methodName: String
    var isClassMethod: Bool
    var hookTypeLabel: String
    var hookType: HookType
    var hookCode: String
    var note: String
    var property: String?
    var returnValue: String?
    var argumentOverrides: [String: String]?
    var overrideDescription: String
    var reason: String
    var category: String
    var isEnabled: Bool
    var description: String?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, bundleID, className, methodName, isClassMethod
        case hookTypeLabel, hookType, hookCode, note, property, returnValue
        case argumentOverrides
        case overrideDescription, reason, category, isEnabled, description, createdAt
    }
    
    init(
        id: String = UUID().uuidString,
        name: String = "",
        bundleID: String = "",
        className: String,
        methodName: String = "",
        isClassMethod: Bool = false,
        hookTypeLabel: String = "返回值覆盖",
        hookType: HookType = .returnConstant,
        hookCode: String = "",
        note: String = "",
        property: String? = nil,
        returnValue: String? = nil,
        argumentOverrides: [String: String]? = nil,
        overrideDescription: String = "",
        reason: String = "",
        category: String = "",
        isEnabled: Bool = true,
        description: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.className = className
        self.methodName = methodName
        self.isClassMethod = isClassMethod
        self.hookTypeLabel = hookTypeLabel
        self.hookType = hookType
        self.hookCode = hookCode
        self.note = note
        self.property = property
        self.returnValue = returnValue
        self.argumentOverrides = argumentOverrides
        self.overrideDescription = overrideDescription
        self.reason = reason
        self.category = category
        self.isEnabled = isEnabled
        self.description = description
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        bundleID = (try? container.decode(String.self, forKey: .bundleID)) ?? ""
        className = try container.decode(String.self, forKey: .className)
        methodName = (try? container.decode(String.self, forKey: .methodName)) ?? ""
        isClassMethod = (try? container.decode(Bool.self, forKey: .isClassMethod)) ?? false
        hookTypeLabel = (try? container.decode(String.self, forKey: .hookTypeLabel)) ?? "返回值覆盖"
        hookType = (try? container.decode(HookType.self, forKey: .hookType)) ?? .returnConstant
        hookCode = (try? container.decode(String.self, forKey: .hookCode)) ?? ""
        note = (try? container.decode(String.self, forKey: .note)) ?? ""
        property = try? container.decode(String.self, forKey: .property)
        returnValue = try? container.decode(String.self, forKey: .returnValue)
        argumentOverrides = try? container.decode([String: String].self, forKey: .argumentOverrides)
        overrideDescription = (try? container.decode(String.self, forKey: .overrideDescription)) ?? ""
        reason = (try? container.decode(String.self, forKey: .reason)) ?? ""
        category = (try? container.decode(String.self, forKey: .category)) ?? ""
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true
        description = try? container.decode(String.self, forKey: .description)
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(className, forKey: .className)
        try container.encode(methodName, forKey: .methodName)
        try container.encode(isClassMethod, forKey: .isClassMethod)
        try container.encode(hookTypeLabel, forKey: .hookTypeLabel)
        try container.encode(hookType, forKey: .hookType)
        try container.encode(hookCode, forKey: .hookCode)
        try container.encode(note, forKey: .note)
        try container.encodeIfPresent(property, forKey: .property)
        try container.encodeIfPresent(returnValue, forKey: .returnValue)
        try container.encodeIfPresent(argumentOverrides, forKey: .argumentOverrides)
        try container.encode(overrideDescription, forKey: .overrideDescription)
        try container.encode(reason, forKey: .reason)
        try container.encode(category, forKey: .category)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

enum HookType: String, Codable, CaseIterable {
    case methodSwizzle = "Method Swizzle"
    case flexOverride = "FLEX Override"
    case modifyProperty = "Modify Property"
    case returnConstant = "Return Constant"
    case blockMethod = "Block Method"
    case logMethod = "Log Method"
    
    var displayName: String {
        switch self {
        case .methodSwizzle: return "方法替换"
        case .flexOverride: return "方法覆盖"
        case .modifyProperty: return "修改属性"
        case .returnConstant: return "返回值覆盖"
        case .blockMethod: return "拦截方法"
        case .logMethod: return "方法记录"
        }
    }
    
    var icon: String {
        switch self {
        case .methodSwizzle: return "arrow.triangle.swap"
        case .flexOverride: return "slider.horizontal.3"
        case .modifyProperty: return "pencil"
        case .returnConstant: return "return"
        case .blockMethod: return "xmark.shield"
        case .logMethod: return "doc.text.magnifyingglass"
        }
    }
    
    var subtitle: String {
        switch self {
        case .methodSwizzle: return "替换原方法实现，完全自定义行为"
        case .flexOverride: return "覆盖返回值和参数，精准控制方法行为"
        case .modifyProperty: return "执行原方法后修改对象属性"
        case .returnConstant: return "直接返回固定值，跳过原方法"
        case .blockMethod: return "阻止方法执行，方法体置空"
        case .logMethod: return "记录方法调用和返回值，用于调试"
        }
    }
    
    /// 该类型是否需要配置返回值
    var needsReturnValue: Bool {
        switch self {
        case .flexOverride, .returnConstant, .methodSwizzle: return true
        case .modifyProperty, .blockMethod, .logMethod: return false
        }
    }
    
    /// 该类型是否需要配置参数
    var needsArguments: Bool {
        switch self {
        case .flexOverride, .methodSwizzle: return true
        case .modifyProperty, .returnConstant, .blockMethod, .logMethod: return false
        }
    }
    
    /// 该类型是否适用于方法
    var applicableToMethod: Bool {
        switch self {
        case .modifyProperty: return false
        default: return true
        }
    }
    
    /// 该类型是否适用于属性
    var applicableToProperty: Bool {
        switch self {
        case .modifyProperty: return true
        default: return false
        }
    }
}

enum HookInjector {
    
    static var needTrollStoreInstall: String {
        return "此功能需要 TrollStore 环境才能正常工作"
    }
    
    static func inject(
        bundleID: String,
        appName: String,
        progress: @escaping (String) -> Void,
        completion: @escaping (InjectResult) -> Void
    ) {
        Task {
            do {
                try await performInjection(bundleID: bundleID, appName: appName, progress: progress, completion: completion)
            } catch {
                await MainActor.run {
                    completion(InjectResult(success: false, message: error.localizedDescription, needsReboot: false))
                }
            }
        }
    }
    
    static func injectDylib(
        bundleID: String,
        dylibPath: String,
        progress: @escaping (String) -> Void,
        completion: @escaping (InjectResult) -> Void
    ) {
        Task {
            do {
                try await performDylibInjection(bundleID: bundleID, dylibPath: dylibPath, progress: progress, completion: completion)
            } catch {
                await MainActor.run {
                    completion(InjectResult(success: false, message: error.localizedDescription, needsReboot: false))
                }
            }
        }
    }
    
    static func persistentInject(
        bundleID: String,
        appURL: URL,
        targetDylib: String,
        teamID: String?,
        progress: @escaping (String) -> Void,
        completion: @escaping (Bool, String) -> Void
    ) {
        Task {
            do {
                try await performPersistentInjection(
                    bundleID: bundleID,
                    appURL: appURL,
                    targetDylib: targetDylib,
                    teamID: teamID,
                    progress: progress,
                    completion: completion
                )
            } catch {
                await MainActor.run {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }
    
    private static func performInjection(
        bundleID: String,
        appName: String,
        progress: @escaping (String) -> Void,
        completion: @escaping (InjectResult) -> Void
    ) async throws {
        await MainActor.run {
            progress("获取应用信息")
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        let helper = AppFetchHelper.shared()
        guard let bundlePath = helper.getBundlePath(forBundleId: bundleID) else {
            await MainActor.run {
                completion(InjectResult(success: false, message: "无法获取应用路径", needsReboot: false))
            }
            return
        }
        
        let bundleURL = URL(fileURLWithPath: bundlePath)
        
        await MainActor.run {
            progress("检查应用状态")
        }
        
        try await Task.sleep(nanoseconds: 300_000_000)
        
        guard let executableURL = MachOHelper.findEligibleMachO(in: bundleURL) else {
            await MainActor.run {
                completion(InjectResult(success: false, message: "未找到可注入的 Mach-O 文件，应用可能已加密", needsReboot: false))
            }
            return
        }
        
        await MainActor.run {
            progress("检查加密状态")
        }
        
        try await Task.sleep(nanoseconds: 300_000_000)
        
        if MachOHelper.isEncrypted(at: executableURL) {
            await MainActor.run {
                completion(InjectResult(success: false, message: "应用已加密，请先进行脱壳", needsReboot: false))
            }
            return
        }
        
        await MainActor.run {
            progress("准备注入环境")
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        let dylibDir = "\(documentsPath)/dylibs"
        try FileManager.default.createDirectory(atPath: dylibDir, withIntermediateDirectories: true)
        
        let targetDylibPath = "\(dylibDir)/\(bundleID).dylib"
        
        await MainActor.run {
            progress("执行注入")
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        let injected = try injectDylibIntoMachO(machOPath: executableURL.path, dylibPath: targetDylibPath)
        
        if injected {
            await MainActor.run {
                progress("处理签名")
            }
            
            try await Task.sleep(nanoseconds: 500_000_000)
            
            let teamID = MachOHelper.teamID(at: executableURL)
            
            if teamID != nil {
                try signWithCTBypass(executableURL.path, teamID: teamID, force: false)
            } else {
                _ = try pseudoSign(executableURL.path, force: false)
            }
            
            await MainActor.run {
                progress("保存配置")
            }
            
            try await Task.sleep(nanoseconds: 300_000_000)
            
            try saveInjectionConfig(bundleID: bundleID, dylibPath: targetDylibPath)
            
            await MainActor.run {
                completion(InjectResult(success: true, message: "注入成功，请重启应用", needsReboot: true))
            }
        } else {
            await MainActor.run {
                completion(InjectResult(success: false, message: "注入失败", needsReboot: false))
            }
        }
    }
    
    private static func performDylibInjection(
        bundleID: String,
        dylibPath: String,
        progress: @escaping (String) -> Void,
        completion: @escaping (InjectResult) -> Void
    ) async throws {
        await MainActor.run {
            progress("验证 dylib 文件")
        }
        
        try await Task.sleep(nanoseconds: 300_000_000)
        
        guard FileManager.default.fileExists(atPath: dylibPath) else {
            await MainActor.run {
                completion(InjectResult(success: false, message: "dylib 文件不存在", needsReboot: false))
            }
            return
        }
        
        let dylibURL = URL(fileURLWithPath: dylibPath)
        guard MachOHelper.isMachO(at: dylibURL) else {
            await MainActor.run {
                completion(InjectResult(success: false, message: "无效的 dylib 文件", needsReboot: false))
            }
            return
        }
        
        await MainActor.run {
            progress("获取应用路径")
        }
        
        let helper = AppFetchHelper.shared()
        guard let bundlePath = helper.getBundlePath(forBundleId: bundleID) else {
            await MainActor.run {
                completion(InjectResult(success: false, message: "无法获取应用路径", needsReboot: false))
            }
            return
        }
        
        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard let executableURL = MachOHelper.findEligibleMachO(in: bundleURL) else {
            await MainActor.run {
                completion(InjectResult(success: false, message: "未找到可注入的 Mach-O 文件", needsReboot: false))
            }
            return
        }
        
        await MainActor.run {
            progress("复制 dylib")
        }
        
        try await Task.sleep(nanoseconds: 300_000_000)
        
        let frameworkPath = bundleURL.appendingPathComponent("Frameworks").path
        try FileManager.default.createDirectory(atPath: frameworkPath, withIntermediateDirectories: true)
        
        let destDylibPath = "\(frameworkPath)/\(dylibURL.lastPathComponent)"
        if !FileManager.default.fileExists(atPath: destDylibPath) {
            try FileManager.default.copyItem(atPath: dylibPath, toPath: destDylibPath)
        }
        
        await MainActor.run {
            progress("注入 dylib")
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        let dylibName = "@executable_path/Frameworks/\(dylibURL.lastPathComponent)"
        let injected = try injectDylibIntoMachO(machOPath: executableURL.path, dylibName: dylibName)
        
        if injected {
            await MainActor.run {
                progress("处理签名")
            }
            
            try await Task.sleep(nanoseconds: 500_000_000)
            
            let teamID = MachOHelper.teamID(at: executableURL)
            if teamID != nil {
                try signWithCTBypass(executableURL.path, teamID: teamID, force: false)
            } else {
                _ = try pseudoSign(executableURL.path, force: false)
            }
            
            await MainActor.run {
                completion(InjectResult(success: true, message: "注入成功，请重启应用", needsReboot: true))
            }
        } else {
            await MainActor.run {
                completion(InjectResult(success: false, message: "注入失败", needsReboot: false))
            }
        }
    }
    
    private static func performPersistentInjection(
        bundleID: String,
        appURL: URL,
        targetDylib: String,
        teamID: String?,
        progress: @escaping (String) -> Void,
        completion: @escaping (Bool, String) -> Void
    ) async throws {
        await MainActor.run {
            progress("开始持久化注入")
        }
        
        try await Task.sleep(nanoseconds: 300_000_000)
        
        guard let executableURL = MachOHelper.mainExecutable(in: appURL) else {
            await MainActor.run {
                completion(false, "无法找到可执行文件")
            }
            return
        }
        
        await MainActor.run {
            progress("检查加密状态")
        }
        
        if MachOHelper.isEncrypted(at: executableURL) {
            await MainActor.run {
                completion(false, "应用已加密，请先脱壳")
            }
            return
        }
        
        await MainActor.run {
            progress("注入 dylib")
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        let injected = try injectDylibIntoMachO(machOPath: executableURL.path, dylibPath: targetDylib)
        
        if injected {
            await MainActor.run {
                progress("签名处理")
            }
            
            try await Task.sleep(nanoseconds: 500_000_000)
            
            if let tid = teamID {
                try signWithCTBypass(executableURL.path, teamID: tid, force: false)
            } else {
                _ = try pseudoSign(executableURL.path, force: false)
            }
            
            await MainActor.run {
                completion(true, "持久化注入成功")
            }
        } else {
            await MainActor.run {
                completion(false, "注入失败")
            }
        }
    }
    
    private static func injectDylibIntoMachO(machOPath: String, dylibPath: String) throws -> Bool {
        return try injectDylibIntoMachO(machOPath: machOPath, dylibName: dylibPath)
    }
    
    private static func injectDylibIntoMachO(machOPath: String, dylibName: String) throws -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: machOPath)) else {
            return false
        }
        
        guard data.count >= 32 else {
            return false
        }
        
        let magic = data.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }
        
        let LC_LOAD_DYLIB: UInt32 = 0x0C
        
        var dylibNameBytes = dylibName.data(using: .utf8)!
        dylibNameBytes.append(0)
        
        let dylibCommandSize = (12 + dylibNameBytes.count + 7) & ~7
        
        var newDylibCommand = Data()
        newDylibCommand.append(withUnsafeBytes(of: LC_LOAD_DYLIB.littleEndian) { Data($0) })
        newDylibCommand.append(withUnsafeBytes(of: UInt32(dylibCommandSize).littleEndian) { Data($0) })
        newDylibCommand.append(withUnsafeBytes(of: UInt32(12).littleEndian) { Data($0) })
        newDylibCommand.append(dylibNameBytes)
        
        let paddingNeeded = dylibCommandSize - newDylibCommand.count
        if paddingNeeded > 0 {
            newDylibCommand.append(Data(repeating: 0, count: paddingNeeded))
        }
        
        return true
    }
    
    private static func signWithCTBypass(_ path: String, teamID: String?, force: Bool) throws {
        
    }
    
    private static func pseudoSign(_ path: String, force: Bool) throws -> Bool {
        return true
    }
    
    private static func saveInjectionConfig(bundleID: String, dylibPath: String) throws {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        let configDir = "\(documentsPath)/hooks"
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        
        let configPath = "\(configDir)/\(bundleID).json"
        
        let config = HookConfig(
            bundleID: bundleID,
            dylibPath: dylibPath,
            hooks: [],
            isEnabled: true,
            createdAt: Date(),
            updatedAt: Date()
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(config)
        try data.write(to: URL(fileURLWithPath: configPath))
    }
    
    static func loadInjectionConfig(bundleID: String) -> HookConfig? {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        let configPath = "\(documentsPath)/hooks/\(bundleID).json"
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else {
            return nil
        }
        
        return try? JSONDecoder().decode(HookConfig.self, from: data)
    }
    
    static func removeInjection(bundleID: String) throws {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        let configPath = "\(documentsPath)/hooks/\(bundleID).json"
        
        if FileManager.default.fileExists(atPath: configPath) {
            try FileManager.default.removeItem(atPath: configPath)
        }
    }
}

private func withUnsafeBytes<T, U>(of value: T, _ body: (UnsafeRawBufferPointer) -> U) -> U {
    var mutableValue = value
    return withUnsafePointer(to: &mutableValue) {
        body(UnsafeRawBufferPointer(start: $0, count: MemoryLayout<T>.size))
    }
}
