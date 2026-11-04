import SwiftUI
import SwiftData

// MARK: - Warm Dark Mode Color Palette (Tonos Cálidos y Orgánicos)

enum SamsungHealthTheme {
    static let background = Color(red: 0.071, green: 0.063, blue: 0.055)       // #12100E (Espresso Carbón Profundo)
    static let cardBackground = Color(red: 0.118, green: 0.102, blue: 0.090)   // #1E1A17 (Piedra Umber Cálida)
    static let cardBorder = Color(red: 0.961, green: 0.910, blue: 0.839).opacity(0.09)

    static let mintSteps = Color(red: 0.898, green: 0.604, blue: 0.322)        // #E59A52 (Ámbar Dorado / Miel)
    static let cyanActivity = Color(red: 0.541, green: 0.690, blue: 0.510)     // #8AB082 (Verde Salvia Cálido)
    static let coralHeart = Color(red: 0.851, green: 0.373, blue: 0.357)       // #D95F5B (Rojo Arcilla Suave)
    static let orangeCalories = Color(red: 0.851, green: 0.420, blue: 0.263)   // #D96B43 (Terracota Cobre)
    static let purpleSleep = Color(red: 0.722, green: 0.545, blue: 0.620)      // #B88B9E (Malva Tostado)
    static let indigoDeepSleep = Color(red: 0.549, green: 0.384, blue: 0.471)  // #8C6278 (Ciruela Cálido)
}

// MARK: - Main App Entry Point

@main
struct Fit3LinkApp: App {
    @StateObject private var bleManager = BLEManager()
    @StateObject private var healthSyncBridge = HealthSyncBridge()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            StepRecord.self,
            HeartRateRecord.self,
            SpO2Record.self,
            SleepSession.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("No se pudo inicializar el ModelContainer de SwiftData: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(bleManager)
                .environmentObject(healthSyncBridge)
                .preferredColorScheme(.dark)
        }
        .modelContainer(sharedModelContainer)
    }
}
