import SwiftUI

@MainActor
struct DashboardView: View {
    @EnvironmentObject private var store: MonitorStore
    @State private var search = ""
    @State private var showSettings = false
    @State private var onlineOnly = false

    private var filteredNodes: [ServerNode] {
        store.nodes.filter { node in
            (!onlineOnly || node.isOnline) &&
            (search.isEmpty || "\(node.name) \(node.region) \(node.tags.joined(separator: " "))".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if store.isDemo {
                        MessageBanner(text: "演示模式 · 以下为示例数据，尚未连接你的 NAS。", symbol: "sparkles", color: MonitorStyle.violet)
                    }
                    if let error = store.errorMessage {
                        MessageBanner(text: "更新失败：\(error)\(store.nodes.isEmpty ? "" : "。下方保留上次成功获取的数据。")", color: .red)
                    }
                    if let warning = store.warningMessage {
                        MessageBanner(text: warning)
                    }
                    if store.nodes.isEmpty {
                        if store.isLoading {
                            VStack(spacing: 14) {
                                ProgressView()
                                Text("正在读取 NAS 监控数据…").font(.subheadline).foregroundColor(.secondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 80)
                        } else if store.config.baseURL.isEmpty && !store.isDemo {
                            welcome
                        } else {
                            emptyState(title: "还没有监控节点", subtitle: "在 Komari 后台添加服务器，并在服务器上安装采集 Agent。随后下拉刷新。", symbol: "server.rack")
                        }
                    } else {
                        searchBar
                        if filteredNodes.isEmpty {
                            emptyState(title: "没有匹配的服务器", subtitle: "试试其他名称、地区或标签。", symbol: "magnifyingglass")
                        } else {
                            LazyVStack(spacing: 14) {
                                ForEach(filteredNodes) { node in
                                    NavigationLink {
                                        NodeDetailView(nodeID: node.id)
                                    } label: {
                                        ServerCard(node: node)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 24)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(MonitorStyle.background)
            .navigationTitle("云哨")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新监控")
                    .disabled(store.isLoading || (store.config.baseURL.isEmpty && !store.isDemo))
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }.accessibilityLabel("连接设置")
                }
            }
            .refreshable { await store.refresh() }
            .sheet(isPresented: $showSettings) { ConnectionSettingsView() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.isDemo ? "服务器监控 · 演示" : store.config.name)
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                    Text("每一台，都在眼前。")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 28, weight: .light)).foregroundColor(MonitorStyle.mint)
            }
            if !store.nodes.isEmpty {
                HStack(spacing: 0) {
                    summary("服务器", value: store.nodes.count, color: .primary)
                    Spacer()
                    summary("在线", value: store.nodes.filter(\.isOnline).count, color: MonitorStyle.mint)
                    Spacer()
                    summary("离线", value: store.nodes.filter { !$0.isOnline }.count, color: .secondary)
                }
                .padding(16)
                .background(MonitorStyle.card, in: RoundedRectangle(cornerRadius: 15))
            }
        }
    }

    private func summary(_ title: String, value: Int, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(value)").font(.system(size: 25, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(title).font(.system(size: 11)).foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("搜索名称、地区或标签", text: $search)
                .font(.system(size: 13)).autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .accessibilityLabel("清空搜索")
            }
            Button { onlineOnly.toggle() } label: {
                Image(systemName: onlineOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .foregroundColor(onlineOnly ? MonitorStyle.mint : .secondary)
            }
            .accessibilityLabel(onlineOnly ? "显示所有服务器" : "仅显示在线服务器")
        }
        .padding(12)
        .background(MonitorStyle.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "server.rack")
                .font(.system(size: 43, weight: .light)).foregroundColor(MonitorStyle.mint)
                .frame(width: 82, height: 82)
                .background(MonitorStyle.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
            VStack(alignment: .leading, spacing: 8) {
                Text("连接你的 NAS")
                    .font(.title2.bold())
                Text("将 NAS 上的 Komari 面板连到云哨，即可随时查看服务器状态、流量和网络质量。")
                    .font(.subheadline).foregroundColor(.secondary).lineSpacing(4)
            }
            VStack(alignment: .leading, spacing: 12) {
                welcomeStep("1", "在 NAS Docker 中运行 Komari")
                welcomeStep("2", "在服务器安装采集 Agent")
                welcomeStep("3", "填入面板地址，开始监控")
            }
            Button { showSettings = true } label: {
                HStack { Text("添加监控面板"); Spacer(); Image(systemName: "arrow.right") }
                    .font(.system(size: 15, weight: .semibold))
                    .padding(16).foregroundColor(.white)
                    .background(MonitorStyle.mint, in: RoundedRectangle(cornerRadius: 12))
            }
            Button { store.useDemo() } label: {
                Text("先看看演示界面").font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(23)
        .background(MonitorStyle.card, in: RoundedRectangle(cornerRadius: 21))
    }

    private func welcomeStep(_ number: String, _ title: String) -> some View {
        HStack(spacing: 9) {
            Text(number).font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 20, height: 20)
                .background(MonitorStyle.mint.opacity(0.1), in: Circle()).foregroundColor(MonitorStyle.mint)
            Text(title).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    private func emptyState(title: String, subtitle: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button("连接设置") { showSettings = true }.font(.subheadline.weight(.semibold)).padding(.top, 5)
        }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 44)
    }

    private var footer: some View {
        VStack(spacing: 5) {
            if let updated = store.lastUpdated {
                HStack(spacing: 5) {
                    if store.isLoading { ProgressView().scaleEffect(0.6) }
                    Text("最后更新 \(updated.formatted(date: .omitted, time: .standard))")
                }
            }
            Text(store.isDemo ? "演示数据仅用于界面预览" : "数据来自你的 Komari 面板")
        }
        .font(.system(size: 10)).foregroundColor(.secondary)
        .frame(maxWidth: .infinity).padding(.top, 3)
    }
}
