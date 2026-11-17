import XCTest
@testable import ServerMonitor

final class KomariParsingTests: XCTestCase {
    func testMappingUsesRealOnlineStatusCorrectDirectionsAndTCPCount() throws {
        let metadata: [String: KomariNodeDTO] = try decode(#"{"jsonrpc":"2.0","id":"1","result":{"node-1":{"uuid":"node-1","name":"Test","cpu_cores":2,"mem_total":1000,"disk_total":2000,"tags":"CN2;IPv6","traffic_limit":100000,"traffic_limit_type":"sum","expired_at":"2027-01-01T00:00:00.123456789Z"}}}"#)
        let statuses: [String: KomariStatusDTO] = try decode(#"{"result":{"node-1":{"time":"2026-11-17T01:00:00Z","cpu":0.7,"ram":110,"ram_total":1000,"disk":380,"disk_total":2000,"load":0,"net_in":651,"net_out":86,"net_total_up":547,"net_total_down":2250,"connections":42,"connections_udp":5,"online":true,"uptime":14400}}}"#)
        let node = try XCTUnwrap(KomariMapper.nodes(metadata, statuses: statuses).first)
        XCTAssertTrue(node.isOnline)
        XCTAssertEqual(node.memoryPercent, 11)
        XCTAssertEqual(node.diskPercent, 19)
        XCTAssertEqual(node.uploadBytesPerSecond, 86)
        XCTAssertEqual(node.downloadBytesPerSecond, 651)
        XCTAssertEqual(node.tcpConnections, 37)
        XCTAssertEqual(node.udpConnections, 5)
        XCTAssertEqual(node.trafficUsedBytes, 2797)
        XCTAssertEqual(node.tags, ["CN2", "IPv6"])
        XCTAssertNotNil(node.expiresAt)
    }

    func testMissingReportIsOfflineAndDoesNotInventZeroMetrics() throws {
        let metadata: [String: KomariNodeDTO] = try decode(#"{"result":{"n":{"name":"Offline","mem_total":0}}}"#)
        let node = try XCTUnwrap(KomariMapper.nodes(metadata, statuses: [:]).first)
        XCTAssertFalse(node.isOnline)
        XCTAssertNil(node.cpuPercent)
        XCTAssertNil(node.memoryPercent)
        XCTAssertNil(node.totalUploadBytes)
        XCTAssertNil(node.trafficUsedBytes)
        XCTAssertTrue(node.pings.isEmpty)
    }

    func testLatestFailedPingIsNotReplacedByOlderSuccessfulSummary() throws {
        let meta: [String: KomariNodeDTO] = try decode(#"{"result":{"n":{"name":"Node"}}}"#)
        let statuses: [String: KomariStatusDTO] = try decode(#"{"result":{"n":{"online":true,"ping":{"1":{"name":"电信","latest":20,"loss":50}}}}}"#)
        let pings: KomariPingRecordsDTO = try decode(#"{"result":{"tasks":[{"id":1,"name":"电信","type":"icmp"}],"records":[{"client":"n","task_id":1,"time":"2026-11-17T01:00:01Z","value":-1},{"client":"n","task_id":1,"time":"2026-11-17T01:00:00Z","value":20}]}}"#)
        let node = try XCTUnwrap(KomariMapper.nodes(meta, statuses: statuses, pings: PingOverview(pings)).first)
        XCTAssertEqual(node.pings.first?.latestMilliseconds, -1)
        XCTAssertEqual(node.pings.first?.lossPercent, 50)
        XCTAssertEqual(node.pings.first?.kind, "icmp")
        XCTAssertEqual(node.pings.first?.samples.count, 2)
    }

    func testTrafficModesAndUnknownMode() {
        XCTAssertEqual(MetricMath.traffic(up: 12, down: 30, type: "max"), 30)
        XCTAssertEqual(MetricMath.traffic(up: 12, down: 30, type: "min"), 12)
        XCTAssertEqual(MetricMath.traffic(up: 12, down: 30, type: "sum"), 42)
        XCTAssertEqual(MetricMath.traffic(up: 12, down: 30, type: "up"), 12)
        XCTAssertEqual(MetricMath.traffic(up: 12, down: 30, type: "down"), 30)
        XCTAssertNil(MetricMath.traffic(up: 12, down: 30, type: "unknown"))
        XCTAssertNil(MetricMath.percent(used: 5, total: 0))
    }

    func testInvalidRPCAndHTMLAreNotEmptySuccessfulPanels() {
        XCTAssertThrowsError(try KomariClient.decode([String: KomariNodeDTO].self, data: Data(#"{"jsonrpc":"2.0","error":{"code":-32601,"message":"missing"}}"#.utf8)))
        XCTAssertThrowsError(try KomariClient.decode([String: KomariNodeDTO].self, data: Data("<html>login</html>".utf8)))
        XCTAssertThrowsError(try KomariClient.decode([String: KomariNodeDTO].self, data: Data(#"{"status":"success"}"#.utf8)))
    }

    func testUnauthorizedRPCUsesKomari161ErrorCodes() {
        for code in [-32040, -32041] {
            let data = Data("{\"error\":{\"code\":\(code)}}".utf8)
            XCTAssertThrowsError(try KomariClient.decode([String: KomariNodeDTO].self, data: data)) { error in
                guard case MonitorError.unauthorized = error else { return XCTFail("Wrong error: \(error)") }
            }
        }
    }

    func testAssignedProbeWithoutSamplesStaysUnknown() throws {
        let metadata: [String: KomariNodeDTO] = try decode(#"{"result":{"n":{"name":"New node"}}}"#)
        let response: KomariPingRecordsDTO = try decode(#"{"result":{"tasks":[{"id":1,"name":"电信","type":"tcp","clients":["n"]}],"records":[]}}"#)
        let node = try XCTUnwrap(KomariMapper.nodes(metadata, statuses: [:], pings: PingOverview(response)).first)
        XCTAssertEqual(node.pings.count, 1)
        XCTAssertEqual(node.pings.first?.kind, "tcp")
        XCTAssertNil(node.pings.first?.latestMilliseconds)
        XCTAssertNil(node.pings.first?.lossPercent)
    }

    func testPanelURLRejectsEmbeddedSecretsAndPreservesBasePath() throws {
        XCTAssertThrowsError(try PanelConfig(baseURL: "https://name:password@example.com").validatedURL())
        XCTAssertThrowsError(try PanelConfig(baseURL: "https://example.com?token=secret").validatedURL())
        XCTAssertThrowsError(try PanelConfig(baseURL: "file:///etc/passwd").validatedURL())
        XCTAssertEqual(try PanelConfig(baseURL: " https://example.com/monitor/ ").validatedURL().absoluteString, "https://example.com/monitor")
    }

    func testHistoricalMetricsUseTimestampAndDoNotTreatBytesAsPercent() throws {
        let response: KomariHistoryDTO = try decode(#"{"result":{"records":{"n":[{"time":"2026-11-17T01:00:00.125Z","cpu":42,"ram":512,"ram_total":1024,"net_in":500,"net_out":200}]}}}"#)
        let rows = KomariMapper.history(response, nodeID: "n")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.memoryPercent, 50)
        XCTAssertEqual(rows.first?.uploadBytesPerSecond, 200)
    }

    func testRouteReportReadsOnlyVersionedBlockAndPreservesMeasurementMeaning() throws {
        let remark = "自己的公开备注\n" + routeBlock + "\n其他说明"
        let report = try XCTUnwrap(RouteReportParser.parse(remark))
        XCTAssertEqual(report.directionLabel, "VPS → 中国大陆（回程）")
        XCTAssertEqual(report.ipVersionLabel, "IPv4")
        XCTAssertEqual(report.paths.count, 2)
        XCTAssertEqual(report.paths[0].badge, "电信163")
        XCTAssertEqual(report.paths[0].evidence, ["AS4134"])
        XCTAssertTrue(report.paths[0].reachedTarget)
        XCTAssertEqual(report.paths[1].displayLabel, "无法判断")
        XCTAssertFalse(report.paths[1].reachedTarget)
    }

    func testRouteReportDoesNotInferRoutingFromOrdinaryRemarkOrTags() throws {
        let metadata: [String: KomariNodeDTO] = try decode(#"{"result":{"n":{"name":"Node","tags":"CN2 GIA;9929","public_remark":"商家说是CN2 GIA"}}}"#)
        let node = try XCTUnwrap(KomariMapper.nodes(metadata, statuses: [:]).first)
        XCTAssertNil(node.routeReport)
        XCTAssertEqual(node.tags, ["CN2 GIA", "9929"])
    }

    func testInvalidRouteReportDoesNotBreakNodeMetrics() throws {
        for invalid in [routeBlock.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":2"),
                        routeBlock.replacingOccurrences(of: "2026-11-17T01:00:00Z", with: "invalid"),
                        "[yunshao-route-v1]{invalid}[/yunshao-route-v1]",
                        routeBlock.replacingOccurrences(of: "[/yunshao-route-v1]", with: "")] {
            XCTAssertNil(RouteReportParser.parse(invalid))
        }
        let metadata: [String: KomariNodeDTO] = try decode(#"{"result":{"n":{"name":"Node","public_remark":"[yunshao-route-v1]{invalid}[/yunshao-route-v1]"}}}"#)
        let statuses: [String: KomariStatusDTO] = try decode(#"{"result":{"n":{"online":true,"cpu":7}}}"#)
        let node = try XCTUnwrap(KomariMapper.nodes(metadata, statuses: statuses).first)
        XCTAssertNil(node.routeReport)
        XCTAssertEqual(node.cpuPercent, 7)
        XCTAssertTrue(node.isOnline)
    }

    func testRouteReportFlowsFromKomariPublicRemarkIntoNode() throws {
        let metadataData = try JSONSerialization.data(withJSONObject: ["result": ["n": ["name": "Node", "public_remark": routeBlock]]])
        let metadata = try KomariClient.decode([String: KomariNodeDTO].self, data: metadataData)
        let node = try XCTUnwrap(KomariMapper.nodes(metadata, statuses: [:]).first)
        XCTAssertEqual(node.routeReport?.paths.first?.label, "电信163")
        XCTAssertNotNil(node.routeReport?.checkedAt)
    }

    func testRouteReportBecomesStaleAfter48HoursWithoutChangingItsEvidence() throws {
        let report = try XCTUnwrap(RouteReportParser.parse(routeBlock))
        XCTAssertFalse(report.isStale(at: report.checkedAt.addingTimeInterval(48 * 60 * 60)))
        XCTAssertTrue(report.isStale(at: report.checkedAt.addingTimeInterval(48 * 60 * 60 + 1)))
        XCTAssertEqual(report.paths.first?.evidence, ["AS4134"])
    }

    private var routeBlock: String {
        #"[yunshao-route-v1]{"schema":1,"checked_at":"2026-11-17T01:00:00Z","direction":"VPS → 中国大陆（回程）","ip_version":"IPv4","paths":[{"carrier":"电信","label":"电信163","evidence":["AS4134"],"target":"192.0.2.1","reached_target":true},{"carrier":"联通","label":"","evidence":[],"target":"192.0.2.2","reached_target":false}]}[/yunshao-route-v1]"#
    }

    private func decode<T: Decodable>(_ text: String) throws -> T {
        try KomariClient.decode(T.self, data: Data(text.utf8))
    }
}
