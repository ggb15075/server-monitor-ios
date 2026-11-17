import Foundation

struct PanelConfig: Codable, Equatable {
    var name: String = "我的面板"
    var baseURL: String = ""
    var refreshInterval: Double = 5

    func validatedURL() throws -> URL {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw MonitorError.invalidURL
        }
        parts.scheme = scheme
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !parts.path.isEmpty { parts.path = "/" + parts.path }
        guard let url = parts.url else { throw MonitorError.invalidURL }
        return url
    }
}

struct ServerNode: Identifiable, Equatable {
    var id: String
    var name: String
    var region: String = ""
    var os: String = ""
    var cpuName: String = ""
    var tags: [String] = []
    var cpuCores: Int = 0
    var isOnline: Bool = false
    var lastSeen: Date?
    var cpuPercent: Double?
    var memoryPercent: Double?
    var diskPercent: Double?
    var load1: Double?
    var uploadBytesPerSecond: Double?
    var downloadBytesPerSecond: Double?
    var totalUploadBytes: Double?
    var totalDownloadBytes: Double?
    var uptimeSeconds: Double?
    var memoryTotalBytes: Double?
    var diskTotalBytes: Double?
    var tcpConnections: Int?
    var udpConnections: Int?
    var ipv4: String?
    var ipv6: String?
    var price: Double?
    var currency: String = "$"
    var billingCycleDays: Int?
    var expiresAt: Date?
    var trafficLimitBytes: Double?
    var trafficLimitType: String = "max"
    /// Agent counters, whose reset policy is configured on the server. Not necessarily monthly.
    var trafficUsedBytes: Double?
    var pings: [PingSeries] = []
}

struct PingSeries: Identifiable, Equatable {
    var id: String
    var name: String
    var kind: String = "unknown"
    var latestMilliseconds: Double?
    var lossPercent: Double?
    var samples: [PingSample] = []
}

struct PingSample: Identifiable, Equatable {
    var id: String
    var time: Date
    /// A negative value means the probe failed; zero is a valid measurement.
    var value: Double
}

struct MetricSample: Identifiable, Equatable {
    var id: String
    var time: Date
    var cpuPercent: Double?
    var memoryPercent: Double?
    var uploadBytesPerSecond: Double?
    var downloadBytesPerSecond: Double?
}

enum MonitorError: LocalizedError {
    case invalidURL
    case unauthorized
    case http(Int)
    case rpc(Int)
    case invalidResponse
    case secureStorage(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入完整的 http:// 或 https:// 面板地址，不要包含用户名、密码或查询参数。"
        case .unauthorized: return "面板拒绝访问。请检查 API Key，或在 Komari 中检查私有站点设置。"
        case .http(let code): return "面板返回 HTTP \(code)。请检查地址、反向代理和服务器状态。"
        case .rpc(let code): return "Komari 接口返回错误（\(code)）。本应用适配 Komari 1.6.1 的 RPC2 接口。"
        case .invalidResponse: return "返回内容不是兼容的 Komari 数据，请检查面板地址和版本。"
        case .secureStorage(let code): return "无法安全保存 API Key（\(code)），连接配置尚未保存。"
        }
    }
}

enum MetricMath {
    static func nonnegative(_ value: Double?) -> Double? {
        guard let value = value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func percent(used: Double?, total: Double?) -> Double? {
        guard let used = nonnegative(used), let total = nonnegative(total), total > 0 else { return nil }
        return min(100, max(0, used / total * 100))
    }

    static func traffic(up: Double?, down: Double?, type: String) -> Double? {
        guard let up = nonnegative(up), let down = nonnegative(down) else { return nil }
        switch type {
        case "sum": return up + down
        case "min": return min(up, down)
        case "up": return up
        case "down": return down
        case "max", "": return max(up, down)
        default: return nil
        }
    }
}

enum KomariDate {
    static func parse(_ text: String?) -> Date? {
        guard let text = text, !text.isEmpty, !text.hasPrefix("0001-") else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
