import Foundation
import CoreBluetooth

// MARK: - 1. Dispositivo BLE Descubierto
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int

    init(peripheral: CBPeripheral, name: String, rssi: Int) {
        self.id = peripheral.identifier
        self.peripheral = peripheral
        self.name = name
        self.rssi = rssi
    }

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id && lhs.rssi == rhs.rssi && lhs.name == rhs.name
    }
}

// MARK: - 2. Registro de Frecuencia Cardíaca (Persistente en JSON / CSV)
struct HeartRateRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let bpm: Int
    let batteryLevel: Int?

    init(id: UUID = UUID(), timestamp: Date = Date(), bpm: Int, batteryLevel: Int?) {
        self.id = id
        self.timestamp = timestamp
        self.bpm = bpm
        self.batteryLevel = batteryLevel
    }
}

// MARK: - 3. Elemento de Característica GATT para el Inspector
struct GATTCharacteristicItem: Identifiable {
    let id: String
    let serviceUUID: String
    let serviceName: String
    let characteristic: CBCharacteristic
    let uuidString: String
    let characteristicName: String
    let propertiesText: String
    let canRead: Bool
    let canWrite: Bool
    let canNotify: Bool
    var isNotifying: Bool
    var lastHexValue: String
    var lastASCIIValue: String
    var lastUpdated: Date?

    init(characteristic: CBCharacteristic, lastHexValue: String = "--", lastASCIIValue: String = "--", lastUpdated: Date? = nil) {
        let sUUID = characteristic.service?.uuid.uuidString ?? "UNKNOWN"
        let cUUID = characteristic.uuid.uuidString
        self.id = "\(sUUID)_\(cUUID)"
        self.serviceUUID = sUUID
        self.serviceName = GATTCharacteristicItem.friendlyServiceName(for: sUUID)
        self.characteristic = characteristic
        self.uuidString = cUUID
        self.characteristicName = GATTCharacteristicItem.friendlyCharacteristicName(for: cUUID)

        let props = characteristic.properties
        self.canRead = props.contains(.read)
        self.canWrite = props.contains(.write) || props.contains(.writeWithoutResponse)
        self.canNotify = props.contains(.notify) || props.contains(.indicate)
        self.isNotifying = characteristic.isNotifying

        var propLabels: [String] = []
        if props.contains(.read) { propLabels.append("Read") }
        if props.contains(.write) { propLabels.append("Write") }
        if props.contains(.writeWithoutResponse) { propLabels.append("WriteNoResp") }
        if props.contains(.notify) { propLabels.append("Notify") }
        if props.contains(.indicate) { propLabels.append("Indicate") }
        if props.contains(.authenticatedSignedWrites) { propLabels.append("AuthWrite") }
        if props.contains(.notifyEncryptionRequired) || props.contains(.indicateEncryptionRequired) {
            propLabels.append("Encrypted")
        }
        self.propertiesText = propLabels.isEmpty ? "None" : propLabels.joined(separator: ", ")

        self.lastHexValue = lastHexValue
        self.lastASCIIValue = lastASCIIValue
        self.lastUpdated = lastUpdated
    }

    var shortPermissionsBadge: String {
        var badges: [String] = []
        if canRead { badges.append("R") }
        if canWrite { badges.append("W") }
        if canNotify { badges.append("N") }
        return badges.isEmpty ? "-" : badges.joined(separator: "/")
    }

    static func friendlyServiceName(for uuid: String) -> String {
        switch uuid.uppercased() {
        case "180D": return "Heart Rate Service (180D)"
        case "180F": return "Battery Service (180F)"
        case "1805": return "Current Time Service (1805)"
        case "180A": return "Device Information (180A)"
        case "1800": return "Generic Access (1800)"
        case "1801": return "Generic Attribute (1801)"
        case "1812": return "HID Service (1812)"
        case "FD59", "FE6B": return "Samsung Wearable Service (\(uuid))"
        default:
            return uuid.count > 8 ? "Samsung/Custom Service (\(uuid.prefix(8))…)" : "Service (\(uuid))"
        }
    }

    static func friendlyCharacteristicName(for uuid: String) -> String {
        switch uuid.uppercased() {
        case "2A37": return "Heart Rate Measurement"
        case "2A38": return "Body Sensor Location"
        case "2A39": return "Heart Rate Control Point"
        case "2A19": return "Battery Level"
        case "2A2B": return "Current Time"
        case "2A0F": return "Local Time Information"
        case "2A29": return "Manufacturer Name"
        case "2A24": return "Model Number"
        case "2A25": return "Serial Number"
        case "2A26": return "Firmware Revision"
        case "2A27": return "Hardware Revision"
        case "2A28": return "Software Revision"
        default:
            return "Characteristic \(uuid)"
        }
    }
}

// MARK: - 4. Entrada de Consola de Depuración BLE
enum LogEventType: String, Codable, CaseIterable {
    case INFO = "INFO"
    case RX = "RX"
    case TX = "TX"
    case ERROR = "ERROR"
}

struct LogEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let type: LogEventType
    let message: String

    init(id: UUID = UUID(), timestamp: Date = Date(), type: LogEventType, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.message = message
    }

    var formattedLine: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return "[\(formatter.string(from: timestamp))] [\(type.rawValue)] \(message)"
    }
}

// MARK: - Extensiones de Utilidad para Data y Hexadecimal
extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var asciiSafeString: String {
        let chars = self.map { byte -> Character in
            if byte >= 32 && byte <= 126, let scalar = UnicodeScalar(Int(byte)) {
                return Character(scalar)
            } else {
                return "."
            }
        }
        return String(chars)
    }

    init?(hexString: String) {
        let cleaned = hexString
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }

        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            let byteSubstring = cleaned[index..<nextIndex]
            guard let byte = UInt8(byteSubstring, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
