import Foundation

/// Used only after the user explicitly selects 演示模式. Never used as a network fallback.
enum DemoData {
    static var nodes: [ServerNode] {
        let now = Date()
        return [
            ServerNode(id: "demo-los-angeles", name: "HHost.LA.China-Optimized", region: "US", os: "Debian 12",
                       cpuName: "AMD EPYC", tags: ["200 Mbps", "演示节点"], cpuCores: 2,
                       isOnline: true, lastSeen: now, cpuPercent: 0.7, memoryPercent: 11, diskPercent: 19, load1: 0,
                       uploadBytesPerSecond: 86, downloadBytesPerSecond: 651, totalUploadBytes: 547_000_000,
                       totalDownloadBytes: 2_250_000_000, uptimeSeconds: 14_400, memoryTotalBytes: 2_147_483_648,
                       diskTotalBytes: 42_949_672_960, tcpConnections: 37, udpConnections: 0,
                       ipv4: "192.0.2.1", ipv6: "2001:db8::1", price: 39, currency: "$", billingCycleDays: 365,
                       expiresAt: now.addingTimeInterval(352 * 86400), trafficLimitBytes: 400_000_000_000,
                       trafficLimitType: "sum", trafficUsedBytes: 2_797_000_000,
                       pings: [ping(id: "ct", name: "电信", base: 159, loss: 0), ping(id: "cu", name: "联通", base: 140, loss: 1.7), ping(id: "cm", name: "移动", base: 137, loss: 0)],
                       routeReport: RouteReport(checkedAt: now, direction: "VPS → 中国大陆（回程）· 示例", ipVersion: "IPv4", paths: [
                           RoutePath(carrier: "电信", label: "电信 CN2", evidence: ["AS4809"], target: "192.0.2.10", reachedTarget: true),
                           RoutePath(carrier: "联通", label: "联通 9929", evidence: ["AS9929"], target: "198.51.100.10", reachedTarget: true),
                           RoutePath(carrier: "移动", label: "移动 CMI", evidence: ["AS58453"], target: "203.0.113.10", reachedTarget: true)
                       ])),
            ServerNode(id: "demo-tokyo", name: "Tokyo · Edge 01", region: "JP", os: "Ubuntu 24.04", cpuName: "AMD EPYC",
                       tags: ["东京", "1 Gbps"], cpuCores: 4, isOnline: true, lastSeen: now,
                       cpuPercent: 18.4, memoryPercent: 42, diskPercent: 28, load1: 0.31,
                       uploadBytesPerSecond: 1_460_000, downloadBytesPerSecond: 580_000,
                       totalUploadBytes: 35_000_000_000, totalDownloadBytes: 87_000_000_000, uptimeSeconds: 10 * 86400,
                       memoryTotalBytes: 4_294_967_296, diskTotalBytes: 85_899_345_920, tcpConnections: 82, udpConnections: 7,
                       ipv4: "192.0.2.2", price: 5, currency: "$", billingCycleDays: 30,
                       expiresAt: now.addingTimeInterval(18 * 86400), trafficLimitBytes: 1_000_000_000_000,
                       trafficLimitType: "max", trafficUsedBytes: 87_000_000_000,
                       pings: [ping(id: "ct", name: "电信", base: 61, loss: 0), ping(id: "cu", name: "联通", base: 48, loss: 0), ping(id: "cm", name: "移动", base: 52, loss: 0)]),
            ServerNode(id: "demo-singapore", name: "Singapore · Backup", region: "SG", os: "Debian 12",
                       tags: ["备份节点"], cpuCores: 1, isOnline: false, lastSeen: now.addingTimeInterval(-1860),
                       memoryTotalBytes: 1_073_741_824, diskTotalBytes: 21_474_836_480)
        ]
    }

    static func history(nodeID: String) -> [MetricSample] {
        let now = Date()
        return (0..<60).map { index in
            MetricSample(id: "\(nodeID)-\(index)", time: now.addingTimeInterval(Double(index - 59) * 60),
                         cpuPercent: 12 + sin(Double(index) * 0.45) * 7,
                         memoryPercent: 30 + sin(Double(index) * 0.1) * 3,
                         uploadBytesPerSecond: 500_000 + sin(Double(index) * 0.28) * 350_000,
                         downloadBytesPerSecond: 250_000 + cos(Double(index) * 0.18) * 150_000)
        }
    }

    private static func ping(id: String, name: String, base: Double, loss: Double) -> PingSeries {
        let now = Date()
        let samples = (0..<36).map { index in
            PingSample(id: "\(id)-\(index)", time: now.addingTimeInterval(Double(index - 35) * 60),
                       value: loss > 0 && index == 24 ? -1 : base + sin(Double(index) * 0.6) * 8)
        }
        return PingSeries(id: id, name: name, kind: "icmp", latestMilliseconds: samples.last?.value,
                          lossPercent: loss, samples: samples)
    }
}
