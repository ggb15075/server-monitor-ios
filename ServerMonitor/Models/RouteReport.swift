import Foundation

/// A saved route measurement. Carrier labels are supplied by the detector, never inferred from latency.
struct RouteReport: Equatable {
    var checkedAt: Date
    var direction: String
    var ipVersion: String
    var paths: [RoutePath]

    func isStale(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(checkedAt) > 48 * 60 * 60
    }

    var directionLabel: String {
        switch direction.lowercased() {
        case "outbound": return "VPS → 探测目标"
        case "inbound": return "探测目标 → VPS"
        default: return direction.isEmpty ? "方向未提供" : direction
        }
    }

    var ipVersionLabel: String {
        switch ipVersion.lowercased() {
        case "4", "ipv4": return "IPv4"
        case "6", "ipv6": return "IPv6"
        default: return "IP 协议未提供"
        }
    }
}

enum RouteReportParser {
    static let openingMarker = "[yunshao-route-v1]"
    static let closingMarker = "[/yunshao-route-v1]"

    /// Only read the detector's versioned block; ordinary remarks and tags are never route evidence.
    static func parse(_ remark: String?) -> RouteReport? {
        guard let remark, remark.utf8.count <= 65_536,
              let opening = remark.range(of: openingMarker),
              let closing = remark.range(of: closingMarker, range: opening.upperBound..<remark.endIndex) else { return nil }
        let payload = String(remark[opening.upperBound..<closing.lowerBound])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let wire = try? decoder.decode(StoredReport.self, from: Data(payload.utf8)),
              wire.schema == 1, let checkedAt = KomariDate.parse(wire.checkedAt) else { return nil }
        var seen = Set<String>()
        let paths = wire.paths.prefix(3).compactMap { path -> RoutePath? in
            let carrier = path.carrier.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = path.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !carrier.isEmpty, carrier.count <= 32, !target.isEmpty, target.count <= 128,
                  seen.insert(carrier + "-" + target).inserted else { return nil }
            return RoutePath(carrier: carrier, label: String(path.label.prefix(64)),
                             evidence: Array(path.evidence.prefix(32)).map { String($0.prefix(80)) },
                             target: target, reachedTarget: path.reachedTarget)
        }
        guard !paths.isEmpty else { return nil }
        return RouteReport(checkedAt: checkedAt, direction: String(wire.direction.prefix(80)),
                           ipVersion: wire.ipVersion, paths: paths)
    }

    private struct StoredReport: Decodable {
        var schema: Int
        var checkedAt: String
        var direction: String
        var ipVersion: String
        var paths: [StoredPath]
    }

    private struct StoredPath: Decodable {
        var carrier: String
        var label: String
        var evidence: [String]
        var target: String
        var reachedTarget: Bool
    }
}

struct RoutePath: Identifiable, Equatable {
    var id: String { carrier + "-" + target }
    var carrier: String
    var label: String
    var evidence: [String]
    var target: String
    var reachedTarget: Bool

    var displayLabel: String {
        let result = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "无法判断" : result
    }

    var badge: String {
        displayLabel.hasPrefix(carrier) ? displayLabel : "\(carrier) · \(displayLabel)"
    }
}
