import Foundation
import Combine
#if canImport(HealthKit)
import HealthKit
#endif

final class BiometricStorageManager: ObservableObject {
    static let shared = BiometricStorageManager()

    @Published var records: [HeartRateRecord] = []
    @Published var useAppleHealth: Bool = false {
        didSet {
            UserDefaults.standard.set(useAppleHealth, forKey: "fit3_use_apple_health")
            if useAppleHealth {
                DispatchQueue.main.async {
                    self.healthKitStatusMessage = "Apple Health activado (requiere Entitlement en cuenta de pago)"
                }
            } else {
                DispatchQueue.main.async {
                    self.healthKitStatusMessage = "Almacenamiento local CSV/JSON activo (Cuenta Gratuita OK)"
                }
            }
        }
    }
    @Published var healthKitStatusMessage: String = "Almacenamiento local CSV/JSON activo (Cuenta Gratuita OK)"

    private let csvFileName = "galaxy_fit3_heartrate.csv"
    private let jsonFileName = "galaxy_fit3_heartrate.json"
    private let csvHeader = "ISO8601_Timestamp,BPM,Battery_Percent\n"
    private let fileQueue = DispatchQueue(label: "com.galaxyfit3.biometricstorage.queue", qos: .utility)
    private let isoFormatter: ISO8601DateFormatter

    #if canImport(HealthKit)
    private lazy var healthStore: HKHealthStore? = {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        return HKHealthStore()
    }()
    #endif

    init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
        self.useAppleHealth = UserDefaults.standard.bool(forKey: "fit3_use_apple_health")

        ensureCSVFileExists()
        loadRecordsFromDisk()
    }

    // MARK: - Rutas de Archivos en Documents
    private var documentsDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private var csvFileURL: URL? {
        documentsDirectory?.appendingPathComponent(csvFileName)
    }

    private var jsonFileURL: URL? {
        documentsDirectory?.appendingPathComponent(jsonFileName)
    }

    // MARK: - Guardar Lectura de Frecuencia Cardíaca
    func saveHeartRate(bpm: Int, battery: Int?) {
        guard bpm > 0 && bpm < 260 else { return }
        let newRecord = HeartRateRecord(timestamp: Date(), bpm: bpm, batteryLevel: battery)

        // 1. Añadir al array en memoria en el hilo principal
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.records.insert(newRecord, at: 0)
        }

        // 2. Persistir en CSV y JSON en cola dedicada de E/S
        fileQueue.async { [weak self] in
            guard let self = self else { return }
            self.appendRecordToCSV(newRecord)
            self.saveRecordsToJSONSnapshot()
        }

        // 3. Sincronización opcional y segura con Apple Health
        if useAppleHealth {
            trySaveToAppleHealth(bpm: Double(bpm))
        }
    }

    // MARK: - Manejo de CSV (galaxy_fit3_heartrate.csv)
    private func ensureCSVFileExists() {
        fileQueue.async { [weak self] in
            guard let self = self, let url = self.csvFileURL else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                try? self.csvHeader.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func appendRecordToCSV(_ record: HeartRateRecord) {
        guard let url = csvFileURL else { return }

        if !FileManager.default.fileExists(atPath: url.path) {
            try? csvHeader.write(to: url, atomically: true, encoding: .utf8)
        }

        let timestampString = isoFormatter.string(from: record.timestamp)
        let batteryString = record.batteryLevel.map { String($0) } ?? ""
        let csvLine = "\(timestampString),\(record.bpm),\(batteryString)\n"

        guard let lineData = csvLine.data(using: .utf8) else { return }

        if let fileHandle = try? FileHandle(forWritingTo: url) {
            defer {
                try? fileHandle.close()
            }
            do {
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: lineData)
            } catch {
                // Fallback si falla FileHandle
                if var existing = try? String(contentsOf: url, encoding: .utf8) {
                    existing.append(csvLine)
                    try? existing.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        } else {
            let initialContent = csvHeader + csvLine
            try? initialContent.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Persistencia JSON + Carga Inicial
    private func saveRecordsToJSONSnapshot() {
        guard let jsonURL = jsonFileURL else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let snapshot = self.records
            self.fileQueue.async {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(snapshot) {
                    try? data.write(to: jsonURL, options: .atomic)
                }
            }
        }
    }

    private func loadRecordsFromDisk() {
        fileQueue.async { [weak self] in
            guard let self = self else { return }

            // Intentar cargar desde JSON primero para preservar UUIDs exactos
            if let jsonURL = self.jsonFileURL,
               FileManager.default.fileExists(atPath: jsonURL.path),
               let data = try? Data(contentsOf: jsonURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let loaded = try? decoder.decode([HeartRateRecord].self, from: data) {
                    DispatchQueue.main.async {
                        self.records = loaded
                    }
                    return
                }
            }

            // Fallback: reconstruir registros leyendo galaxy_fit3_heartrate.csv
            guard let csvURL = self.csvFileURL,
                  FileManager.default.fileExists(atPath: csvURL.path),
                  let content = try? String(contentsOf: csvURL, encoding: .utf8) else {
                return
            }

            let lines = content.components(separatedBy: .newlines)
            var parsedRecords: [HeartRateRecord] = []
            let fallbackISO = ISO8601DateFormatter()

            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let parts = trimmed.components(separatedBy: ",")
                guard parts.count >= 2,
                      let bpm = Int(parts[1]) else { continue }

                let date = self.isoFormatter.date(from: parts[0])
                    ?? fallbackISO.date(from: parts[0])
                    ?? Date()
                let battery: Int? = (parts.count >= 3 && !parts[2].isEmpty) ? Int(parts[2]) : nil

                parsedRecords.append(
                    HeartRateRecord(timestamp: date, bpm: bpm, batteryLevel: battery)
                )
            }

            parsedRecords.sort { $0.timestamp > $1.timestamp }

            DispatchQueue.main.async {
                self.records = parsedRecords
            }
        }
    }

    // MARK: - Exportación y Limpieza de Historial
    func getCSVFileURL() -> URL? {
        guard let url = csvFileURL else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? csvHeader.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    func clearHistory() {
        DispatchQueue.main.async { [weak self] in
            self?.records.removeAll()
        }

        fileQueue.async { [weak self] in
            guard let self = self else { return }
            if let csvURL = self.csvFileURL {
                try? self.csvHeader.write(to: csvURL, atomically: true, encoding: .utf8)
            }
            if let jsonURL = self.jsonFileURL, FileManager.default.fileExists(atPath: jsonURL.path) {
                try? FileManager.default.removeItem(at: jsonURL)
            }
        }
    }

    // MARK: - Apple HealthKit Opcional (Seguro sin Entitlements)
    func trySaveToAppleHealth(bpm: Double) {
        #if canImport(HealthKit)
        guard useAppleHealth else { return }
        guard HKHealthStore.isHealthDataAvailable(),
              let store = healthStore,
              let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            DispatchQueue.main.async {
                self.healthKitStatusMessage = "HealthKit no disponible en este dispositivo"
            }
            return
        }

        let shareTypes: Set<HKSampleType> = [heartRateType]
        store.requestAuthorization(toShare: shareTypes, read: nil) { [weak self] success, error in
            guard let self = self else { return }

            if let error = error {
                // Si se compila con cuenta gratuita sin Entitlements de HealthKit,
                // capturamos el error silenciosamente sin bloquear ni cerrar la app.
                DispatchQueue.main.async {
                    self.healthKitStatusMessage = "HealthKit omitido (Sin Entitlement): \(error.localizedDescription)"
                }
                return
            }

            guard success else {
                DispatchQueue.main.async {
                    self.healthKitStatusMessage = "Permiso de Apple Health denegado por el usuario"
                }
                return
            }

            let unit = HKUnit.count().unitDivided(by: HKUnit.minute())
            let quantity = HKQuantity(unit: unit, doubleValue: bpm)
            let now = Date()
            let metadata: [String: Any] = [
                HKMetadataKeyDeviceName: "Samsung Galaxy Fit 3 (SM-R390)"
            ]

            let sample = HKQuantitySample(
                type: heartRateType,
                quantity: quantity,
                start: now,
                end: now,
                metadata: metadata
            )

            store.save(sample) { saved, saveError in
                DispatchQueue.main.async {
                    if saved {
                        self.healthKitStatusMessage = "Último BPM (\(Int(bpm))) sincronizado en Apple Health"
                    } else if let saveError = saveError {
                        self.healthKitStatusMessage = "Error guardando en Health: \(saveError.localizedDescription)"
                    }
                }
            }
        }
        #endif
    }
}
