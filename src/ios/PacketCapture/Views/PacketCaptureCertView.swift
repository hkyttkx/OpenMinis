import SwiftUI

struct PacketCaptureCertView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var certState: CACertificateTrustState = .missing

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 状态卡片
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CA 证书状态")
                                .font(.system(size: 16, weight: .bold))
                            Text(statusText)
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Circle()
                            .fill(statusColor)
                            .frame(width: 14, height: 14)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(UIColor.secondarySystemGroupedBackground))
                    )

                    // 安装指南
                    VStack(alignment: .leading, spacing: 14) {
                        Text("安装指南")
                            .font(.system(size: 16, weight: .bold))

                        guideStep(num: "1", text: "点击下方「安装 CA 证书」按钮，系统会跳转到 Safari 下载证书描述文件")
                        guideStep(num: "2", text: "下载完成后，打开「设置」APP，顶部会出现「已下载描述文件」提示，点击进入并安装")
                        guideStep(num: "3", text: "前往 设置 → 通用 → 关于本机 → 证书信任设置，找到刚安装的 CA 证书，开启「完全信任」开关")
                        guideStep(num: "4", text: "返回本页面确认状态变为绿色，即可正常解密 HTTPS 流量")
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(UIColor.secondarySystemGroupedBackground))
                    )

                    // 安装证书按钮
                    if certState != .trusted {
                        Button(action: installCert) {
                            HStack {
                                Image(systemName: "safari")
                                Text("安装 CA 证书")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color.blue)
                            )
                        }
                    }

                    // 重新生成按钮
                    Button(action: regenerateCert) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("重新生成 CA 证书")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.orange.opacity(0.1))
                        )
                    }
                }
                .padding(20)
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("证书配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            CAManager.shared.initializeCertificateIfNeeded()
            certState = CAManager.shared.certificateTrustState()
        }
    }

    private func guideStep(num: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(num)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.blue))
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.gray)
        }
    }

    private var statusText: String {
        switch certState {
        case .trusted: return "CA 证书已安装并信任"
        case .generated: return "CA 已生成，等待安装信任"
        case .missing: return "CA 证书缺失"
        }
    }

    private var statusColor: Color {
        switch certState {
        case .trusted: return .green
        case .generated: return .orange
        case .missing: return .red
        }
    }

    private func regenerateCert() {
        CAManager.shared.initializeCertificateIfNeeded()
        certState = CAManager.shared.certificateTrustState()
    }

    private func installCert() {
        CAManager.shared.initializeCertificateIfNeeded()
        CAManager.shared.installCertificateViaSafari()
    }
}
