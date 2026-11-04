import SwiftUI
import SwiftData

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var bleManager: BLEManager
    @EnvironmentObject private var healthSyncBridge: HealthSyncBridge

    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Salud", systemImage: "heart.circle.fill")
                }
                .tag(0)

            DeviceTabView()
                .tabItem {
                    Label("Galaxy Fit 3", systemImage: "applewatch.radiowaves.left.and.right")
                }
                .tag(1)

            BLEDiagnosticsView()
                .tabItem {
                    Label("Sniffer BLE", systemImage: "terminal.fill")
                }
                .tag(2)
        }
        .tint(SamsungHealthTheme.mintSteps)
        .onAppear {
            bleManager.configure(modelContext: modelContext)
        }
    }
}
