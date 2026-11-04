import Foundation
import SwiftData

// MARK: - SwiftData Persistent Models

@Model
final class StepRecord {
    var id: UUID
    var date: Date
    var steps: Int
    var calories: Double
    var distanceMeters: Double
    var activeMinutes: Int
    var source: String
    var isSyncedToHealth: Bool

    init(
        id: UUID = UUID(),
        date: Date = .now,
        steps: Int,
        calories: Double,
        distanceMeters: Double,
        activeMinutes: Int = 0,
        source: String = "Galaxy Fit3",
        isSyncedToHealth: Bool = false
    ) {
        self.id = id
        self.date = date
        self.steps = steps
        self.calories = calories
        self.distanceMeters = distanceMeters
        self.activeMinutes = activeMinutes
        self.source = source
        self.isSyncedToHealth = isSyncedToHealth
    }
}

@Model
final class HeartRateRecord {
    var id: UUID
    var timestamp: Date
    var bpm: Int
    var sensorContactDetected: Bool
    var rrIntervalMs: Int?
    var source: String
    var isSyncedToHealth: Bool

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        bpm: Int,
        sensorContactDetected: Bool = true,
        rrIntervalMs: Int? = nil,
        source: String = "Galaxy Fit3",
        isSyncedToHealth: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.bpm = bpm
        self.sensorContactDetected = sensorContactDetected
        self.rrIntervalMs = rrIntervalMs
        self.source = source
        self.isSyncedToHealth = isSyncedToHealth
    }
}

@Model
final class SpO2Record {
    var id: UUID
    var timestamp: Date
    var percentage: Int
    var source: String
    var isSyncedToHealth: Bool

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        percentage: Int,
        source: String = "Galaxy Fit3",
        isSyncedToHealth: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.percentage = percentage
        self.source = source
        self.isSyncedToHealth = isSyncedToHealth
    }
}

@Model
final class SleepSession {
    var id: UUID
    var startTime: Date
    var endTime: Date
    var deepMinutes: Int
    var lightMinutes: Int
    var remMinutes: Int
    var awakeMinutes: Int
    var sleepScore: Int
    var source: String
    var isSyncedToHealth: Bool

    init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date,
        deepMinutes: Int,
        lightMinutes: Int,
        remMinutes: Int,
        awakeMinutes: Int,
        sleepScore: Int = 82,
        source: String = "Galaxy Fit3",
        isSyncedToHealth: Bool = false
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.deepMinutes = deepMinutes
        self.lightMinutes = lightMinutes
        self.remMinutes = remMinutes
        self.awakeMinutes = awakeMinutes
        self.sleepScore = sleepScore
        self.source = source
        self.isSyncedToHealth = isSyncedToHealth
    }

    var totalSleepMinutes: Int {
        deepMinutes + lightMinutes + remMinutes
    }

    var totalInBedMinutes: Int {
        deepMinutes + lightMinutes + remMinutes + awakeMinutes
    }

    var formattedDuration: String {
        let hours = totalSleepMinutes / 60
        let mins = totalSleepMinutes % 60
        return "\(hours)h \(mins)m"
    }
}

// MARK: - BLE Sniffer & Reverse Engineering Models

enum BLEPacketDirection: String, Codable, CaseIterable, Sendable {
    case incoming = "RX"
    case outgoing = "TX"
}

enum BLEHeuristicTag: String, Codable, CaseIterable, Sendable {
    case all = "Todos"
    case heartRate = "Heart Rate (0x180D)"
    case battery = "Battery (0x180F)"
    case rscCadence = "Cadence/Speed (0x1814)"
    case stepsCandidate = "Candidato Pasos"
    case sleepCandidate = "Candidato Sueño"
    case spo2Candidate = "Candidato SpO2"
    case samsungProprietary = "Samsung Propietario"
    case deviceInfo = "Device Info (0x180A)"
    case customCommand = "Comando TX"
}

struct BLEPacketLog: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let serviceUUID: String
    let characteristicUUID: String
    let rawBytes: Data
    let direction: BLEPacketDirection
    let heuristicTag: BLEHeuristicTag
    let note: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        serviceUUID: String,
        characteristicUUID: String,
        rawBytes: Data,
        direction: BLEPacketDirection = .incoming,
        heuristicTag: BLEHeuristicTag = .samsungProprietary,
        note: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.serviceUUID = serviceUUID
        self.characteristicUUID = characteristicUUID
        self.rawBytes = rawBytes
        self.direction = direction
        self.heuristicTag = heuristicTag
        self.note = note
    }

    /// Representación en hexadecimal separada por espacios (ej. "FE 01 4A 00 12")
    var hexString: String {
        rawBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Representación UTF-8 / ASCII imprimible (reemplaza bytes de control por '.')
    var utf8Preview: String {
        if let validUTF8 = String(data: rawBytes, encoding: .utf8),
           validUTF8.allSatisfy({ !$0.isNewline && ($0.isASCII && ($0.asciiValue ?? 0) >= 32) }) {
            return validUTF8
        }
        let chars = rawBytes.map { byte -> Character in
            if (32...126).contains(byte) {
                return Character(UnicodeScalar(byte))
            }
            return "."
        }
        return String(chars)
    }

    /// Decodificación heurística de enteros Little-Endian para ingeniería inversa de pasos/sueño
    var decodedNumbersSummary: String {
        let bytes = [UInt8](rawBytes)
        guard !bytes.isEmpty else { return "Vacío" }

        var parts: [String] = []
        parts.append("u8[0]=\(bytes[0])")

        if bytes.count >= 2 {
            let u16_0 = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            parts.append("u16LE[0]=\(u16_0)")
        }
        if bytes.count >= 4 {
            let u16_2 = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
            let u32_0 = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            parts.append("u16LE[2]=\(u16_2)")
            parts.append("u32LE[0]=\(u32_0)")
        }
        if bytes.count >= 6 {
            let u16_4 = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
            parts.append("u16LE[4]=\(u16_4)")
        }
        return parts.joined(separator: " | ")
    }
}

struct DiscoveredCharacteristicInfo: Identifiable, Hashable, Sendable {
    var id: String { "\(serviceUUID):\(uuid)" }
    let serviceUUID: String
    let uuid: String
    let name: String
    let propertiesDescription: String
    let canRead: Bool
    let canWrite: Bool
    let canNotify: Bool
    var isNotifying: Bool
    var lastHexValue: String
    var lastUTF8Value: String
    var lastUpdated: Date?
}

struct DiscoveredServiceInfo: Identifiable, Hashable, Sendable {
    var id: String { uuid }
    let uuid: String
    let name: String
    let isProprietarySamsung: Bool
    var characteristics: [DiscoveredCharacteristicInfo]
}

// MARK: - Apple Health Shortcuts JSON Payload

struct Fit3ShortcutsExportPayload: Codable, Sendable {
    struct StepExportItem: Codable, Sendable {
        let id: String
        let dateISO8601: String
        let steps: Int
        let activeCalories: Double
        let distanceMeters: Double
        let activeMinutes: Int
    }

    struct HeartRateExportItem: Codable, Sendable {
        let id: String
        let timestampISO8601: String
        let bpm: Int
    }

    struct SpO2ExportItem: Codable, Sendable {
        let id: String
        let timestampISO8601: String
        let percentage: Int
    }

    struct SleepExportItem: Codable, Sendable {
        let id: String
        let startISO8601: String
        let endISO8601: String
        let totalSleepMinutes: Int
        let deepMinutes: Int
        let lightMinutes: Int
        let remMinutes: Int
        let awakeMinutes: Int
        let sleepScore: Int
    }

    let schemaVersion: String
    let exportedAtISO8601: String
    let deviceName: String
    let deviceModel: String
    let summaryStepsToday: Int
    let summaryLatestHeartRateBPM: Int
    let summaryLatestSpO2Percent: Int
    let summaryLastSleepMinutes: Int
    let stepRecords: [StepExportItem]
    let heartRateRecords: [HeartRateExportItem]
    let spo2Records: [SpO2ExportItem]
    let sleepSessions: [SleepExportItem]
}
