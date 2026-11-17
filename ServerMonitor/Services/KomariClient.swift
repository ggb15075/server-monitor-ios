import Foundation

struct MonitorSnapshot {
    var nodes: [ServerNode]
    var pingWarning: String?
}

/// Do not forward a panel key to another origin, including HTTP redirects.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor KomariClient {
    private let url: URL
    private let token: String
    private let session: URLSession
    private var pingCache = PingOverview()
    private var pingUpdatedAt: Date?

    init(config: PanelConfig, token: String) throws {
        self.url = try config.validatedURL().appendingPathComponent("api/rpc2")
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func cancel() { session.invalidateAndCancel() }

    func snapshot() async throws -> MonitorSnapshot {
        async let metadata: [String: KomariNodeDTO] = call("common:getNodes")
        async let statuses: [String: KomariStatusDTO] = call("common:getNodesLatestStatus")
        let (meta, live) = try await (metadata, statuses)
        try Task.checkCancellation()
        var warning: String?
        if pingUpdatedAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
            do {
                async let pingRecords: KomariPingRecordsDTO = call("common:getRecords", params: [
                    "type": "ping", "hours": 1, "maxCount": 6000
                ])
                async let pingTasks: [KomariPingTaskDTO] = call("public:getPublicPingTasks")
                let (records, tasks) = try await (pingRecords, pingTasks)
                var nextCache = PingOverview(records)
                for task in tasks {
                    if let id = task.id { nextCache.tasks[String(id)] = task }
                }
                pingCache = nextCache
                pingUpdatedAt = Date()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                warning = "实时指标已更新；网络探测历史暂时无法读取，稍后自动重试。"
                // Failed history refresh must not display an earlier window as current.
                pingCache = PingOverview()
                pingUpdatedAt = nil
            }
        }
        return MonitorSnapshot(nodes: KomariMapper.nodes(meta, statuses: live, pings: pingCache), pingWarning: warning)
    }

    func history(nodeID: String) async throws -> [MetricSample] {
        let dto: KomariHistoryDTO = try await call("common:getRecords", params: [
            "type": "load", "uuid": nodeID, "hours": 1, "maxCount": 180
        ])
        return KomariMapper.history(dto, nodeID: nodeID)
    }

    private func call<T: Decodable>(_ method: String, params: [String: Any] = [:]) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params
        ])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw MonitorError.invalidResponse }
        if [401, 403].contains(response.statusCode) { throw MonitorError.unauthorized }
        guard (200...299).contains(response.statusCode) else { throw MonitorError.http(response.statusCode) }
        return try Self.decode(T.self, data: data)
    }

    nonisolated static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope: RPCEnvelope<T>
        do { envelope = try decoder.decode(RPCEnvelope<T>.self, from: data) }
        catch { throw MonitorError.invalidResponse }
        if let error = envelope.error {
            if [-32040, -32041].contains(error.code) { throw MonitorError.unauthorized }
            throw MonitorError.rpc(error.code)
        }
        guard let value = envelope.result else { throw MonitorError.invalidResponse }
        return value
    }
}
