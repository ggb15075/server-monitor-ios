import SwiftUI

@main
@MainActor
struct ServerMonitorApp: App {
    @StateObject private var store = MonitorStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(store)
                .tint(MonitorStyle.mint)
                .onAppear {
                    if ProcessInfo.processInfo.arguments.contains("--demo") { store.useDemo() }
                    store.setActive(scenePhase == .active)
                }
                .onChange(of: scenePhase) { phase in
                    store.setActive(phase == .active)
                }
        }
    }
}
