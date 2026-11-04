import Foundation
import CoreBluetooth

// MARK: - Peripheral Item Representation

public struct ScannedPeripheralItem: Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public var rssi: Int
    public let isLikelyFit3: Bool
    public var advertisedServiceUUIDs: [String]
    public var lastSeen: Date
    public var isConnected: Bool
    public let peripheral: CBPeripheral

    public init(
        peripheral: CBPeripheral,
        rssi: Int,
        advertisedServiceUUIDs: [String] = [],
        isConnected: Bool = false
    ) {
        self.peripheral = peripheral
        self.id = peripheral.identifier
        let rawName = peripheral.name ?? "Dispositivo BLE (\(peripheral.identifier.uuidString.prefix(4)))"
        self.name = rawName
        self.rssi = rssi == 127 ? -65 : rssi
        self.advertisedServiceUUIDs = advertisedServiceUUIDs
        self.lastSeen = Date()
        self.isConnected = isConnected

        let upper = rawName.uppercased()
        self.isLikelyFit3 = upper.contains("FIT3")
            || upper.contains("78DC")
            || upper.contains("SM-R390")
            || upper.contains("GALAXY FIT")
            || advertisedServiceUUIDs.contains(where: {
                ["180D", "180F", "FD5A", "FEE7", "FDEE", "FEE0"].contains($0.uppercased())
            })
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: ScannedPeripheralItem, rhs: ScannedPeripheralItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - BLE Packet Direction & Heuristics

public enum BLEPacketDirection: String, Codable, CaseIterable, Sendable {
    case incoming = "RX"
    case outgoing = "TX"
}

public enum BLEHeuristicTag: String, Codable, CaseIterable, Sendable {
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

public struct BLEPacketLog: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let serviceUUID: String
    public let characteristicUUID: String
    public let rawBytes: Data
    public let direction: BLEPacketDirection
    public let heuristicTag: BLEHeuristicTag
    public let note: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
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

    /// Formato hexadecimal con bytes separados por espacio (e.g. "FE A1 00 12 34")
    public var hexString: String {
        rawBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Formato array numérico para inspección rápida (e.g. "[254, 161, 0, 18, 52]")
    public var byteArrayString: String {
        let array = [UInt8](rawBytes)
        return "[" + array.map(String.init).joined(separator: ", ") + "]"
    }

    /// Representación UTF-8 / ASCII legible
    public var utf8Preview: String {
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

    /// Decodificación Little-Endian (UInt8, UInt16LE, UInt32LE)
    public var decodedNumbersSummary: String {
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

// MARK: - Discovered Service and Characteristic Metadata

public struct DiscoveredCharacteristicInfo: Identifiable, Hashable, Sendable {
    public var id: String { "\(serviceUUID):\(uuid)" }
    public let serviceUUID: String
    public let uuid: String
    public let name: String
    public let propertiesDescription: String
    public let canRead: Bool
    public let canWrite: Bool
    public let canNotify: Bool
    public var isNotifying: Bool
    public var lastHexValue: String
    public var lastUTF8Value: String
    public var lastDecodedNumbers: String
    public var lastUpdated: Date?
}

public struct DiscoveredServiceInfo: Identifiable, Hashable, Sendable {
    public var id: String { uuid }
    public let uuid: String
    public let name: String
    public let isProprietarySamsung: Bool
    public var characteristics: [DiscoveredCharacteristicInfo]
}

// MARK: - Metric Assignment Target

public enum MetricAssignmentTarget: String, CaseIterable, Identifiable {
    case steps = "Pasos Diarios"
    case heartRate = "Frecuencia Cardíaca (BPM)"
    case battery = "Batería (%)"
    case sleep = "Fases de Sueño"

    public var id: String { rawValue }
}
