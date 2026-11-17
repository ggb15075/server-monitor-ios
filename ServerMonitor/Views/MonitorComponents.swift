import SwiftUI

enum MonitorStyle {
    static let mint = Color(red: 0.13, green: 0.65, blue: 0.49)
    static let violet = Color(red: 0.56, green: 0.36, blue: 0.84)
    static let blue = Color(red: 0.24, green: 0.49, blue: 0.89)
    static let orange = Color(red: 0.92, green: 0.53, blue: 0.25)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let muted = Color(uiColor: .tertiarySystemFill)
}

enum MonitorFormat {
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: value < 10 ? "%.1f%%" : "%.0f%%", value)
    }

    static func decimal(_ value: Double?, digits: Int = 2) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.*f", digits, value)
    }

    static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var scaled = value
        var index = 0
        while scaled >= 1024 && index < units.count - 1 {
            scaled /= 1024
            index += 1
        }
        return String(format: scaled >= 100 || index == 0 ? "%.0f %@" : "%.2f %@", scaled, units[index])
    }

    static func speed(_ value: Double?) -> String {
        value == nil ? "—" : "\(bytes(value))/s"
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds >= 86400 { return "\(Int(seconds / 86400))天" }
        if seconds >= 3600 { return "\(Int(seconds / 3600))小时" }
        if seconds >= 60 { return "\(Int(seconds / 60))分钟" }
        return "\(Int(seconds))秒"
    }

    static func flag(_ region: String) -> String {
        let code = region.uppercased()
        guard code.count == 2, code.unicodeScalars.allSatisfy({ (65...90).contains(Int($0.value)) }) else {
            return "🌐"
        }
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
    }

    static func price(_ node: ServerNode) -> String {
        guard let price = node.price else { return "未设置价格" }
        let cycle: String
        switch node.billingCycleDays {
        case 30, 31: cycle = "/月"
        case 365, 366: cycle = "/年"
        case .some(let days) where days > 0: cycle = "/\(days)天"
        default: cycle = ""
        }
        return "\(node.currency)\(decimal(price))\(cycle)"
    }

    static func expiry(_ date: Date?) -> String {
        guard let date else { return "未设置到期" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if date < Date() { return "已到期" }
        return days == 0 ? "今日到期" : "余 \(days) 天"
    }
}

struct Pill: View {
    let title: String
    var color: Color = .secondary

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .foregroundColor(color)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct SegmentedBar: View {
    let percent: Double?
    let color: Color
    var count = 22

    private var activeCount: Int {
        guard let percent, percent.isFinite, percent > 0 else { return 0 }
        return min(count, max(1, Int(ceil(min(100, percent) / 100 * Double(count)))))
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < activeCount ? color : MonitorStyle.muted)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

struct MetricTile: View {
    let title: String
    let symbol: String
    let value: String
    let percent: Double?
    let color: Color

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundColor(color)
                Text(title).foregroundColor(.secondary)
                Spacer(minLength: 3)
                Text(value).fontWeight(.semibold).foregroundColor(.primary)
            }
            .font(.system(size: 11))
            SegmentedBar(percent: percent, color: color)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PairStat: View {
    let firstIcon: String
    let first: String
    let secondIcon: String
    let second: String
    var color: Color = .primary

    var body: some View {
        VStack(spacing: 5) {
            stat(firstIcon, first)
            stat(secondIcon, second)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(color)
    }

    private func stat(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Spacer(minLength: 1)
            Text(value).lineLimit(1).minimumScaleFactor(0.75)
        }
    }
}

struct PingStrip: View {
    let ping: PingSeries

    private var color: Color {
        guard let latency = ping.latestMilliseconds else { return .secondary }
        return sampleColor(latency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(ping.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 4)
                Text(ping.latestMilliseconds.map { $0 < 0 ? "超时" : "\(MonitorFormat.decimal($0, digits: 0)) ms" } ?? "无数据")
                    .foregroundColor(color).fontWeight(.semibold)
                Text("·").foregroundColor(Color(uiColor: .tertiaryLabel))
                Text("\(ping.kind.lowercased() == "icmp" ? "丢包" : "失败") \(MonitorFormat.percent(ping.lossPercent))")
                    .foregroundColor((ping.lossPercent ?? 0) > 5 ? .orange : MonitorStyle.mint)
            }
            .font(.system(size: 10))
            if ping.samples.isEmpty {
                Text("暂无探测历史").font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                HStack(spacing: 2) {
                    ForEach(Array(ping.samples.suffix(36))) { sample in
                        RoundedRectangle(cornerRadius: 1.5).fill(sampleColor(sample.value))
                    }
                }
                .frame(height: 6)
                .accessibilityLabel("\(ping.name)，最近 \(min(ping.samples.count, 36)) 次真实探测记录，左旧右新")
            }
        }
    }

    private func sampleColor(_ value: Double) -> Color {
        if value < 0 { return .red }
        if value >= 250 { return MonitorStyle.orange }
        if value >= 100 { return Color(red: 0.71, green: 0.78, blue: 0.22) }
        return MonitorStyle.mint
    }
}

struct MessageBanner: View {
    let text: String
    var symbol = "exclamationmark.circle"
    var color: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).padding(.top, 1)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundColor(color)
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ServerCard: View {
    let node: ServerNode

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Text(MonitorFormat.flag(node.region)).font(.system(size: 16))
                Text(node.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                Spacer(minLength: 2)
                Circle().fill(node.isOnline ? MonitorStyle.mint : .gray).frame(width: 6, height: 6)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundColor(Color(uiColor: .tertiaryLabel))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    if !node.os.isEmpty { Pill(title: node.os, color: .secondary) }
                    if node.ipv4 != nil { Pill(title: "IPv4", color: MonitorStyle.mint) }
                    if node.ipv6 != nil { Pill(title: "IPv6", color: MonitorStyle.mint) }
                    ForEach(Array(node.tags.enumerated()), id: \.offset) { _, tag in
                        Pill(title: tag, color: MonitorStyle.violet)
                    }
                }
            }
            Divider()
            VStack(spacing: 11) {
                HStack(spacing: 15) {
                    MetricTile(title: "CPU", symbol: "cpu", value: MonitorFormat.percent(node.cpuPercent), percent: node.cpuPercent, color: MonitorStyle.blue)
                    MetricTile(title: "内存", symbol: "memorychip", value: MonitorFormat.percent(node.memoryPercent), percent: node.memoryPercent, color: MonitorStyle.violet)
                }
                HStack(spacing: 15) {
                    MetricTile(title: "磁盘", symbol: "internaldrive", value: MonitorFormat.percent(node.diskPercent), percent: node.diskPercent, color: MonitorStyle.orange)
                    MetricTile(title: "负载", symbol: "gauge", value: MonitorFormat.decimal(node.load1), percent: node.cpuCores > 0 ? node.load1.map { $0 / Double(node.cpuCores) * 100 } : nil, color: .pink)
                }
            }
            HStack(spacing: 9) {
                PairStat(firstIcon: "arrow.up", first: MonitorFormat.speed(node.uploadBytesPerSecond), secondIcon: "arrow.down", second: MonitorFormat.speed(node.downloadBytesPerSecond), color: MonitorStyle.mint)
                Divider()
                PairStat(firstIcon: "arrow.up.to.line", first: MonitorFormat.bytes(node.totalUploadBytes), secondIcon: "arrow.down.to.line", second: MonitorFormat.bytes(node.totalDownloadBytes))
                Divider()
                PairStat(firstIcon: "calendar", first: MonitorFormat.expiry(node.expiresAt), secondIcon: "creditcard", second: MonitorFormat.price(node), color: MonitorStyle.mint)
                Divider()
                PairStat(firstIcon: "network", first: "TCP \(node.tcpConnections.map(String.init) ?? "—")", secondIcon: "network", second: "UDP \(node.udpConnections.map(String.init) ?? "—")", color: MonitorStyle.mint)
            }
            .frame(height: 31)
            .padding(10)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 4) {
                Image(systemName: "clock").font(.system(size: 10))
                Text("运行 \(MonitorFormat.duration(node.uptimeSeconds))")
                Spacer()
                Text(node.isOnline ? "在线" : "离线").fontWeight(.semibold)
                    .foregroundColor(node.isOnline ? MonitorStyle.mint : .secondary)
            }
            .font(.system(size: 10)).foregroundColor(.secondary)
            if let limit = node.trafficLimitBytes, limit > 0 {
                VStack(spacing: 6) {
                    HStack {
                        Text("累计流量 / 配额")
                        Spacer()
                        Text("\(MonitorFormat.bytes(node.trafficUsedBytes)) / \(MonitorFormat.bytes(limit))")
                    }.font(.system(size: 10)).foregroundColor(.secondary)
                    SegmentedBar(percent: node.trafficUsedBytes.map { $0 / limit * 100 }, color: MonitorStyle.mint, count: 30)
                    if node.trafficUsedBytes == nil {
                        Text("探针累计用量未提供").font(.system(size: 9)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if !node.pings.isEmpty {
                Divider()
                VStack(spacing: 9) {
                    ForEach(node.pings.prefix(3)) { PingStrip(ping: $0) }
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "waveform.path")
                    Text("尚未配置网络探测")
                }.font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding(15)
        .background(MonitorStyle.card, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.primary.opacity(0.035), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 17))
    }
}
