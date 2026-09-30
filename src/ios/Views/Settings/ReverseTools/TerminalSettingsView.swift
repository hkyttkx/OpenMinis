//
//  TerminalSettingsView.swift
//  KyTuT
//
//  「设置 → 终端」
//
//  终端权限档位 + 行为设置。
//
//  三档权限：
//    .appNative   App 原生权限 —— 默认。iSH 内以当前进程身份运行，
//                 只看得见 fakefs 与已挂载进沙盒的宿主目录。
//    .ishRoot     iSH Root —— iSH 内核的 PID 1 天然是 root，让 shell
//                 以 root 身份 fork。对 Alpine rootfs 与挂载点有完全
//                 权限（读写挂载点时可写宿主文件）。
//    .systemRoot  系统 Root（实验性）—— 经 roothide jbserver 提权，
//                 尝试获取真实 iOS root。依赖平台签名标志
//                 CS_PLATFORM_BINARY 生效；未生效时自动回落到 iSH Root。
//
//  AI 联动：AI 的 shell_execute 工具走同一套权限，选 iSH Root 后
//  AI 执行的命令同样带 root。
//

import SwiftUI

// MARK: - 权限档位

enum TerminalPrivilege: String, CaseIterable, Identifiable {
    case appNative
    case ishRoot
    case systemRoot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appNative:  return "App 原生权限"
        case .ishRoot:    return "iSH Root"
        case .systemRoot: return "系统 Root（实验性）"
        }
    }

    var detail: String {
        switch self {
        case .appNative:
            return "以当前应用身份运行，只能访问沙盒与已挂载的目录。最安全。"
        case .ishRoot:
            return "在 iSH 模拟环境中以 root 运行，可读写整个 Alpine 根文件系统；对读写挂载的宿主目录同样可写。"
        case .systemRoot:
            return "尝试通过越狱环境获取真实 iOS root，可访问沙盒外的系统路径。依赖平台签名标志，可能失败。"
        }
    }

    var systemImage: String {
        switch self {
        case .appNative:  return "person.fill"
        case .ishRoot:    return "person.badge.key.fill"
        case .systemRoot: return "crown.fill"
        }
    }

    var tint: Color {
        switch self {
        case .appNative:  return .blue
        case .ishRoot:    return .orange
        case .systemRoot: return .purple
        }
    }
}

// MARK: - 设置存储

@MainActor
final class TerminalSettings: ObservableObject {

    static let shared = TerminalSettings()

    private static let privilegeKey = "terminal.privilege"
    private static let aiShellKey = "terminal.allowAIShell"
    private static let workingDirKey = "terminal.workingDir"
    private static let maxOutputKey = "terminal.maxOutputLines"

    @Published var privilege: TerminalPrivilege {
        didSet { UserDefaults.standard.set(privilege.rawValue, forKey: Self.privilegeKey) }
    }

    /// 允许 AI 通过 shell_execute 调用终端
    @Published var allowAIShell: Bool {
        didSet { UserDefaults.standard.set(allowAIShell, forKey: Self.aiShellKey) }
    }

    /// shell 启动工作目录
    @Published var workingDirectory: String {
        didSet { UserDefaults.standard.set(workingDirectory, forKey: Self.workingDirKey) }
    }

    /// 单次命令保留的最大输出行数
    @Published var maxOutputLines: Int {
        didSet { UserDefaults.standard.set(maxOutputLines, forKey: Self.maxOutputKey) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.privilegeKey) ?? TerminalPrivilege.appNative.rawValue
        privilege = TerminalPrivilege(rawValue: raw) ?? .appNative

        if UserDefaults.standard.object(forKey: Self.aiShellKey) == nil {
            allowAIShell = true
        } else {
            allowAIShell = UserDefaults.standard.bool(forKey: Self.aiShellKey)
        }

        workingDirectory = UserDefaults.standard.string(forKey: Self.workingDirKey) ?? "/root"

        let lines = UserDefaults.standard.integer(forKey: Self.maxOutputKey)
        maxOutputLines = lines > 0 ? lines : 2000
    }

    /// 供终端启动时构造 shell 参数
    var shellLaunchArguments: [String] {
        switch privilege {
        case .appNative:
            return ["/bin/sh", "-l"]
        case .ishRoot, .systemRoot:
            // iSH 内核里 PID 1 即 root；用 login shell 保证 PATH 与
            // /etc/profile 生效，root 身份由内核上下文决定。
            return ["/bin/sh", "-l"]
        }
    }

    /// 给 AI 的工具说明用
    func describe() -> String {
        """
        终端权限档位：\(privilege.title)
        AI 终端调用：\(allowAIShell ? "已开启" : "已关闭")
        工作目录：\(workingDirectory)
        输出上限：\(maxOutputLines) 行
        """
    }
}

// MARK: - 设置页

struct TerminalSettingsView: View {
    @StateObject private var settings = TerminalSettings.shared

    var body: some View {
        List {
            Section {
                ForEach(TerminalPrivilege.allCases) { p in
                    Button {
                        settings.privilege = p
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: p == settings.privilege ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(p == settings.privilege ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Image(systemName: p.systemImage)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(p.tint)
                                    Text(p.title).font(.body.weight(.medium))
                                }
                                Text(p.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("权限档位")
            } footer: {
                Text("控制终端命令以什么身份执行。系统 Root 依赖越狱环境的平台签名标志，若不可用会自动回落到 iSH Root。")
            }

            Section {
                Toggle(isOn: $settings.allowAIShell) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("允许 AI 调用终端")
                        Text("开启后 AI 可通过 shell_execute 执行命令")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("AI 联动")
            } footer: {
                Text("AI 执行的命令使用与上方相同的权限档位。关闭后 AI 将无法执行任何 shell 命令。")
            }

            Section {
                HStack {
                    Text("工作目录")
                    Spacer()
                    TextField("/root", text: $settings.workingDirectory)
                        .multilineTextAlignment(.trailing)
                        .font(.caption.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                HStack {
                    Text("输出上限")
                    Spacer()
                    TextField("2000", value: $settings.maxOutputLines, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospacedDigit())
                        .frame(width: 90)
                    Text("行").foregroundStyle(.secondary)
                }
            } header: {
                Text("行为")
            }

            Section {
                Text(settings.describe())
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("当前状态")
            }

            Section {
                Label("iSH 是用户态模拟环境。iSH Root 对 Alpine 根文件系统是完全权限，但跨出 fakefs 访问真实 iOS 系统文件仍受系统沙盒限制 —— 那部分通过「宿主访问」的挂载点实现。",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("说明")
            }
        }
        .navigationTitle("终端")
        .navigationBarTitleDisplayMode(.inline)
    }
}
