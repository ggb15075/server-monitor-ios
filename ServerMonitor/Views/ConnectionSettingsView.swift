import SwiftUI

@MainActor
struct ConnectionSettingsView: View {
    @EnvironmentObject private var store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "我的 NAS"
    @State private var address = ""
    @State private var token = ""
    @State private var refreshInterval = 5.0
    @State private var isBusy = false
    @State private var status: String?
    @State private var hasError = false
    @State private var loaded = false
    @State private var operation: Task<Void, Never>?

    private var config: PanelConfig {
        PanelConfig(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "我的 NAS" : name.trimmingCharacters(in: .whitespacesAndNewlines), baseURL: address.trimmingCharacters(in: .whitespacesAndNewlines), refreshInterval: refreshInterval)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.system(size: 28)).foregroundColor(MonitorStyle.mint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("连接 Komari").font(.headline)
                            Text("从 NAS 读取服务器监控数据").font(.caption).foregroundColor(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
                Section {
                    TextField("面板名称", text: $name)
                    TextField("https://monitor.example.com", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Komari 面板地址")
                    SecureField("API Token（公开面板可留空）", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("面板连接")
                } footer: {
                    Text("填写 Komari 面板首页地址。局域网示例：http://192.168.1.10:25774。Token 保存在手机钥匙串中。")
                }
                Section {
                    Picker("刷新间隔", selection: $refreshInterval) {
                        Text("5 秒").tag(5.0)
                        Text("10 秒").tag(10.0)
                        Text("15 秒").tag(15.0)
                        Text("30 秒").tag(30.0)
                        Text("60 秒").tag(60.0)
                    }
                } header: {
                    Text("数据更新")
                } footer: {
                    Text("App 在前台时自动刷新。网络探测与历史记录由 NAS 后端持续采集。")
                }
                Section {
                    Button {
                        startOperation(save: false)
                    } label: {
                        HStack {
                            Text("测试连接")
                            Spacer()
                            if isBusy { ProgressView() } else { Image(systemName: "network") }
                        }
                    }.disabled(isBusy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let status {
                        Text(status).font(.footnote).foregroundColor(hasError ? .red : MonitorStyle.mint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section {
                    Button {
                        store.useDemo()
                        dismiss()
                    } label: {
                        Label("查看演示数据", systemImage: "sparkles")
                    }.disabled(isBusy)
                    if store.isDemo || !store.config.baseURL.isEmpty {
                        Button(role: .destructive) {
                            store.disconnect()
                            dismiss()
                        } label: {
                            Text("断开当前面板并清除连接信息")
                        }.disabled(isBusy)
                    }
                }
                Section {
                    LabeledContent("应用", value: "云哨")
                    LabeledContent("支持系统", value: "iOS 16 及以上")
                    Link("Komari 开源项目", destination: URL(string: "https://github.com/komari-monitor/komari")!)
                    Text("只显示后端返回的指标。缺失数据以 — 表示；网络历史色块来自真实探测记录。")
                        .font(.footnote).foregroundColor(.secondary)
                } header: {
                    Text("关于")
                }
            }
            .navigationTitle("连接设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { operation?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { startOperation(save: true) }
                        .fontWeight(.semibold)
                        .disabled(isBusy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                name = store.config.name
                address = store.config.baseURL
                refreshInterval = store.config.refreshInterval
                token = store.storedToken
            }
            .onDisappear { operation?.cancel() }
            .interactiveDismissDisabled(isBusy)
        }
    }

    private func startOperation(save: Bool) {
        isBusy = true
        status = nil
        operation = Task {
            defer { isBusy = false }
            do {
                if save {
                    try await store.configure(config, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                    guard !Task.isCancelled else { return }
                    dismiss()
                } else {
                    let count = try await store.testConnection(config, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                    guard !Task.isCancelled else { return }
                    hasError = false
                    status = "连接成功，读取到 \(count) 台服务器。"
                }
            } catch {
                guard !Task.isCancelled else { return }
                hasError = true
                status = error.localizedDescription
            }
        }
    }
}
