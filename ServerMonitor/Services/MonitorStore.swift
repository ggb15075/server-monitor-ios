import Foundation
import Combine

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var config = PanelConfig()
    @Published private(set) var nodes: [ServerNode] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var warningMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isDemo = false

    private let defaults: UserDefaults
    private let configKey = "monitor.panel.v1"
    private var client: KomariClient?
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<MonitorSnapshot, Error>?
    private var generation = UUID()
    private var active = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: configKey),
           let saved = try? JSONDecoder().decode(PanelConfig.self, from: data),
           let url = try? saved.validatedURL() {
            var normalized = saved
            normalized.refreshInterval = saved.refreshInterval.isFinite ? min(60, max(3, saved.refreshInterval)) : 5
            config = normalized
            client = try? KomariClient(config: normalized, token: KeychainStore.read(account: url.absoluteString))
        }
    }

    deinit {
        pollingTask?.cancel()
        refreshTask?.cancel()
    }

    var storedToken: String {
        guard let url = try? config.validatedURL() else { return "" }
        return KeychainStore.read(account: url.absoluteString)
    }

    func testConnection(_ config: PanelConfig, token: String) async throws -> Int {
        let candidate = try KomariClient(config: config, token: token)
        do {
            let result = try await candidate.snapshot()
            await candidate.cancel()
            return result.nodes.count
        } catch {
            await candidate.cancel()
            throw error
        }
    }

    func configure(_ newConfig: PanelConfig, token: String) async throws {
        var normalized = newConfig
        normalized.baseURL = try newConfig.validatedURL().absoluteString
        normalized.name = newConfig.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.name.isEmpty { normalized.name = "我的面板" }
        normalized.refreshInterval = newConfig.refreshInterval.isFinite ? min(60, max(3, newConfig.refreshInterval)) : 5
        let candidate = try KomariClient(config: normalized, token: token)
        do {
            let snapshot = try await candidate.snapshot()
            try Task.checkCancellation()
            try KeychainStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines), account: normalized.baseURL)
            let persisted = try JSONEncoder().encode(normalized)
            stopCurrentRequests()
            let oldClient = client
            client = candidate
            config = normalized
            isDemo = false
            nodes = snapshot.nodes
            warningMessage = snapshot.pingWarning
            errorMessage = nil
            lastUpdated = Date()
            defaults.set(persisted, forKey: configKey)
            if let oldClient = oldClient { await oldClient.cancel() }
            if active { startPolling() }
        } catch {
            await candidate.cancel()
            throw error
        }
    }

    func refresh() async {
        guard !isDemo, let client = client, refreshTask == nil else { return }
        let requestGeneration = generation
        let task = Task { try await client.snapshot() }
        refreshTask = task
        isLoading = true
        defer {
            if generation == requestGeneration {
                refreshTask = nil
                isLoading = false
            }
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard generation == requestGeneration, !Task.isCancelled else { return }
            nodes = result.nodes
            warningMessage = result.pingWarning
            errorMessage = nil
            lastUpdated = Date()
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            errorMessage = Self.friendlyError(error)
            // Retained data is explicitly stale: never continue showing an unverified online badge.
            nodes = nodes.map { var node = $0; node.isOnline = false; return node }
        }
    }

    func fetchHistory(nodeID: String) async throws -> [MetricSample] {
        if isDemo { return DemoData.history(nodeID: nodeID) }
        guard let client = client else { return [] }
        return try await client.history(nodeID: nodeID)
    }

    func setActive(_ value: Bool) {
        active = value
        if value { startPolling() }
        else { stopCurrentRequests() }
    }

    func useDemo() {
        stopCurrentRequests()
        isDemo = true
        nodes = DemoData.nodes
        errorMessage = nil
        warningMessage = nil
        lastUpdated = Date()
    }

    func disconnect() {
        stopCurrentRequests()
        if let url = try? config.validatedURL() { KeychainStore.remove(account: url.absoluteString) }
        let oldClient = client
        client = nil
        if let oldClient = oldClient { Task { await oldClient.cancel() } }
        config = PanelConfig()
        nodes = []
        isDemo = false
        errorMessage = nil
        warningMessage = nil
        lastUpdated = nil
        defaults.removeObject(forKey: configKey)
    }

    private func startPolling() {
        guard active, !isDemo, client != nil, pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.config.refreshInterval else { return }
                do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    private func stopCurrentRequests() {
        generation = UUID()
        pollingTask?.cancel()
        pollingTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        isLoading = false
    }

    private static func friendlyError(_ error: Error) -> String {
        if let known = error as? MonitorError { return known.localizedDescription }
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet: return "网络未连接，当前保留上次数据。"
            case .timedOut: return "面板连接超时，当前保留上次数据。"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return "HTTPS 证书验证失败，请检查服务器证书。"
            default: return "无法连接面板，请检查网络、地址和端口。"
            }
        }
        return "数据更新失败，请检查面板连接。"
    }
}
