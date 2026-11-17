import Foundation

// Wire fields checked against komari-monitor/komari tag 1.6.1.
// Never decode or persist the node's agent token, even if an administrator response includes it.
struct KomariNodeDTO: Decodable {
    var uuid: String?
    var name: String?
    var region: String?
    var os: String?
    var cpuName: String?
    var cpuCores: Int?
    var memTotal: Double?
    var diskTotal: Double?
    var ipv4: String?
    var ipv6: String?
    var tags: String?
    var publicRemark: String?
    var group: String?
    var weight: Int?
    var price: Double?
    var currency: String?
    var billingCycle: Int?
    var expiredAt: String?
    var trafficLimit: Double?
    var trafficLimitType: String?
}

struct KomariStatusDTO: Decodable {
    var client: String?
    var time: String?
    var cpu: Double?
    var ram: Double?
    var ramTotal: Double?
    var disk: Double?
    var diskTotal: Double?
    var load: Double?
    var netIn: Double?
    var netOut: Double?
    var netTotalUp: Double?
    var netTotalDown: Double?
    /// Komari's `connections` is TCP + UDP, not TCP alone.
    var connections: Int?
    var connectionsUdp: Int?
    var online: Bool?
    var uptime: Double?
    var ping: [String: KomariPingSummaryDTO]?
}

struct KomariPingSummaryDTO: Decodable {
    var name: String?
    var latest: Double?
    var loss: Double?
}

struct KomariPingRecordsDTO: Decodable {
    var records: [KomariPingRecordDTO]?
    var tasks: [KomariPingTaskDTO]?
}

struct KomariPingRecordDTO: Decodable {
    var taskId: Int?
    var time: String?
    var value: Double?
    var client: String?
}

struct KomariPingTaskDTO: Decodable {
    var id: Int?
    var name: String?
    var type: String?
    var clients: [String]?
}

struct KomariHistoryDTO: Decodable {
    var records: [String: [KomariStatusDTO]]?
}

struct RPCEnvelope<T: Decodable>: Decodable {
    var result: T?
    var error: RPCFailure?
}

struct RPCFailure: Decodable {
    var code: Int
    // Do not surface arbitrary server error messages: they may include request credentials.
}

struct PingOverview {
    var tasks: [String: KomariPingTaskDTO] = [:]
    var records: [String: [String: [PingSample]]] = [:]

    init() {}

    init(_ dto: KomariPingRecordsDTO) {
        for task in dto.tasks ?? [] {
            if let id = task.id { tasks[String(id)] = task }
        }
        for row in dto.records ?? [] {
            guard let client = row.client, let task = row.taskId,
                  let time = KomariDate.parse(row.time), let value = row.value, value.isFinite else { continue }
            let key = String(task)
            records[client, default: [:]][key, default: []].append(
                PingSample(id: "\(client)-\(task)-\(time.timeIntervalSince1970)", time: time, value: value)
            )
        }
        for client in Array(records.keys) {
            for task in Array(records[client, default: [:]].keys) {
                records[client]?[task]?.sort { $0.time < $1.time }
            }
        }
    }
}

enum KomariMapper {
    static func nodes(_ metadata: [String: KomariNodeDTO], statuses: [String: KomariStatusDTO], pings: PingOverview = PingOverview()) -> [ServerNode] {
        metadata.sorted {
            if $0.value.weight != $1.value.weight { return ($0.value.weight ?? 0) > ($1.value.weight ?? 0) }
            return ($0.value.name ?? $0.key).localizedStandardCompare($1.value.name ?? $1.key) == .orderedAscending
        }.map { key, meta in
            let status = statuses[key]
            let memoryTotal = MetricMath.nonnegative(status?.ramTotal ?? meta.memTotal)
            let diskTotal = MetricMath.nonnegative(status?.diskTotal ?? meta.diskTotal)
            let up = MetricMath.nonnegative(status?.netTotalUp)
            let down = MetricMath.nonnegative(status?.netTotalDown)
            let trafficType = meta.trafficLimitType ?? "max"
            var tags = (meta.tags ?? "").split(separator: ";").map(String.init)
            if let group = meta.group, !group.isEmpty, !tags.contains(group) { tags.insert(group, at: 0) }
            let assignedTasks = pings.tasks.filter { $0.value.clients?.contains(key) == true }.keys
            let pingIDs = Set((status?.ping ?? [:]).keys)
                .union(pings.records[key, default: [:]].keys).union(assignedTasks)
            let series: [PingSeries] = pingIDs.sorted().map { id in
                let summary = status?.ping?[id]
                let task = pings.tasks[id]
                let samples = pings.records[key]?[id] ?? []
                // The status API's `latest` means last successful ping in 1.6.1.
                // Prefer the most recent actual sample so a failed latest probe stays failed.
                return PingSeries(id: id, name: task?.name ?? summary?.name ?? "探测 \(id)",
                                  kind: task?.type ?? "unknown",
                                  latestMilliseconds: samples.last?.value,
                                  lossPercent: summary?.loss.map { min(100, max(0, $0)) }, samples: samples)
            }
            let tcp: Int?
            if let total = status?.connections, let udp = status?.connectionsUdp { tcp = max(0, total - udp) }
            else { tcp = nil }
            return ServerNode(id: key, name: meta.name ?? key, region: meta.region ?? "", os: meta.os ?? "",
                cpuName: meta.cpuName ?? "", tags: tags, cpuCores: meta.cpuCores ?? 0,
                isOnline: status?.online == true, lastSeen: KomariDate.parse(status?.time),
                cpuPercent: MetricMath.nonnegative(status?.cpu).map { min(100, $0) },
                memoryPercent: MetricMath.percent(used: status?.ram, total: memoryTotal),
                diskPercent: MetricMath.percent(used: status?.disk, total: diskTotal),
                load1: MetricMath.nonnegative(status?.load),
                uploadBytesPerSecond: MetricMath.nonnegative(status?.netOut),
                downloadBytesPerSecond: MetricMath.nonnegative(status?.netIn),
                totalUploadBytes: up, totalDownloadBytes: down, uptimeSeconds: MetricMath.nonnegative(status?.uptime),
                memoryTotalBytes: memoryTotal, diskTotalBytes: diskTotal, tcpConnections: tcp,
                udpConnections: status?.connectionsUdp, ipv4: nonempty(meta.ipv4), ipv6: nonempty(meta.ipv6),
                price: MetricMath.nonnegative(meta.price), currency: meta.currency ?? "$",
                billingCycleDays: meta.billingCycle, expiresAt: KomariDate.parse(meta.expiredAt),
                trafficLimitBytes: MetricMath.nonnegative(meta.trafficLimit).flatMap { $0 > 0 ? $0 : nil },
                trafficLimitType: trafficType, trafficUsedBytes: MetricMath.traffic(up: up, down: down, type: trafficType),
                pings: series, routeReport: RouteReportParser.parse(meta.publicRemark))
        }
    }

    static func history(_ dto: KomariHistoryDTO, nodeID: String) -> [MetricSample] {
        (dto.records?[nodeID] ?? []).compactMap { row in
            guard let time = KomariDate.parse(row.time) else { return nil }
            return MetricSample(id: "\(nodeID)-\(time.timeIntervalSince1970)", time: time,
                                cpuPercent: MetricMath.nonnegative(row.cpu),
                                memoryPercent: MetricMath.percent(used: row.ram, total: row.ramTotal),
                                uploadBytesPerSecond: MetricMath.nonnegative(row.netOut),
                                downloadBytesPerSecond: MetricMath.nonnegative(row.netIn))
        }.sorted { $0.time < $1.time }
    }

    private static func nonempty(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : $0 } }
}
