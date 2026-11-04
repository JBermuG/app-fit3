import Foundation
import Combine
import UIKit
import SwiftData
import AppIntents
#if canImport(HealthKit)
import HealthKit
#endif

// MARK: - Sync Method Selection

enum HealthSyncMethod: String, CaseIterable, Identifiable {
    case iosShortcutsBridge = "Puente Atajos de iOS (Sideloadly Free)"
    case directHealthKitOptional = "HealthKit Directo (Opcional)"

    var id: String { rawValue }
}

// MARK: - HealthSyncBridge Service

@MainActor
final class HealthSyncBridge: ObservableObject {

    @Published var selectedSyncMethod: HealthSyncMethod = .iosShortcutsBridge
    @Published var shortcutName: String = UserDefaults.standard.string(forKey: "fit3.shortcutName") ?? "Fit3 Health Sync" {
        didSet { UserDefaults.standard.set(shortcutName, forKey: "fit3.shortcutName") }
    }
    @Published var lastSyncStatus: String = "Sin sincronizar aún"
    @Published var lastExportedJSONPreview: String = ""
    @Published var lastSyncDate: Date? = nil
    @Published var isSyncing: Bool = false

    // MARK: - Main Sync Entry Point

    func syncPendingRecords(modelContext: ModelContext, bleManager: BLEManager, includeAlreadySyncedToday: Bool = true) async {
        isSyncing = true
        defer { isSyncing = false }

        switch selectedSyncMethod {
        case .iosShortcutsBridge:
            await exportViaShortcutsBridge(
                modelContext: modelContext,
                bleManager: bleManager,
                includeAlreadySyncedToday: includeAlreadySyncedToday
            )
        case .directHealthKitOptional:
            await syncViaOptionalHealthKit(
                modelContext: modelContext,
                bleManager: bleManager
            )
        }
    }

    // MARK: - Option A: iOS Shortcuts Bridge (Recommended for Sideloadly Free Account)

    func exportViaShortcutsBridge(
        modelContext: ModelContext,
        bleManager: BLEManager,
        includeAlreadySyncedToday: Bool = true
    ) async {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let startOfToday = Calendar.current.startOfDay(for: .now)

        // 1. Obtener registros desde SwiftData
        let stepDescriptor = FetchDescriptor<StepRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let hrDescriptor = FetchDescriptor<HeartRateRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let spo2Descriptor = FetchDescriptor<SpO2Record>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let sleepDescriptor = FetchDescriptor<SleepSession>(
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )

        let allSteps = (try? modelContext.fetch(stepDescriptor)) ?? []
        let allHR = (try? modelContext.fetch(hrDescriptor)) ?? []
        let allSpO2 = (try? modelContext.fetch(spo2Descriptor)) ?? []
        let allSleep = (try? modelContext.fetch(sleepDescriptor)) ?? []

        let filteredSteps = allSteps.filter { !$0.isSyncedToHealth || (includeAlreadySyncedToday && $0.date >= startOfToday) }
        let filteredHR = Array(allHR.filter { !$0.isSyncedToHealth || (includeAlreadySyncedToday && $0.timestamp >= startOfToday) }.prefix(25))
        let filteredSpO2 = Array(allSpO2.filter { !$0.isSyncedToHealth || (includeAlreadySyncedToday && $0.timestamp >= startOfToday) }.prefix(10))
        let filteredSleep = Array(allSleep.filter { !$0.isSyncedToHealth || (includeAlreadySyncedToday && $0.endTime >= startOfToday) }.prefix(3))

        let payload = Fit3ShortcutsExportPayload(
            schemaVersion: "1.0",
            exportedAtISO8601: isoFormatter.string(from: .now),
            deviceName: bleManager.connectedDeviceName,
            deviceModel: bleManager.modelNumber,
            summaryStepsToday: bleManager.todaySteps,
            summaryLatestHeartRateBPM: bleManager.currentHeartRate,
            summaryLatestSpO2Percent: bleManager.currentSpO2,
            summaryLastSleepMinutes: filteredSleep.first?.totalSleepMinutes ?? 0,
            stepRecords: filteredSteps.map {
                .init(
                    id: $0.id.uuidString,
                    dateISO8601: isoFormatter.string(from: $0.date),
                    steps: $0.steps,
                    activeCalories: $0.calories,
                    distanceMeters: $0.distanceMeters,
                    activeMinutes: $0.activeMinutes
                )
            },
            heartRateRecords: filteredHR.map {
                .init(
                    id: $0.id.uuidString,
                    timestampISO8601: isoFormatter.string(from: $0.timestamp),
                    bpm: $0.bpm
                )
            },
            spo2Records: filteredSpO2.map {
                .init(
                    id: $0.id.uuidString,
                    timestampISO8601: isoFormatter.string(from: $0.timestamp),
                    percentage: $0.percentage
                )
            },
            sleepSessions: filteredSleep.map {
                .init(
                    id: $0.id.uuidString,
                    startISO8601: isoFormatter.string(from: $0.startTime),
                    endISO8601: isoFormatter.string(from: $0.endTime),
                    totalSleepMinutes: $0.totalSleepMinutes,
                    deepMinutes: $0.deepMinutes,
                    lightMinutes: $0.lightMinutes,
                    remMinutes: $0.remMinutes,
                    awakeMinutes: $0.awakeMinutes,
                    sleepScore: $0.sleepScore
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let jsonData = try? encoder.encode(payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            lastSyncStatus = "❌ Error al codificar el payload JSON para Atajos."
            return
        }

        // Guardar en portapapeles del sistema y UserDefaults compartido para AppIntents
        UIPasteboard.general.string = jsonString
        UserDefaults.standard.set(jsonString, forKey: "fit3.latestShortcutsJSON")
        lastExportedJSONPreview = jsonString

        // Marcar registros como sincronizados
        filteredSteps.forEach { $0.isSyncedToHealth = true }
        filteredHR.forEach { $0.isSyncedToHealth = true }
        filteredSpO2.forEach { $0.isSyncedToHealth = true }
        filteredSleep.forEach { $0.isSyncedToHealth = true }
        try? modelContext.save()

        lastSyncDate = .now

        // Construir URL Scheme hacia la app Atajos de iOS
        let encodedShortcutName = shortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Fit3%20Health%20Sync"
        let urlString = "shortcuts://run-shortcut?name=\(encodedShortcutName)&input=clipboard"

        if let shortcutURL = URL(string: urlString), UIApplication.shared.canOpenURL(shortcutURL) {
            await UIApplication.shared.open(shortcutURL)
            lastSyncStatus = "✅ JSON copiado al portapapeles y Atajo '\(shortcutName)' ejecutado."
        } else {
            lastSyncStatus = "✅ JSON copiado al portapapeles (\(filteredHR.count) pulsos, \( bleManager.todaySteps) pasos). Abre la app Atajos para procesarlo."
        }
    }

    func copyJSONOnly(modelContext: ModelContext, bleManager: BLEManager) async {
        await exportViaShortcutsBridge(modelContext: modelContext, bleManager: bleManager, includeAlreadySyncedToday: true)
        lastSyncStatus = "📋 JSON estructurado copiado al portapapeles listo para Atajos."
    }

    // MARK: - Option B: Optional Direct HealthKit (Runtime Safe Wrapper)

    private func syncViaOptionalHealthKit(modelContext: ModelContext, bleManager: BLEManager) async {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            lastSyncStatus = "⚠️ HealthKit no está disponible en este dispositivo. Usa el Puente de Atajos."
            return
        }

        let store = HKHealthStore()
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount),
              let hrType = HKObjectType.quantityType(forIdentifier: .heartRate),
              let spo2Type = HKObjectType.quantityType(forIdentifier: .oxygenSaturation),
              let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
              let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            lastSyncStatus = "⚠️ Tipos de HealthKit no disponibles."
            return
        }

        let writeTypes: Set<HKSampleType> = [stepType, hrType, spo2Type, energyType, sleepType]

        do {
            // Si el .ipa fue firmado con Sideloadly sin entitlement de pago, requestAuthorization lanza error
            // que capturamos de forma segura sin provocar ningún crash.
            try await store.requestAuthorization(toShare: writeTypes, read: [])

            var samplesToSave: [HKSample] = []
            let now = Date.now
            let startOfDay = Calendar.current.startOfDay(for: now)

            if bleManager.todaySteps > 0 {
                let stepQuantity = HKQuantity(unit: .count(), doubleValue: Double(bleManager.todaySteps))
                let stepSample = HKQuantitySample(type: stepType, quantity: stepQuantity, start: startOfDay, end: now)
                samplesToSave.append(stepSample)
            }

            if bleManager.currentHeartRate > 0 {
                let hrUnit = HKUnit.count().unitDivided(by: .minute())
                let hrQuantity = HKQuantity(unit: hrUnit, doubleValue: Double(bleManager.currentHeartRate))
                let hrSample = HKQuantitySample(type: hrType, quantity: hrQuantity, start: now, end: now)
                samplesToSave.append(hrSample)
            }

            if bleManager.currentSpO2 > 0 {
                let spo2Quantity = HKQuantity(unit: .percent(), doubleValue: Double(bleManager.currentSpO2) / 100.0)
                let spo2Sample = HKQuantitySample(type: spo2Type, quantity: spo2Quantity, start: now, end: now)
                samplesToSave.append(spo2Sample)
            }

            if !samplesToSave.isEmpty {
                try await store.save(samplesToSave)
            }

            lastSyncDate = .now
            lastSyncStatus = "✅ Sincronizado directamente con HealthKit (\(samplesToSave.count) muestras)."
        } catch {
            // Fallback seguro para cuentas gratuitas de Sideloadly:
            lastSyncStatus = "ℹ️ Tu perfil gratuito de Sideloadly no incluye el entitlement de pago de HealthKit (\(error.localizedDescription)). Cambiando automáticamente al Puente de Atajos..."
            selectedSyncMethod = .iosShortcutsBridge
            await exportViaShortcutsBridge(modelContext: modelContext, bleManager: bleManager)
        }
        #else
        lastSyncStatus = "ℹ️ HealthKit SDK no enlazado. Usando Puente de Atajos de iOS."
        await exportViaShortcutsBridge(modelContext: modelContext, bleManager: bleManager)
        #endif
    }
}

// MARK: - AppIntents Integration for Native iOS Shortcuts

struct ExportFit3HealthJSONIntent: AppIntent {
    static let title: LocalizedStringResource = "Obtener Último JSON de Salud (Fit3 Link)"
    static let description = IntentDescription(
        "Devuelve el último paquete JSON con pasos, frecuencia cardíaca, SpO2 y sueño capturados desde la Samsung Galaxy Fit 3 para escribirlos en Apple Health mediante Atajos."
    )

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let json = UserDefaults.standard.string(forKey: "fit3.latestShortcutsJSON") ?? """
        {
          "schemaVersion": "1.0",
          "deviceName": "Galaxy Fit3",
          "summaryStepsToday": 0,
          "summaryLatestHeartRateBPM": 0,
          "summaryLatestSpO2Percent": 98,
          "summaryLastSleepMinutes": 0
        }
        """
        return .result(value: json)
    }
}

struct Fit3ShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ExportFit3HealthJSONIntent(),
            phrases: [
                "Sincronizar pasos de \(.applicationName)",
                "Obtener datos de salud de \(.applicationName)"
            ],
            shortTitle: "Exportar Salud Fit3",
            systemImageName: "heart.text.square.fill"
        )
    }
}
