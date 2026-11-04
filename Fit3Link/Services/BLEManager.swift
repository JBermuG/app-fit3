import Foundation
@preconcurrency import CoreBluetooth
import SwiftData
import Combine

// MARK: - Discovered Peripheral Item

struct ScannedPeripheralItem: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
    let isLikelyFit3: Bool
    let advertisedServiceUUIDs: [String]
    let lastSeen: Date
}

// MARK: - BLE Connection State

enum Fit3ConnectionState: String {
    case disconnected = "Desconectado"
    case scanning = "Buscando Galaxy Fit 3..."
    case connecting = "Conectando..."
    case connected = "Conectado"
    case simulating = "Modo Simulación Activo"
}

// MARK: - BLEManager

@MainActor
final class BLEManager: NSObject, ObservableObject {

    // MARK: Standard & Samsung GATT UUID Constants
    enum GATT {
        // Servicios estándar Bluetooth SIG
        static let heartRateService = CBUUID(string: "180D")
        static let heartRateMeasurement = CBUUID(string: "2A37")
        static let bodySensorLocation = CBUUID(string: "2A38")

        static let batteryService = CBUUID(string: "180F")
        static let batteryLevel = CBUUID(string: "2A19")

        static let deviceInfoService = CBUUID(string: "180A")
        static let manufacturerName = CBUUID(string: "2A29")
        static let modelNumber = CBUUID(string: "2A24")
        static let serialNumber = CBUUID(string: "2A25")
        static let firmwareRevision = CBUUID(string: "2A26")
        static let hardwareRevision = CBUUID(string: "2A27")

        static let runningSpeedCadenceService = CBUUID(string: "1814")
        static let rscMeasurement = CBUUID(string: "2A53")

        static let immediateAlertService = CBUUID(string: "1802")
        static let alertLevel = CBUUID(string: "2A06")

        static let currentTimeService = CBUUID(string: "1805")
        static let currentTimeChar = CBUUID(string: "2A2B")

        // Prefijos y UUIDs frecuentes en wearables Samsung (Galaxy Fit3 SM-R390 / FreeRTOS BLE)
        static let samsungKnownServiceHints: Set<String> = [
            "FD5A", "FD69", "FDEE", "FEE0", "FEE1", "FFF0", "FE26",
            "0000FD5A-0000-1000-8000-00805F9B34FB",
            "0000FEE0-0000-1000-8000-00805F9B34FB"
        ]
    }

    // MARK: Published UI State
    @Published var connectionState: Fit3ConnectionState = .disconnected
    @Published var bluetoothPoweredOn: Bool = false
    @Published var statusBannerMessage: String = "Listo para escanear tu Samsung Galaxy Fit 3"

    @Published var connectedDeviceName: String = "Sin vincular"
    @Published var manufacturer: String = "Samsung Electronics"
    @Published var modelNumber: String = "SM-R390"
    @Published var firmwareVersion: String = "—"
    @Published var batteryLevel: Int = 0
    @Published var lastRSSI: Int = -62

    // Telemetría en tiempo real
    @Published var currentHeartRate: Int = 0
    @Published var sensorContactDetected: Bool = false
    @Published var currentSpO2: Int = 97
    @Published var todaySteps: Int = 0
    @Published var todayCalories: Double = 0.0
    @Published var todayDistanceMeters: Double = 0.0
    @Published var todayActiveMinutes: Int = 0
    @Published var instantaneousCadence: Int = 0
    @Published var instantaneousSpeedKmh: Double = 0.0

    // Estado ANCS / AMS & Bonding
    @Published var isBondedForANCS: Bool = false
    @Published var isFindMyBandActive: Bool = false

    // Escáner y modo desarrollador (Sniffer)
    @Published var scannedPeripherals: [ScannedPeripheralItem] = []
    @Published var showAllBLEDevicesInScanner: Bool = false
    @Published var autoSubscribeProprietaryUUIDs: Bool = true
    @Published var isSnifferPaused: Bool = false
    @Published var discoveredServices: [DiscoveredServiceInfo] = []
    @Published var packetLogs: [BLEPacketLog] = []

    // Mapeo configurable por el usuario para ingeniería inversa
    @Published var customStepsCharacteristicUUID: String = UserDefaults.standard.string(forKey: "fit3.customStepsCharUUID") ?? "FEA1" {
        didSet { UserDefaults.standard.set(customStepsCharacteristicUUID, forKey: "fit3.customStepsCharUUID") }
    }
    @Published var customSleepCharacteristicUUID: String = UserDefaults.standard.string(forKey: "fit3.customSleepCharUUID") ?? "FEA2" {
        didSet { UserDefaults.standard.set(customSleepCharacteristicUUID, forKey: "fit3.customSleepCharUUID") }
    }

    // Modo Simulación (Mock Mode)
    @Published var isMockModeEnabled: Bool = UserDefaults.standard.bool(forKey: "fit3.isMockModeEnabled") {
        didSet {
            UserDefaults.standard.set(isMockModeEnabled, forKey: "fit3.isMockModeEnabled")
            handleMockModeChange(isMockModeEnabled)
        }
    }

    // MARK: Private CoreBluetooth References
    private var centralManager: CBCentralManager!
    private var activePeripheral: CBPeripheral?
    private var peripheralCache: [UUID: CBPeripheral] = [:]
    private var characteristicsMap: [String: CBCharacteristic] = [:]
    private var mockTimer: Timer?
    private var modelContext: ModelContext?

    private let savedPeripheralUUIDKey = "fit3.savedPeripheralUUID"
    private let maxPacketLogsCount = 250

    override init() {
        super.init()
        let options: [String: Any] = [
            CBCentralManagerOptionShowPowerAlertKey: true,
            CBCentralManagerOptionRestoreIdentifierKey: "com.fit3link.central.restore"
        ]
        self.centralManager = CBCentralManager(delegate: self, queue: nil, options: options)

        if isMockModeEnabled {
            startMockSimulation()
        }
    }

    // MARK: - SwiftData Context Injection

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadInitialMetricsFromDatabase()
        if isMockModeEnabled && todaySteps == 0 {
            seedMockHistoryIfNeeded()
        }
    }

    private func loadInitialMetricsFromDatabase() {
        guard let context = modelContext else { return }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: .now)

        let stepDescriptor = FetchDescriptor<StepRecord>(
            predicate: #Predicate { $0.date >= startOfToday },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        if let latestStep = try? context.fetch(stepDescriptor).first {
            todaySteps = latestStep.steps
            todayCalories = latestStep.calories
            todayDistanceMeters = latestStep.distanceMeters
            todayActiveMinutes = latestStep.activeMinutes
        }

        let hrDescriptor = FetchDescriptor<HeartRateRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        if let latestHR = try? context.fetch(hrDescriptor).first {
            currentHeartRate = latestHR.bpm
        }

        let spo2Descriptor = FetchDescriptor<SpO2Record>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        if let latestSpO2 = try? context.fetch(spo2Descriptor).first {
            currentSpO2 = latestSpO2.percentage
        }
    }

    // MARK: - Public BLE Actions

    func startScanning() {
        if isMockModeEnabled {
            statusBannerMessage = "Desactiva el Modo Simulación para usar el escáner BLE real."
            return
        }
        guard centralManager.state == .poweredOn else {
            statusBannerMessage = "Bluetooth apagado o sin permisos en Ajustes de iOS."
            return
        }

        scannedPeripherals.removeAll()
        connectionState = .scanning
        statusBannerMessage = "Escaneando dispositivos BLE cercanos..."

        // Intentar reconectar primero con periféricos ya enlazados en iOS (p. ej. vía Ajustes > Bluetooth)
        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: [
            GATT.heartRateService,
            GATT.batteryService,
            GATT.deviceInfoService,
            GATT.runningSpeedCadenceService
        ])

        for peripheral in connectedPeripherals {
            registerDiscoveredPeripheral(peripheral, rssi: -55, advertisedUUIDs: ["180D", "180F"])
        }

        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
        if connectionState == .scanning {
            connectionState = activePeripheral?.state == .connected ? .connected : .disconnected
            statusBannerMessage = "Escaneo detenido."
        }
    }

    func connectToScannedPeripheral(_ item: ScannedPeripheralItem) {
        guard let peripheral = peripheralCache[item.id] else { return }
        centralManager.stopScan()
        connectionState = .connecting
        statusBannerMessage = "Conectando con \(item.name)..."
        activePeripheral = peripheral
        peripheral.delegate = self
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedPeripheralUUIDKey)

        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ])
    }

    func disconnect() {
        if isMockModeEnabled {
            isMockModeEnabled = false
            return
        }
        if let peripheral = activePeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectionState = .disconnected
        statusBannerMessage = "Pulsera desconectada."
    }

    func forgetSavedDevice() {
        UserDefaults.standard.removeObject(forKey: savedPeripheralUUIDKey)
        disconnect()
        discoveredServices.removeAll()
        characteristicsMap.removeAll()
        connectedDeviceName = "Sin vincular"
        isBondedForANCS = false
    }

    // MARK: - Bonding (ANCS / AMS) & Find My Band

    /// Fuerza la lectura/suscripción de características protegidas para disparar el cuadro de diálogo
    /// de emparejamiento seguro (Bonding) de iOS y activar ANCS (notificaciones) y AMS (música).
    func requestANCSAndAMSBonding() {
        if isMockModeEnabled {
            isBondedForANCS = true
            statusBannerMessage = "Emparejamiento seguro ANCS/AMS simulado correctamente."
            return
        }
        guard let peripheral = activePeripheral, peripheral.state == .connected else {
            statusBannerMessage = "Conecta primero tu Galaxy Fit 3 para solicitar el enlace ANCS."
            return
        }

        statusBannerMessage = "Solicitando enlace seguro (Bonding) para ANCS/AMS..."
        for (_, characteristic) in characteristicsMap {
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }
        isBondedForANCS = true
    }

    /// Envía el comando de alerta inmediata (0x1802 / 0x2A06) o trama propietaria Samsung para hacer vibrar la pulsera.
    func triggerFindMyBand() {
        isFindMyBandActive.toggle()
        let alertByte: UInt8 = isFindMyBandActive ? 0x02 : 0x00 // 0x02 = High Alert, 0x00 = Stop
        let payload = Data([alertByte])

        if isMockModeEnabled {
            appendPacketLog(
                serviceUUID: "1802",
                characteristicUUID: "2A06",
                data: payload,
                direction: .outgoing,
                tag: .customCommand,
                note: isFindMyBandActive ? "Encontrar mi pulsera: Alerta Alta (0x02)" : "Detener alerta (0x00)"
            )
            statusBannerMessage = isFindMyBandActive
                ? "🔔 Haciendo vibrar/sonar Galaxy Fit 3 (Simulado)..."
                : "Alerta de búsqueda detenida."
            return
        }

        guard let peripheral = activePeripheral, peripheral.state == .connected else {
            isFindMyBandActive = false
            statusBannerMessage = "La pulsera no está conectada."
            return
        }

        // 1. Buscar característica estándar Immediate Alert (2A06)
        if let alertChar = characteristicsMap.values.first(where: { $0.uuid == GATT.alertLevel }) {
            let writeType: CBCharacteristicWriteType = alertChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            peripheral.writeValue(payload, for: alertChar, type: writeType)
            appendPacketLog(
                serviceUUID: "1802",
                characteristicUUID: "2A06",
                data: payload,
                direction: .outgoing,
                tag: .customCommand,
                note: "Immediate Alert enviado"
            )
            statusBannerMessage = isFindMyBandActive ? "🔔 Señal de vibración enviada a la Fit 3." : "Alerta detenida."
            return
        }

        // 2. Fallback: enviar trama de vibración a la primera característica propietaria con permiso Write
        let samsungFindFrame = Data([0xFE, 0x5A, 0x01, alertByte])
        if let writableChar = characteristicsMap.values.first(where: {
            $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
        }) {
            let writeType: CBCharacteristicWriteType = writableChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            peripheral.writeValue(samsungFindFrame, for: writableChar, type: writeType)
            appendPacketLog(
                serviceUUID: writableChar.service?.uuid.uuidString ?? "PROP",
                characteristicUUID: writableChar.uuid.uuidString,
                data: samsungFindFrame,
                direction: .outgoing,
                tag: .customCommand,
                note: "Trama Find-My-Band propietaria enviada"
            )
            statusBannerMessage = isFindMyBandActive
                ? "🔔 Trama de búsqueda enviada a UUID \(writableChar.uuid.uuidString)."
                : "Alerta detenida."
        } else {
            statusBannerMessage = "No se encontró característica de escritura para alerta."
        }
    }

    // MARK: - Developer Mode / GATT Sniffer Actions

    func readCharacteristic(serviceUUID: String, characteristicUUID: String) {
        let key = "\(serviceUUID):\(characteristicUUID)"
        guard let peripheral = activePeripheral,
              peripheral.state == .connected,
              let char = characteristicsMap[key] else {
            statusBannerMessage = "No se puede leer \(characteristicUUID) (no conectado)."
            return
        }
        peripheral.readValue(for: char)
    }

    func toggleNotification(serviceUUID: String, characteristicUUID: String) {
        let key = "\(serviceUUID):\(characteristicUUID)"
        guard let peripheral = activePeripheral,
              peripheral.state == .connected,
              let char = characteristicsMap[key] else {
            return
        }
        let targetState = !char.isNotifying
        peripheral.setNotifyValue(targetState, for: char)
    }

    func writeHexPayload(_ hexString: String, toService serviceUUID: String, characteristic characteristicUUID: String) {
        let cleaned = hexString
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()

        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else {
            statusBannerMessage = "Formato Hex inválido. Usa pares de bytes (ej. FE 01 0A)."
            return
        }

        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            let byteSubstring = cleaned[index..<nextIndex]
            guard let byte = UInt8(byteSubstring, radix: 16) else {
                statusBannerMessage = "Byte hexadecimal inválido: \(byteSubstring)"
                return
            }
            data.append(byte)
            index = nextIndex
        }

        appendPacketLog(
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            data: data,
            direction: .outgoing,
            tag: .customCommand,
            note: "Envío manual Hex"
        )

        if isMockModeEnabled {
            statusBannerMessage = "TX simulado (\(data.count) bytes) hacia \(characteristicUUID)."
            return
        }

        let key = "\(serviceUUID):\(characteristicUUID)"
        guard let peripheral = activePeripheral,
              peripheral.state == .connected,
              let char = characteristicsMap[key] else {
            statusBannerMessage = "Periférico no conectado para escribir en \(characteristicUUID)."
            return
        }

        let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: char, type: writeType)
        statusBannerMessage = "Enviados \(data.count) bytes a \(characteristicUUID)."
    }

    func clearPacketLogs() {
        packetLogs.removeAll()
    }

    // MARK: - Standard & Proprietary Packet Parsing

    private func handleIncomingCharacteristicData(serviceUUID: String, characteristicUUID: String, data: Data) {
        guard !data.isEmpty else { return }
        let bytes = [UInt8](data)

        // 1. Heart Rate Measurement (0x2A37)
        if characteristicUUID.uppercased().contains("2A37") {
            let flags = bytes[0]
            let is16Bit = (flags & 0x01) != 0
            let contactSupported = (flags & 0x04) != 0
            let contactDetected = (flags & 0x02) != 0
            sensorContactDetected = contactSupported ? contactDetected : true

            var bpm = 0
            var offset = 1
            if is16Bit && bytes.count >= 3 {
                bpm = Int(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
                offset = 3
            } else if bytes.count >= 2 {
                bpm = Int(bytes[1])
                offset = 2
            }

            // Energy Expended present (bit 3)
            if (flags & 0x08) != 0 {
                offset += 2
            }

            var rrInterval: Int? = nil
            if (flags & 0x10) != 0 && bytes.count >= offset + 2 {
                let rawRR = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                rrInterval = Int((Double(rawRR) / 1024.0) * 1000.0)
            }

            if bpm > 25 && bpm < 240 {
                currentHeartRate = bpm
                persistHeartRate(bpm: bpm, contact: sensorContactDetected, rrMs: rrInterval, source: "Galaxy Fit3 BLE")
            }

            appendPacketLog(
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                data: data,
                direction: .incoming,
                tag: .heartRate,
                note: "Pulso: \(bpm) BPM"
            )
            return
        }

        // 2. Battery Level (0x2A19)
        if characteristicUUID.uppercased().contains("2A19") {
            let level = Int(bytes[0])
            batteryLevel = min(max(level, 0), 100)
            appendPacketLog(
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                data: data,
                direction: .incoming,
                tag: .battery,
                note: "Batería: \(batteryLevel)%"
            )
            return
        }

        // 3. Device Information Service (0x180A)
        if serviceUUID.uppercased().contains("180A") {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? ""
            if characteristicUUID.uppercased().contains("2A29"), !text.isEmpty {
                manufacturer = text
            } else if characteristicUUID.uppercased().contains("2A24"), !text.isEmpty {
                modelNumber = text
            } else if characteristicUUID.uppercased().contains("2A26"), !text.isEmpty {
                firmwareVersion = text
            }
            appendPacketLog(
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                data: data,
                direction: .incoming,
                tag: .deviceInfo,
                note: "Info: \(text)"
            )
            return
        }

        // 4. Running Speed and Cadence (0x1814 -> 0x2A53)
        if characteristicUUID.uppercased().contains("2A53") && bytes.count >= 4 {
            let flags = bytes[0]
            let rawSpeed = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            // Unidad Bluetooth SIG: 1/256 m/s
            let speedMetersPerSec = Double(rawSpeed) / 256.0
            instantaneousSpeedKmh = speedMetersPerSec * 3.6
            instantaneousCadence = Int(bytes[3])

            var offset = 4
            if (flags & 0x01) != 0 && bytes.count >= offset + 2 {
                offset += 2 // Stride length en cm
            }
            if (flags & 0x02) != 0 && bytes.count >= offset + 4 {
                let rawTotalDistDecimeters = UInt32(bytes[offset])
                    | (UInt32(bytes[offset + 1]) << 8)
                    | (UInt32(bytes[offset + 2]) << 16)
                    | (UInt32(bytes[offset + 3]) << 24)
                todayDistanceMeters = Double(rawTotalDistDecimeters) / 10.0
            }

            appendPacketLog(
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                data: data,
                direction: .incoming,
                tag: .rscCadence,
                note: String(format: "Cadencia: %d spm | %.1f km/h", instantaneousCadence, instantaneousSpeedKmh)
            )
            return
        }

        // 5. Heurística y Mapeo Propietario de Samsung (Galaxy Fit 3 SM-R390)
        parseProprietarySamsungPacket(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID, data: data)
    }

    private func parseProprietarySamsungPacket(serviceUUID: String, characteristicUUID: String, data: Data) {
        let bytes = [UInt8](data)
        let upperChar = characteristicUUID.uppercased()

        // Si coincide con la característica configurada por el usuario para Pasos o firma heurística 0xFE 0xA1
        if upperChar.contains(customStepsCharacteristicUUID.uppercased())
            || (bytes.count >= 6 && bytes[0] == 0xFE && bytes[1] == 0xA1) {

            let stepsOffset = (bytes[0] == 0xFE && bytes[1] == 0xA1) ? 2 : 0
            if bytes.count >= stepsOffset + 4 {
                let decodedSteps = Int(
                    UInt32(bytes[stepsOffset])
                    | (UInt32(bytes[stepsOffset + 1]) << 8)
                    | (UInt32(bytes[stepsOffset + 2]) << 16)
                    | (UInt32(bytes[stepsOffset + 3]) << 24)
                )
                if decodedSteps >= 0 && decodedSteps < 150_000 {
                    todaySteps = decodedSteps
                    todayCalories = Double(decodedSteps) * 0.042
                    todayDistanceMeters = Double(decodedSteps) * 0.74
                    todayActiveMinutes = max(todayActiveMinutes, decodedSteps / 110)
                    persistTodaySteps(source: "Galaxy Fit3 BLE")
                }
                appendPacketLog(
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID,
                    data: data,
                    direction: .incoming,
                    tag: .stepsCandidate,
                    note: "Pasos decodificados: \(todaySteps)"
                )
                return
            }
        }

        // Si coincide con la característica de Sueño o cabecera heurística 0xFE 0xA2
        if upperChar.contains(customSleepCharacteristicUUID.uppercased())
            || (bytes.count >= 6 && bytes[0] == 0xFE && bytes[1] == 0xA2) {
            let offset = (bytes[0] == 0xFE && bytes[1] == 0xA2) ? 2 : 0
            if bytes.count >= offset + 4 {
                let deep = Int(bytes[offset])
                let light = Int(bytes[offset + 1]) * 2
                let rem = Int(bytes[offset + 2])
                let awake = Int(bytes[offset + 3])
                persistSleepSessionIfValid(deep: deep, light: light, rem: rem, awake: awake, source: "Galaxy Fit3 BLE")
                appendPacketLog(
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID,
                    data: data,
                    direction: .incoming,
                    tag: .sleepCandidate,
                    note: "Sueño RX: Prof \(deep)m / Lig \(light)m / REM \(rem)m"
                )
                return
            }
        }

        // Candidato SpO2 (cabecera 0xFE 0xA3 o porcentaje 85..100 en 2 bytes)
        if bytes.count >= 3 && bytes[0] == 0xFE && bytes[1] == 0xA3 {
            let spo2 = Int(bytes[2])
            if (85...100).contains(spo2) {
                currentSpO2 = spo2
                persistSpO2(percentage: spo2, source: "Galaxy Fit3 BLE")
                appendPacketLog(
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID,
                    data: data,
                    direction: .incoming,
                    tag: .spo2Candidate,
                    note: "SpO2: \(spo2)%"
                )
                return
            }
        }

        // Cualquier otro paquete propietario de Samsung se registra en el Sniffer para ingeniería inversa
        appendPacketLog(
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            data: data,
            direction: .incoming,
            tag: .samsungProprietary,
            note: "Trama propietaria (\(data.count) bytes)"
        )
    }

    private func appendPacketLog(
        serviceUUID: String,
        characteristicUUID: String,
        data: Data,
        direction: BLEPacketDirection,
        tag: BLEHeuristicTag,
        note: String?
    ) {
        // Actualizar último valor en el árbol de características descubiertas
        updateDiscoveredCharacteristicValue(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID, data: data)

        guard !isSnifferPaused else { return }
        let entry = BLEPacketLog(
            timestamp: .now,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            rawBytes: data,
            direction: direction,
            heuristicTag: tag,
            note: note
        )
        packetLogs.insert(entry, at: 0)
        if packetLogs.count > maxPacketLogsCount {
            packetLogs.removeLast(packetLogs.count - maxPacketLogsCount)
        }
    }

    private func updateDiscoveredCharacteristicValue(serviceUUID: String, characteristicUUID: String, data: Data) {
        guard let sIdx = discoveredServices.firstIndex(where: { $0.uuid == serviceUUID }),
              let cIdx = discoveredServices[sIdx].characteristics.firstIndex(where: { $0.uuid == characteristicUUID }) else {
            return
        }
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let utf8 = String(data: data, encoding: .utf8) ?? ""
        discoveredServices[sIdx].characteristics[cIdx].lastHexValue = hex
        discoveredServices[sIdx].characteristics[cIdx].lastUTF8Value = utf8
        discoveredServices[sIdx].characteristics[cIdx].lastUpdated = .now
    }

    // MARK: - SwiftData Persistence Helpers

    private func persistHeartRate(bpm: Int, contact: Bool, rrMs: Int?, source: String) {
        guard let context = modelContext else { return }
        let record = HeartRateRecord(
            timestamp: .now,
            bpm: bpm,
            sensorContactDetected: contact,
            rrIntervalMs: rrMs,
            source: source
        )
        context.insert(record)
        try? context.save()
    }

    private func persistSpO2(percentage: Int, source: String) {
        guard let context = modelContext else { return }
        let record = SpO2Record(timestamp: .now, percentage: percentage, source: source)
        context.insert(record)
        try? context.save()
    }

    private func persistTodaySteps(source: String) {
        guard let context = modelContext else { return }
        let startOfToday = Calendar.current.startOfDay(for: .now)
        let descriptor = FetchDescriptor<StepRecord>(
            predicate: #Predicate { $0.date >= startOfToday },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.steps = todaySteps
            existing.calories = todayCalories
            existing.distanceMeters = todayDistanceMeters
            existing.activeMinutes = todayActiveMinutes
            existing.date = .now
            existing.isSyncedToHealth = false
        } else {
            let newRecord = StepRecord(
                date: .now,
                steps: todaySteps,
                calories: todayCalories,
                distanceMeters: todayDistanceMeters,
                activeMinutes: todayActiveMinutes,
                source: source
            )
            context.insert(newRecord)
        }
        try? context.save()
    }

    private func persistSleepSessionIfValid(deep: Int, light: Int, rem: Int, awake: Int, source: String) {
        guard let context = modelContext else { return }
        let total = deep + light + rem
        guard total > 30 else { return }

        let startOfToday = Calendar.current.startOfDay(for: .now)
        let descriptor = FetchDescriptor<SleepSession>(
            predicate: #Predicate { $0.endTime >= startOfToday }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.deepMinutes = deep
            existing.lightMinutes = light
            existing.remMinutes = rem
            existing.awakeMinutes = awake
        } else {
            let end = startOfToday.addingTimeInterval(7 * 3600)
            let start = end.addingTimeInterval(-Double(total + awake) * 60.0)
            let session = SleepSession(
                startTime: start,
                endTime: end,
                deepMinutes: deep,
                lightMinutes: light,
                remMinutes: rem,
                awakeMinutes: awake,
                sleepScore: min(98, 65 + (deep / 4)),
                source: source
            )
            context.insert(session)
        }
        try? context.save()
    }

    // MARK: - Mock Mode (Modo Simulación)

    private func handleMockModeChange(_ enabled: Bool) {
        if enabled {
            if let peripheral = activePeripheral, peripheral.state == .connected {
                centralManager.cancelPeripheralConnection(peripheral)
            }
            startMockSimulation()
        } else {
            stopMockSimulation()
        }
    }

    private func startMockSimulation() {
        mockTimer?.invalidate()
        connectionState = .simulating
        connectedDeviceName = "Galaxy Fit3 (F9A2)"
        manufacturer = "Samsung Electronics"
        modelNumber = "SM-R390"
        firmwareVersion = "R390XXU0AXB4"
        batteryLevel = 86
        lastRSSI = -51
        isBondedForANCS = true
        sensorContactDetected = true

        if todaySteps == 0 {
            todaySteps = 6_842
            todayCalories = 287.4
            todayDistanceMeters = 5_063.0
            todayActiveMinutes = 54
        }
        if currentHeartRate == 0 {
            currentHeartRate = 74
        }
        currentSpO2 = 98

        statusBannerMessage = "Modo Simulación activo: Generando telemetría y tramas BLE de Galaxy Fit 3."

        // Poblar árbol de servicios GATT estándar + propietarios Samsung para el inspector
        discoveredServices = [
            DiscoveredServiceInfo(
                uuid: "180D",
                name: "Heart Rate Service",
                isProprietarySamsung: false,
                characteristics: [
                    DiscoveredCharacteristicInfo(
                        serviceUUID: "180D",
                        uuid: "2A37",
                        name: "Heart Rate Measurement",
                        propertiesDescription: "Notify",
                        canRead: false,
                        canWrite: false,
                        canNotify: true,
                        isNotifying: true,
                        lastHexValue: "16 4A E8 03",
                        lastUTF8Value: ".J..",
                        lastUpdated: .now
                    )
                ]
            ),
            DiscoveredServiceInfo(
                uuid: "180F",
                name: "Battery Service",
                isProprietarySamsung: false,
                characteristics: [
                    DiscoveredCharacteristicInfo(
                        serviceUUID: "180F",
                        uuid: "2A19",
                        name: "Battery Level",
                        propertiesDescription: "Read, Notify",
                        canRead: true,
                        canWrite: false,
                        canNotify: true,
                        isNotifying: true,
                        lastHexValue: "56",
                        lastUTF8Value: "V",
                        lastUpdated: .now
                    )
                ]
            ),
            DiscoveredServiceInfo(
                uuid: "1814",
                name: "Running Speed and Cadence",
                isProprietarySamsung: false,
                characteristics: [
                    DiscoveredCharacteristicInfo(
                        serviceUUID: "1814",
                        uuid: "2A53",
                        name: "RSC Measurement",
                        propertiesDescription: "Notify",
                        canRead: false,
                        canWrite: false,
                        canNotify: true,
                        isNotifying: true,
                        lastHexValue: "03 40 01 52 4C 00 C7 C5 00 00",
                        lastUTF8Value: ".@.RL.....",
                        lastUpdated: .now
                    )
                ]
            ),
            DiscoveredServiceInfo(
                uuid: "FD5A",
                name: "Samsung Wearable Health Bus (Propietario)",
                isProprietarySamsung: true,
                characteristics: [
                    DiscoveredCharacteristicInfo(
                        serviceUUID: "FD5A",
                        uuid: "FEA1",
                        name: "Samsung Pedometer & Calories Frame",
                        propertiesDescription: "Read, Write, Notify",
                        canRead: true,
                        canWrite: true,
                        canNotify: true,
                        isNotifying: true,
                        lastHexValue: "FE A1 BA 1A 00 00",
                        lastUTF8Value: "......",
                        lastUpdated: .now
                    ),
                    DiscoveredCharacteristicInfo(
                        serviceUUID: "FD5A",
                        uuid: "FEA2",
                        name: "Samsung Sleep Stages Telemetry",
                        propertiesDescription: "Read, Notify",
                        canRead: true,
                        canWrite: false,
                        canNotify: true,
                        isNotifying: true,
                        lastHexValue: "FE A2 58 6E 5C 12",
                        lastUTF8Value: "..Xn\\.",
                        lastUpdated: .now
                    ),
                    DiscoveredCharacteristicInfo(
                        serviceUUID: "FD5A",
                        uuid: "FEA3",
                        name: "Samsung SpO2 Red/IR Sensor",
                        propertiesDescription: "Read, Notify",
                        canRead: true,
                        canWrite: false,
                        canNotify: true,
                        isNotifying: true,
                        lastHexValue: "FE A3 62 00",
                        lastUTF8Value: "..b.",
                        lastUpdated: .now
                    )
                ]
            )
        ]

        seedMockHistoryIfNeeded()

        mockTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emitSimulatedTick()
            }
        }
    }

    private func stopMockSimulation() {
        mockTimer?.invalidate()
        mockTimer = nil
        connectionState = .disconnected
        connectedDeviceName = "Sin vincular"
        discoveredServices.removeAll()
        statusBannerMessage = "Modo Simulación desactivado. Escanea tu Galaxy Fit 3 física."
    }

    private func emitSimulatedTick() {
        guard isMockModeEnabled else { return }

        // 1. Simular paquete Heart Rate 0x2A37
        let deltaHR = Int.random(in: -3...4)
        let nextBPM = min(max((currentHeartRate == 0 ? 74 : currentHeartRate) + deltaHR, 61), 128)
        let rrRaw = UInt16((60.0 / Double(nextBPM)) * 1024.0)
        let hrFrame = Data([
            0x16, // Flags: 8-bit BPM + Sensor Contact Detected + RR-Interval present
            UInt8(nextBPM),
            UInt8(rrRaw & 0xFF),
            UInt8((rrRaw >> 8) & 0xFF)
        ])
        handleIncomingCharacteristicData(serviceUUID: "180D", characteristicUUID: "2A37", data: hrFrame)

        // 2. Simular paquete propietario Samsung de Pasos (UUID FEA1)
        let addedSteps = Int.random(in: 4...19)
        let newSteps = UInt32(todaySteps + addedSteps)
        let stepsFrame = Data([
            0xFE, 0xA1,
            UInt8(newSteps & 0xFF),
            UInt8((newSteps >> 8) & 0xFF),
            UInt8((newSteps >> 16) & 0xFF),
            UInt8((newSteps >> 24) & 0xFF)
        ])
        handleIncomingCharacteristicData(serviceUUID: "FD5A", characteristicUUID: "FEA1", data: stepsFrame)

        // 3. Cada ~3 ticks simular trama SpO2 (UUID FEA3)
        if Int.random(in: 0...2) == 0 {
            let spo2Val = UInt8(Int.random(in: 96...99))
            let spo2Frame = Data([0xFE, 0xA3, spo2Val, 0x00])
            handleIncomingCharacteristicData(serviceUUID: "FD5A", characteristicUUID: "FEA3", data: spo2Frame)
        }
    }

    func seedMockHistoryIfNeeded() {
        guard let context = modelContext else { return }

        let hrCount = (try? context.fetchCount(FetchDescriptor<HeartRateRecord>())) ?? 0
        if hrCount < 6 {
            let baseNow = Date.now
            let sampleBPMs = [66, 68, 72, 79, 94, 108, 96, 82, 75, 71, 74, 76]
            for (index, bpm) in sampleBPMs.enumerated() {
                let timestamp = baseNow.addingTimeInterval(-Double(sampleBPMs.count - index) * 900)
                let record = HeartRateRecord(
                    timestamp: timestamp,
                    bpm: bpm,
                    sensorContactDetected: true,
                    rrIntervalMs: Int(60_000.0 / Double(bpm)),
                    source: "Galaxy Fit3 (Simulación)"
                )
                context.insert(record)
            }
        }

        let sleepCount = (try? context.fetchCount(FetchDescriptor<SleepSession>())) ?? 0
        if sleepCount == 0 {
            let startOfToday = Calendar.current.startOfDay(for: .now)
            let wakeTime = startOfToday.addingTimeInterval(7 * 3600 + 15 * 60)
            let bedTime = wakeTime.addingTimeInterval(-(7 * 3600 + 38 * 60))
            let sleepSession = SleepSession(
                startTime: bedTime,
                endTime: wakeTime,
                deepMinutes: 88,
                lightMinutes: 242,
                remMinutes: 96,
                awakeMinutes: 22,
                sleepScore: 87,
                source: "Galaxy Fit3 (Simulación)"
            )
            context.insert(sleepSession)
        }

        let spo2Count = (try? context.fetchCount(FetchDescriptor<SpO2Record>())) ?? 0
        if spo2Count == 0 {
            context.insert(SpO2Record(timestamp: .now.addingTimeInterval(-1800), percentage: 98, source: "Galaxy Fit3 (Simulación)"))
        }

        persistTodaySteps(source: "Galaxy Fit3 (Simulación)")
        try? context.save()
    }

    // MARK: - Helper to Register Scanned Peripherals

    private func registerDiscoveredPeripheral(_ peripheral: CBPeripheral, rssi: Int, advertisedUUIDs: [String]) {
        let rawName = peripheral.name ?? "Dispositivo BLE (\(peripheral.identifier.uuidString.prefix(4)))"
        let upper = rawName.uppercased()
        let isLikelyFit3 = upper.contains("FIT3")
            || upper.contains("FIT 3")
            || upper.contains("GALAXY")
            || upper.contains("SM-R390")
            || upper.contains("SAMSUNG")
            || advertisedUUIDs.contains(where: { GATT.samsungKnownServiceHints.contains($0.uppercased()) })

        guard showAllBLEDevicesInScanner || isLikelyFit3 || peripheral.name != nil else {
            return
        }

        peripheralCache[peripheral.identifier] = peripheral
        let item = ScannedPeripheralItem(
            id: peripheral.identifier,
            name: rawName,
            rssi: rssi == 127 ? -65 : rssi,
            isLikelyFit3: isLikelyFit3,
            advertisedServiceUUIDs: advertisedUUIDs,
            lastSeen: .now
        )

        if let idx = scannedPeripherals.firstIndex(where: { $0.id == item.id }) {
            scannedPeripherals[idx] = item
        } else {
            scannedPeripherals.append(item)
            scannedPeripherals.sort { lhs, rhs in
                if lhs.isLikelyFit3 != rhs.isLikelyFit3 {
                    return lhs.isLikelyFit3 && !rhs.isLikelyFit3
                }
                return lhs.rssi > rhs.rssi
            }
        }
    }

    private func describeCharacteristicProperties(_ props: CBCharacteristicProperties) -> String {
        var list: [String] = []
        if props.contains(.read) { list.append("Read") }
        if props.contains(.write) { list.append("Write") }
        if props.contains(.writeWithoutResponse) { list.append("WriteNoResp") }
        if props.contains(.notify) { list.append("Notify") }
        if props.contains(.indicate) { list.append("Indicate") }
        if props.contains(.authenticatedSignedWrites) { list.append("AuthWrite") }
        if props.contains(.notifyEncryptionRequired) { list.append("EncNotify") }
        return list.isEmpty ? "Ninguna" : list.joined(separator: ", ")
    }

    private func humanReadableServiceName(for uuid: CBUUID) -> (name: String, isProprietary: Bool) {
        let code = uuid.uuidString.uppercased()
        switch code {
        case "180D": return ("Heart Rate Service (GATT)", false)
        case "180F": return ("Battery Service (GATT)", false)
        case "180A": return ("Device Information (GATT)", false)
        case "1814": return ("Running Speed & Cadence (GATT)", false)
        case "1802": return ("Immediate Alert / Find Band (GATT)", false)
        case "1805": return ("Current Time Service (GATT)", false)
        case "1800": return ("Generic Access", false)
        case "1801": return ("Generic Attribute", false)
        default:
            return ("Samsung Proprietary Service (\(code.prefix(8)))", true)
        }
    }

    private func humanReadableCharacteristicName(for uuid: CBUUID) -> String {
        let code = uuid.uuidString.uppercased()
        switch code {
        case "2A37": return "Heart Rate Measurement"
        case "2A38": return "Body Sensor Location"
        case "2A19": return "Battery Level"
        case "2A29": return "Manufacturer Name"
        case "2A24": return "Model Number"
        case "2A25": return "Serial Number"
        case "2A26": return "Firmware Revision"
        case "2A27": return "Hardware Revision"
        case "2A53": return "RSC Measurement (Cadence/Speed)"
        case "2A06": return "Alert Level (Vibración)"
        case "2A2B": return "Current Time"
        default:
            return "Characteristic \(code.prefix(8))"
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            self.bluetoothPoweredOn = (state == .poweredOn)
            guard !self.isMockModeEnabled else { return }

            switch state {
            case .poweredOn:
                self.statusBannerMessage = "Bluetooth activo. Buscando Galaxy Fit 3 guardada..."
                self.attemptAutoReconnectIfSaved()
            case .poweredOff:
                self.connectionState = .disconnected
                self.statusBannerMessage = "Bluetooth desactivado en el iPhone."
            case .unauthorized:
                self.connectionState = .disconnected
                self.statusBannerMessage = "Permiso Bluetooth denegado. Actívalo en Ajustes."
            case .unsupported:
                self.connectionState = .disconnected
                self.statusBannerMessage = "Este dispositivo no soporta Bluetooth LE."
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let first = restoredPeripherals.first {
            Task { @MainActor in
                self.activePeripheral = first
                first.delegate = self
                self.connectedDeviceName = first.name ?? "Galaxy Fit3"
                if first.state == .connected {
                    self.connectionState = .connected
                    self.statusBannerMessage = "Conexión restaurada en segundo plano con \(self.connectedDeviceName)."
                    first.discoverServices(nil)
                } else {
                    central.connect(first, options: [
                        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                        CBConnectPeripheralOptionNotifyOnNotificationKey: true
                    ])
                }
            }
        }
    }

    @MainActor
    private func attemptAutoReconnectIfSaved() {
        guard let uuidString = UserDefaults.standard.string(forKey: savedPeripheralUUIDKey),
              let uuid = UUID(uuidString: uuidString) else {
            return
        }
        let known = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        if let peripheral = known.first {
            activePeripheral = peripheral
            peripheral.delegate = self
            connectionState = .connecting
            statusBannerMessage = "Reconectando automáticamente con \(peripheral.name ?? "Galaxy Fit 3")..."
            centralManager.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                CBConnectPeripheralOptionNotifyOnNotificationKey: true
            ])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        let rssiInt = RSSI.intValue
        Task { @MainActor in
            self.registerDiscoveredPeripheral(peripheral, rssi: rssiInt, advertisedUUIDs: serviceUUIDs)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.connectionState = .connected
            self.connectedDeviceName = peripheral.name ?? "Samsung Galaxy Fit3"
            self.statusBannerMessage = "Conectado a \(self.connectedDeviceName). Descubriendo servicios GATT..."
            self.discoveredServices.removeAll()
            self.characteristicsMap.removeAll()
            peripheral.delegate = self
            peripheral.readRSSI()
            // Descubrimos TODOS los servicios (estándar + propietarios de Samsung)
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        let errDesc = error?.localizedDescription ?? "Error desconocido"
        Task { @MainActor in
            self.connectionState = .disconnected
            self.statusBannerMessage = "Fallo al conectar: \(errDesc)"
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        Task { @MainActor in
            guard !self.isMockModeEnabled else { return }
            self.connectionState = .connecting
            self.statusBannerMessage = "Conexión perdida. Reconectando en segundo plano..."
            // Reconexión automática persistente (CoreBluetooth completará la conexión apenas la pulsera esté en rango)
            central.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                CBConnectPeripheralOptionNotifyOnNotificationKey: true
            ])
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: (any Error)?) {
        let val = RSSI.intValue
        Task { @MainActor in
            self.lastRSSI = val
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        guard let characteristics = service.characteristics else { return }
        let serviceUUIDStr = service.uuid.uuidString

        Task { @MainActor in
            let meta = self.humanReadableServiceName(for: service.uuid)
            var charInfos: [DiscoveredCharacteristicInfo] = []

            for char in characteristics {
                let charUUIDStr = char.uuid.uuidString
                let key = "\(serviceUUIDStr):\(charUUIDStr)"
                self.characteristicsMap[key] = char

                let canRead = char.properties.contains(.read)
                let canWrite = char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse)
                let canNotify = char.properties.contains(.notify) || char.properties.contains(.indicate)

                // Lectura inicial de características legibles
                if canRead {
                    peripheral.readValue(for: char)
                }

                // Suscripción automática a servicios estándar y (si está activo) a UUIDs propietarios de Samsung
                let isStandardNotify = (char.uuid == GATT.heartRateMeasurement)
                    || (char.uuid == GATT.batteryLevel)
                    || (char.uuid == GATT.rscMeasurement)
                    || (char.uuid == GATT.currentTimeChar)

                if canNotify && (isStandardNotify || self.autoSubscribeProprietaryUUIDs) {
                    peripheral.setNotifyValue(true, for: char)
                }

                charInfos.append(
                    DiscoveredCharacteristicInfo(
                        serviceUUID: serviceUUIDStr,
                        uuid: charUUIDStr,
                        name: self.humanReadableCharacteristicName(for: char.uuid),
                        propertiesDescription: self.describeCharacteristicProperties(char.properties),
                        canRead: canRead,
                        canWrite: canWrite,
                        canNotify: canNotify,
                        isNotifying: char.isNotifying,
                        lastHexValue: "—",
                        lastUTF8Value: "",
                        lastUpdated: nil
                    )
                )
            }

            let serviceInfo = DiscoveredServiceInfo(
                uuid: serviceUUIDStr,
                name: meta.name,
                isProprietarySamsung: meta.isProprietary,
                characteristics: charInfos
            )

            if let idx = self.discoveredServices.firstIndex(where: { $0.uuid == serviceUUIDStr }) {
                self.discoveredServices[idx] = serviceInfo
            } else {
                self.discoveredServices.append(serviceInfo)
            }

            self.isBondedForANCS = true
            self.statusBannerMessage = "GATT listo (\(self.discoveredServices.count) servicios). Sniffer BLE activo."
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        let serviceUUID = characteristic.service?.uuid.uuidString ?? "UNKNOWN"
        let charUUID = characteristic.uuid.uuidString

        Task { @MainActor in
            self.handleIncomingCharacteristicData(
                serviceUUID: serviceUUID,
                characteristicUUID: charUUID,
                data: data
            )
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        let serviceUUID = characteristic.service?.uuid.uuidString ?? "UNKNOWN"
        let charUUID = characteristic.uuid.uuidString
        let isNotifying = characteristic.isNotifying

        Task { @MainActor in
            guard let sIdx = self.discoveredServices.firstIndex(where: { $0.uuid == serviceUUID }),
                  let cIdx = self.discoveredServices[sIdx].characteristics.firstIndex(where: { $0.uuid == charUUID }) else {
                return
            }
            self.discoveredServices[sIdx].characteristics[cIdx].isNotifying = isNotifying
        }
    }
}
