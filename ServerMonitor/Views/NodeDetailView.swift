import SwiftUI
import Charts

@MainActor
struct NodeDetailView: View {
    @EnvironmentObject private var store: MonitorStore
    let nodeID: String
    @State private var history: [MetricSample] = []
    @State private var isLoadingHistory = false
    @State private var historyError: String?

    private var node: ServerNode? { store.nodes.first { $0.id == nodeID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let node {
                    if store.isDemo {
                        MessageBanner(text: "演示模式 · 本页为示例数据。", symbol: "sparkles", color: MonitorStyle.violet)
                    }
                    if let error = store.errorMessage {
                        MessageBanner(text: "\(error) 当前显示上次成功获取的数据。", color: .red)
                    }
                    ServerCard(node: node)
                    historySection
                    if !node.pings.isEmpty { networkSection(node) }
                    informationSection(node)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "server.rack").font(.largeTitle).foregroundColor(.secondary)
                        Text("此节点已不在当前面板中")
                    }.frame(maxWidth: .infinity).padding(.vertical, 80)
                }
            }
            .padding(16)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(MonitorStyle.background)
        .navigationTitle(node?.name ?? "服务器详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: nodeID) { await loadHistory() }
        .refreshable {
            await store.refresh()
            await loadHistory()
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("资源历史", systemImage: "chart.xyaxis.line")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if isLoadingHistory { ProgressView().scaleEffect(0.8) }
            }
            if let historyError {
                Text(historyError).font(.footnote).foregroundColor(.secondary)
                Button("重新读取历史") { Task { await loadHistory() } }.font(.footnote.weight(.semibold))
            } else if history.isEmpty && !isLoadingHistory {
                Text("暂无历史记录。探针运行一段时间后，后端会开始积累数据。")
                    .font(.footnote).foregroundColor(.secondary)
            } else if !history.isEmpty {
                if history.contains(where: { $0.cpuPercent != nil || $0.memoryPercent != nil }) {
                    Chart {
                        ForEach(history) { sample in
                            if let cpu = sample.cpuPercent {
                                LineMark(x: .value("时间", sample.time), y: .value("使用率", cpu))
                                    .foregroundStyle(by: .value("指标", "CPU"))
                                    .interpolationMethod(.linear)
                            }
                            if let memory = sample.memoryPercent {
                                LineMark(x: .value("时间", sample.time), y: .value("使用率", memory))
                                    .foregroundStyle(by: .value("指标", "内存"))
                                    .interpolationMethod(.linear)
                            }
                        }
                    }
                    .chartForegroundStyleScale(["CPU": MonitorStyle.blue, "内存": MonitorStyle.violet])
                    .chartYScale(domain: 0...100)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                            AxisGridLine()
                            AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.system(size: 9)) }
                        }
                    }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                    .frame(height: 165)
                }
                if history.contains(where: { $0.uploadBytesPerSecond != nil || $0.downloadBytesPerSecond != nil }) {
                    Text("网络速率").font(.system(size: 12, weight: .medium)).padding(.top, 4)
                    Chart {
                        ForEach(history) { sample in
                            if let upload = sample.uploadBytesPerSecond {
                                LineMark(x: .value("时间", sample.time), y: .value("字节每秒", upload))
                                    .foregroundStyle(by: .value("方向", "上传"))
                                    .interpolationMethod(.linear)
                            }
                            if let download = sample.downloadBytesPerSecond {
                                LineMark(x: .value("时间", sample.time), y: .value("字节每秒", download))
                                    .foregroundStyle(by: .value("方向", "下载"))
                                    .interpolationMethod(.linear)
                            }
                        }
                    }
                    .chartForegroundStyleScale(["上传": MonitorStyle.mint, "下载": MonitorStyle.blue])
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                Text(MonitorFormat.speed(value.as(Double.self))).font(.system(size: 8))
                            }
                        }
                    }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                    .frame(height: 145)
                }
                if let first = history.first, let last = history.last {
                    Text("\(first.time.formatted(date: .omitted, time: .shortened)) – \(last.time.formatted(date: .omitted, time: .shortened)) · \(history.count) 条记录")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
        .padding(17)
        .background(MonitorStyle.card, in: RoundedRectangle(cornerRadius: 17))
    }

    private func networkSection(_ node: ServerNode) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("网络探测", systemImage: "waveform.path")
                .font(.system(size: 14, weight: .semibold))
            ForEach(node.pings) { ping in
                VStack(alignment: .leading, spacing: 8) {
                    PingStrip(ping: ping)
                    HStack {
                        Text(ping.kind.isEmpty ? "探测类型未提供" : ping.kind.uppercased())
                        Spacer()
                        Text("\(ping.samples.count) 次记录")
                    }.font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            Text("由服务器探针发起。色块从左到右为旧到新，红色代表探测失败。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(17)
        .background(MonitorStyle.card, in: RoundedRectangle(cornerRadius: 17))
    }

    private func informationSection(_ node: ServerNode) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("服务器信息", systemImage: "info.circle")
                .font(.system(size: 14, weight: .semibold))
            informationRow("地区", node.region.isEmpty ? "—" : node.region)
            informationRow("系统", node.os.isEmpty ? "—" : node.os)
            informationRow("处理器", node.cpuName.isEmpty ? "—" : node.cpuName)
            informationRow("核心数", node.cpuCores > 0 ? "\(node.cpuCores)" : "—")
            informationRow("总内存", MonitorFormat.bytes(node.memoryTotalBytes))
            informationRow("总磁盘", MonitorFormat.bytes(node.diskTotalBytes))
            if let ipv4 = node.ipv4, !ipv4.isEmpty { informationRow("IPv4", ipv4) }
            if let ipv6 = node.ipv6, !ipv6.isEmpty { informationRow("IPv6", ipv6) }
            if let expires = node.expiresAt {
                informationRow("到期日期", expires.formatted(date: .abbreviated, time: .omitted))
            }
            if let lastSeen = node.lastSeen {
                informationRow("最后上报", lastSeen.formatted(date: .abbreviated, time: .standard))
            }
            informationRow("节点 ID", node.id)
            if node.trafficLimitBytes != nil {
                Text("累计流量采用探针上报的计数，统计口径：\(node.trafficLimitType)。计数可能随服务器或探针重启而改变，不代表固定自然月账单。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding(17)
        .background(MonitorStyle.card, in: RoundedRectangle(cornerRadius: 17))
    }

    private func informationRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title).foregroundColor(.secondary).frame(width: 60, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled)
        }.font(.system(size: 11))
    }

    private func loadHistory() async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        historyError = nil
        defer { isLoadingHistory = false }
        do {
            let samples = try await store.fetchHistory(nodeID: nodeID)
            guard !Task.isCancelled else { return }
            history = samples.sorted { $0.time < $1.time }
        } catch {
            guard !Task.isCancelled else { return }
            historyError = "读取历史失败：\(error.localizedDescription)"
        }
    }
}
