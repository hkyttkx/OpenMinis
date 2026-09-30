import SwiftUI
import NetworkExtension
import TunnelServices

struct PacketCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vpnManager = VPNManager()
    @ObservedObject private var appSettings = AppSettingsManager.shared

    @AppStorage("packethound.capture.enabled") private var captureEnabled = true
    @AppStorage("packethound.rewrite.enabled") private var rewriteEnabled = true

    @State private var certState: CACertificateTrustState = .missing
    @State private var showCertSetup = false

    @State private var breatheAnimation = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    vpnToggleCard
                    trafficCaptureCard
                    rewriteCard
                    certCard

                    NavigationLink(destination: PacketCaptureRecordView()) {
                        quickActionRow(
                            icon: "list.bullet.rectangle.portrait",
                            iconColor: .purple,
                            title: "抓包记录",
                            subtitle: "查看已捕获的 HTTP/HTTPS 请求"
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("VPN 抓包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onAppear {
            CAManager.shared.initializeCertificateIfNeeded()
            certState = CAManager.shared.certificateTrustState()
        }
        .sheet(isPresented: $showCertSetup) {
            PacketCaptureCertView()
        }
    }

    // MARK: - VPN 开关卡片
    private var vpnToggleCard: some View {
        Button(action: toggleVPN) {
            VStack(spacing: 8) {
                if vpnManager.isConnected {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.white)
                        .scaleEffect(breatheAnimation && appSettings.isAppActive ? 1.15 : 1.0)
                        .opacity(breatheAnimation && appSettings.isAppActive ? 0.7 : 1.0)
                        .animation(appSettings.isAppActive ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default, value: breatheAnimation && appSettings.isAppActive)
                        .onAppear { breatheAnimation = true }
                } else {
                    Image(systemName: "shield.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.white)
                        .onAppear { breatheAnimation = false }
                }

                HStack(spacing: 6) {
                    if vpnManager.isConnected {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                    }
                    Text(vpnManager.isConnected ? "停止抓包" : "开始抓包")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                }

                Text(statusText)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: vpnManager.isConnected
                                ? [Color.red.opacity(0.9), Color.red.opacity(0.65)]
                                : [Color.black.opacity(0.85), Color.black.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 流量抓取卡片
    private var trafficCaptureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("流量抓取", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Toggle("", isOn: $captureEnabled)
                    .labelsHidden()
                    .toggleStyle(DarkToggleStyle())
            }

            Text("抓取 HTTP/HTTPS 请求数据并保存在抓包记录中")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.green.opacity(0.75))
        )
    }

    // MARK: - HTTP 重写卡片
    private var rewriteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("HTTP 重写", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Toggle("", isOn: $rewriteEnabled)
                    .labelsHidden()
                    .toggleStyle(DarkToggleStyle())
            }

            Text("动态修改请求/响应头、重定向、替换 Body 内容")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))

            HStack {
                Spacer()
                NavigationLink(destination: PHRewriteListView()) {
                    Text("规则配置")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.purple.opacity(0.7))
        )
    }

    // MARK: - 证书卡片
    private var certCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(certBadgeColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "lock.shield")
                    .font(.system(size: 20))
                    .foregroundColor(certBadgeColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("CA 证书")
                    .font(.system(size: 15, weight: .semibold))
                Text(certStatusText)
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
            }

            Spacer()

            Button { showCertSetup = true } label: {
                Text(certState == .trusted ? "已配置" : "去配置")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(certState == .trusted ? Color.green : Color.orange)
                    .clipShape(Capsule())
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - 快捷入口行
    private func quickActionRow(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(red: 0.7, green: 0.7, blue: 0.75))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Helpers
    private var statusText: String {
        switch vpnManager.status {
        case .connected: return "VPN 隧道已连接，正在抓取流量"
        case .connecting: return "正在连接..."
        case .disconnecting: return "正在断开..."
        case .reasserting: return "正在重连..."
        case .invalid: return "未配置 VPN，点击开始"
        case .disconnected: return "已断开，点击开始抓包"
        @unknown default: return "未知状态"
        }
    }

    private var certBadgeColor: Color {
        switch certState {
        case .trusted: return .green
        case .generated: return .orange
        case .missing: return .red
        }
    }

    private var certStatusText: String {
        switch certState {
        case .trusted: return "CA 证书已安装并信任"
        case .generated: return "CA 已生成，等待系统信任"
        case .missing: return "CA 证书缺失，需要配置"
        }
    }

    private func toggleVPN() {
        if vpnManager.isConnected {
            vpnManager.stopVPN()
        } else {
            vpnManager.startVPN()
        }
    }
}


// MARK: - 自定义 Toggle 样式
private struct DarkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack {
                Capsule()
                    .fill(configuration.isOn ? Color.white : Color.white.opacity(0.25))
                    .frame(width: 48, height: 28)
                Circle()
                    .fill(configuration.isOn ? Color.green : Color.white.opacity(0.9))
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .offset(x: configuration.isOn ? 10 : -10)
            }
        }
        .buttonStyle(.plain)
    }
}
