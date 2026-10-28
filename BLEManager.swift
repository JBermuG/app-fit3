import Foundation
import CoreBluetooth
import Combine

final class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // MARK: - Propiedades Publicadas (Actualizadas siempre en DispatchQueue.main.async)
    @Published var bluetoothStateText: String = "Inicializando Bluetooth..."
    @Published var isBluetoothPoweredOn: Bool = false
    @Published var isScanning: Bool = false
    @Published var isConnected: Bool = false
    @Published var connectionStatusText: String = "Desconectado"
    @Published var connectedDeviceName: String = "Ninguno"
    @Published var filterGalaxyOnly: Bool = true

    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var gattCharacteristics: [GATTCharacteristicItem] = []
    @Published var logs: [LogEntry] = []

    @Published var currentBPM: Int? = nil
    @Published var batteryLevel: Int? = nil
    @Published var lastSyncTimeStatus: String = "Sin sincronizar"

    // MARK: - Retención Fuerte de CoreBluetooth (Regla 5)
    private var centralManager: CBCentralManager!
    var connectedPeripheral: CBPeripheral?

    // Referencia a la característica 2A2B (Current Time) si el reloj la expone
    private var currentTimeCharacteristic: CBCharacteristic?
    private var userInitiatedDisconnect: Bool = false

    // MARK: - UUIDs Estándar Bluetooth SIG
    private let heartRateServiceUUID = CBUUID(string: "180D")
    private let heartRateMeasurementUUID = CBUUID(string: "2A37")
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private let currentTimeServiceUUID = CBUUID(string: "1805")
    private let currentTimeCharUUID = CBUUID(string: "2A2B")
    private let deviceInfoServiceUUID = CBUUID(string: "180A")
    private let hidServiceUUID = CBUUID(string: "1812")

    override init() {
        super.init()

        /*
         NOTA SOBRE RESTAURACIÓN EN SEGUNDO PLANO (Regla 4):
         Por defecto NO incluimos `CBCentralManagerOptionRestoreIdentifierKey` para evitar
         un crash inmediato (NSInternalInconsistencyException) si aún no se ha activado
         `UIBackgroundModes -> bluetooth-central` en el archivo Info.plist de Xcode.

         Cuando hayas añadido `bluetooth-central` en Info.plist ("Required background modes"),
         puedes reemplazar la inicialización de abajo por:
         let options: [String: Any] = [
             CBCentralManagerOptionShowPowerAlertKey: true,
             CBCentralManagerOptionRestoreIdentifierKey: "com.galaxyfit3.centralManagerRestoreID"
         ]
         */
        let options: [String: Any] = [
            CBCentralManagerOptionShowPowerAlertKey: true
        ]
        self.centralManager = CBCentralManager(delegate: self, queue: nil, options: options)
        appendLog(.INFO, "BLEManager inicializado correctamente.")
    }

    // MARK: - Escaneo de Dispositivos BLE
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            appendLog(.ERROR, "No se puede escanear: Bluetooth no está encendido (\(bluetoothStateText)).")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.discoveredDevices.removeAll()
            self?.isScanning = true
        }

        // 1. Recuperar periféricos ya conectados al sistema iOS (ej. emparejados en Ajustes > Bluetooth)
        let knownServices = [
            heartRateServiceUUID,
            batteryServiceUUID,
            currentTimeServiceUUID,
            deviceInfoServiceUUID,
            hidServiceUUID
        ]
        let systemConnected = centralManager.retrieveConnectedPeripherals(withServices: knownServices)
        for peripheral in systemConnected {
            let name = peripheral.name ?? "Dispositivo Conectado iOS"
            registerDiscoveredPeripheral(peripheral, name: name, rssi: -45)
            appendLog(.INFO, "Detectado periférico ya enlazado a iOS: \(name) [\(peripheral.identifier.uuidString)]")
        }

        // 2. Escaneo activo de anuncios BLE en el aire
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        appendLog(.INFO, "Escaneo BLE iniciado (Filtro Galaxy/Fit3: \(filterGalaxyOnly ? "ACTIVO" : "TODOS")).")
    }

    func stopScanning() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.stopScan()
        DispatchQueue.main.async { [weak self] in
            self?.isScanning = false
        }
        appendLog(.INFO, "Escaneo BLE detenido.")
    }

    private func matchesFilter(name: String) -> Bool {
        guard filterGalaxyOnly else { return true }
        let upper = name.uppercased()
        return upper.contains("FIT3")
            || upper.contains("FIT 3")
            || upper.contains("GALAXY")
            || upper.contains("SM-R390")
            || upper.contains("SAMSUNG")
    }

    private func registerDiscoveredPeripheral(_ peripheral: CBPeripheral, name: String, rssi: Int) {
        guard matchesFilter(name: name) else { return }
        let cleanRSSI = (rssi == 127 || rssi == 0) ? -60 : rssi
        let item = DiscoveredDevice(peripheral: peripheral, name: name, rssi: cleanRSSI)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let index = self.discoveredDevices.firstIndex(where: { $0.id == item.id }) {
                self.discoveredDevices[index] = item
            } else {
                self.discoveredDevices.append(item)
                self.discoveredDevices.sort { $0.rssi > $1.rssi }
            }
        }
    }

    // MARK: - Conexión y Desconexión (Regla 5)
    func connect(to device: DiscoveredDevice) {
        stopScanning()
        userInitiatedDisconnect = false

        // Retención fuerte explícita en `connectedPeripheral` antes de conectar
        self.connectedPeripheral = device.peripheral
        self.connectedPeripheral?.delegate = self

        DispatchQueue.main.async { [weak self] in
            self?.connectionStatusText = "Conectando a \(device.name)..."
            self?.connectedDeviceName = device.name
        }

        let connectOptions: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ]

        appendLog(.INFO, "Iniciando conexión con \(device.name) (\(device.id.uuidString))...")
        centralManager.connect(device.peripheral, options: connectOptions)
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        userInitiatedDisconnect = true
        appendLog(.INFO, "Desconectando manualmente de \(peripheral.name ?? "dispositivo")...")
        centralManager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - Forzado de Emparejamiento (Bonding / ANCS / AMS)
    func forcePairingAndANCS() {
        guard let peripheral = connectedPeripheral else {
            appendLog(.ERROR, "No hay reloj conectado para forzar emparejamiento ANCS.")
            return
        }

        appendLog(.INFO, "Solicitando lectura/suscripción en características protegidas para forzar diálogo de emparejamiento (Bonding/ANCS)...")
        guard let services = peripheral.services else {
            peripheral.discoverServices(nil)
            return
        }

        for service in services {
            guard let characteristics = service.characteristics else { continue }
            for characteristic in characteristics {
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                if characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
            }
        }
    }

    // MARK: - Sincronización de Hora (Current Time Service 1805 -> 2A2B)
    func syncTimeToWatch() {
        guard let peripheral = connectedPeripheral, isConnected else {
            appendLog(.ERROR, "No se puede sincronizar la hora: el reloj no está conectado.")
            DispatchQueue.main.async { [weak self] in
                self?.lastSyncTimeStatus = "Error: Reloj desconectado"
            }
            return
        }

        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: now)

        let year = UInt16(components.year ?? 2026)
        let yearLSB = UInt8(year & 0xFF)
        let yearMSB = UInt8((year >> 8) & 0xFF)
        let month = UInt8(components.month ?? 1)
        let day = UInt8(components.day ?? 1)
        let hour = UInt8(components.hour ?? 0)
        let minute = UInt8(components.minute ?? 0)
        let second = UInt8(components.second ?? 0)

        // Estándar Bluetooth SIG Current Time: Lunes = 1 ... Domingo = 7
        // Calendar.weekday en iOS: Domingo = 1, Lunes = 2 ... Sábado = 7
        let iosWeekday = components.weekday ?? 2
        let gattDayOfWeek = UInt8(iosWeekday == 1 ? 7 : iosWeekday - 1)
        let fractions256: UInt8 = 0
        let adjustReason: UInt8 = 1 // Manual Time Update

        // Paquete exacto de 10 bytes del estándar GATT Current Time (0x2A2B)
        let packetBytes: [UInt8] = [
            yearLSB,
            yearMSB,
            month,
            day,
            hour,
            minute,
            second,
            gattDayOfWeek,
            fractions256,
            adjustReason
        ]
        let packetData = Data(packetBytes)

        // Buscar característica 2A2B descubierta
        let targetChar = currentTimeCharacteristic
            ?? gattCharacteristics.first(where: { $0.uuidString.uppercased() == "2A2B" })?.characteristic

        guard let characteristic = targetChar else {
            appendLog(.ERROR, "Característica Current Time (2A2B) no expuesta como servidor GATT por el reloj. Payload generado (10 bytes): \(packetData.hexString)")
            DispatchQueue.main.async { [weak self] in
                self?.lastSyncTimeStatus = "2A2B no expuesta por el reloj (Payload: \(packetData.hexString))"
            }
            return
        }

        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(packetData, for: characteristic, type: writeType)
        appendLog(.TX, "Sync Hora -> [2A2B] (10 bytes): \(packetData.hexString)")

        let timeFormatted = String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
        DispatchQueue.main.async { [weak self] in
            self?.lastSyncTimeStatus = "Hora enviada (\(timeFormatted))"
        }
    }

    // MARK: - Inspector GATT: Lectura, Notify y Escritura Hexadecimal
    func readCharacteristic(_ item: GATTCharacteristicItem) {
        guard let peripheral = connectedPeripheral else { return }
        guard item.canRead else {
            appendLog(.ERROR, "La característica [\(item.uuidString)] no soporta lectura (Read).")
            return
        }
        appendLog(.INFO, "Solicitando lectura de [\(item.uuidString)]...")
        peripheral.readValue(for: item.characteristic)
    }

    func toggleNotify(for item: GATTCharacteristicItem) {
        guard let peripheral = connectedPeripheral else { return }
        guard item.canNotify else {
            appendLog(.ERROR, "La característica [\(item.uuidString)] no soporta Notify/Indicate.")
            return
        }
        let targetState = !item.characteristic.isNotifying
        appendLog(.INFO, "Cambiando Notify=\(targetState) en [\(item.uuidString)]...")
        peripheral.setNotifyValue(targetState, for: item.characteristic)
    }

    func writeHexCommand(_ hexString: String, to characteristic: CBCharacteristic) {
        guard let peripheral = connectedPeripheral, isConnected else {
            appendLog(.ERROR, "No se puede escribir comando Hex: ningún periférico conectado.")
            return
        }

        guard let data = Data(hexString: hexString) else {
            appendLog(.ERROR, "Formato Hex inválido: '\(hexString)'. Usa pares hexadecimales (ej. 0102FF).")
            return
        }

        let props = characteristic.properties
        let writeType: CBCharacteristicWriteType
        if props.contains(.write) {
            writeType = .withResponse
        } else if props.contains(.writeWithoutResponse) {
            writeType = .withoutResponse
        } else {
            appendLog(.WARN_OR_ERR, "[\(characteristic.uuid.uuidString)] no declara permiso Write; intentando .withResponse...")
            writeType = .withResponse
        }

        peripheral.writeValue(data, for: characteristic, type: writeType)
        appendLog(.TX, "TX -> [\(characteristic.uuid.uuidString)] (\(data.count) bytes): \(data.hexString)")
    }

    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateDesc: String
        let poweredOn: Bool

        switch central.state {
        case .poweredOn:
            stateDesc = "Bluetooth Encendido (Listo)"
            poweredOn = true
        case .poweredOff:
            stateDesc = "Bluetooth Apagado"
            poweredOn = false
        case .unauthorized:
            stateDesc = "Sin Permiso Bluetooth (Revisa Ajustes)"
            poweredOn = false
        case .unsupported:
            stateDesc = "BLE No Soportado en este Dispositivo"
            poweredOn = false
        case .resetting:
            stateDesc = "Reiniciando controlador Bluetooth..."
            poweredOn = false
        case .unknown:
            stateDesc = "Estado Bluetooth Desconocido"
            poweredOn = false
        @unknown default:
            stateDesc = "Estado No Reconocido"
            poweredOn = false
        }

        DispatchQueue.main.async { [weak self] in
            self?.bluetoothStateText = stateDesc
            self?.isBluetoothPoweredOn = poweredOn
            if !poweredOn {
                self?.isScanning = false
                self?.isConnected = false
            }
        }

        appendLog(.INFO, "Estado de CoreBluetooth: \(stateDesc)")
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rawName = peripheral.name ?? advName ?? ""
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Mostramos solo dispositivos con nombre legible
        guard !trimmedName.isEmpty else { return }
        registerDiscoveredPeripheral(peripheral, name: trimmedName, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? connectedDeviceName
        appendLog(.INFO, "Conectado exitosamente a \(name). Descubriendo todos los servicios GATT...")

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = true
            self?.connectionStatusText = "Conectado a \(name)"
            self?.connectedDeviceName = name
            self?.gattCharacteristics.removeAll()
        }

        peripheral.delegate = self
        // Descubrir TODOS los servicios (estándar + propietarios de 128 bits de Samsung)
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let errorMsg = error?.localizedDescription ?? "Error desconocido"
        appendLog(.ERROR, "Fallo al conectar con \(peripheral.name ?? "dispositivo"): \(errorMsg)")

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.connectionStatusText = "Fallo de conexión: \(errorMsg)"
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let name = peripheral.name ?? connectedDeviceName
        if let error = error {
            appendLog(.ERROR, "Desconectado de \(name): \(error.localizedDescription)")
        } else {
            appendLog(.INFO, "Desconectado de \(name).")
        }

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.currentBPM = nil
            self?.connectionStatusText = self?.userInitiatedDisconnect == true
                ? "Desconectado manualmente"
                : "Reconectando a \(name)..."
        }

        // Reconexión automática en segundo plano salvo desconexión manual
        if !userInitiatedDisconnect {
            self.connectedPeripheral = peripheral
            self.connectedPeripheral?.delegate = self
            appendLog(.INFO, "Activando reconexión automática persistente con \(name)...")
            let connectOptions: [String: Any] = [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                CBConnectPeripheralOptionNotifyOnNotificationKey: true
            ]
            central.connect(peripheral, options: connectOptions)
        }
    }

    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            appendLog(.ERROR, "Error descubriendo servicios: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            appendLog(.INFO, "No se encontraron servicios GATT en el periférico.")
            return
        }

        appendLog(.INFO, "Descubiertos \(services.count) servicios GATT. Explorando características...")
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            appendLog(.ERROR, "Error en características del servicio [\(service.uuid.uuidString)]: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            let uuidStr = characteristic.uuid.uuidString.uppercased()
            appendLog(.INFO, "Característica encontrada: [\(uuidStr)] en Servicio [\(service.uuid.uuidString)]")

            if characteristic.uuid == currentTimeCharUUID {
                self.currentTimeCharacteristic = characteristic
            }

            // Registrar en el Inspector GATT
            upsertCharacteristicItem(characteristic: characteristic, data: characteristic.value)

            // Auto-suscripción y lectura para forzar emparejamiento (Bonding/ANCS) y telemetría en vivo
            if characteristic.uuid == heartRateMeasurementUUID || characteristic.uuid == batteryLevelUUID {
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                if characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
            } else {
                // Suscribir o leer características que ayudan a desencadenar el enlace seguro con iOS
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                if characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            appendLog(.ERROR, "Error leyendo [\(characteristic.uuid.uuidString)]: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else { return }
        let uuidStr = characteristic.uuid.uuidString.uppercased()

        appendLog(.RX, "RX <- [\(uuidStr)] (\(data.count) bytes): \(data.hexString) | ASCII: \(data.asciiSafeString)")
        upsertCharacteristicItem(characteristic: characteristic, data: data)

        // Parseo binario según estándar Bluetooth SIG
        if characteristic.uuid == batteryLevelUUID {
            parseBatteryLevel(data)
        } else if characteristic.uuid == heartRateMeasurementUUID {
            parseHeartRateMeasurement(data)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuidStr = characteristic.uuid.uuidString.uppercased()
        if let error = error {
            appendLog(.ERROR, "Error al escribir en [\(uuidStr)]: \(error.localizedDescription)")
        } else {
            appendLog(.INFO, "Confirmación de escritura exitosa (ACK) desde [\(uuidStr)].")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let uuidStr = characteristic.uuid.uuidString.uppercased()
        if let error = error {
            appendLog(.ERROR, "Error Notify en [\(uuidStr)]: \(error.localizedDescription)")
        } else {
            appendLog(.INFO, "Notify en [\(uuidStr)] -> \(characteristic.isNotifying ? "ACTIVO" : "INACTIVO")")
        }
        upsertCharacteristicItem(characteristic: characteristic, data: characteristic.value)
    }

    // MARK: - Parseo Binario Estándar Bluetooth SIG
    /// 1. Batería (Servicio 180F, Característica 2A19): Leer UInt8 del byte 0 (0 a 100%)
    private func parseBatteryLevel(_ data: Data) {
        guard !data.isEmpty else { return }
        let level = Int(UInt8(data[0]))
        let clampedLevel = max(0, min(100, level))

        DispatchQueue.main.async { [weak self] in
            self?.batteryLevel = clampedLevel
        }
        appendLog(.INFO, "Nivel de batería actualizado: \(clampedLevel)%")
    }

    /// 2. Frecuencia Cardíaca (Servicio 180D, Característica 2A37)
    private func parseHeartRateMeasurement(_ data: Data) {
        guard data.count >= 2 else { return }
        let flags = data[0]
        let is16BitFormat = (flags & 0x01) != 0

        let bpm: Int
        if !is16BitFormat {
            bpm = Int(UInt8(data[1]))
        } else if data.count >= 3 {
            bpm = Int(UInt16(data[1]) | (UInt16(data[2]) << 8))
        } else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentBPM = bpm
            let currentBatterySnapshot = self.batteryLevel
            BiometricStorageManager.shared.saveHeartRate(bpm: bpm, battery: currentBatterySnapshot)
        }

        appendLog(.INFO, "Frecuencia cardíaca recibida: \(bpm) BPM")
    }

    // MARK: - Actualización Segura de Inspector GATT y Consola
    private func upsertCharacteristicItem(characteristic: CBCharacteristic, data: Data?) {
        let hex = data?.hexString ?? "--"
        let ascii = data?.asciiSafeString ?? "--"
        let now = data != nil ? Date() : nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let sUUID = characteristic.service?.uuid.uuidString ?? "UNKNOWN"
            let cUUID = characteristic.uuid.uuidString
            let itemID = "\(sUUID)_\(cUUID)"

            if let index = self.gattCharacteristics.firstIndex(where: { $0.id == itemID }) {
                let previousHex = self.gattCharacteristics[index].lastHexValue
                let previousASCII = self.gattCharacteristics[index].lastASCIIValue
                let previousDate = self.gattCharacteristics[index].lastUpdated

                let updated = GATTCharacteristicItem(
                    characteristic: characteristic,
                    lastHexValue: data != nil ? hex : previousHex,
                    lastASCIIValue: data != nil ? ascii : previousASCII,
                    lastUpdated: now ?? previousDate
                )
                self.gattCharacteristics[index] = updated
            } else {
                let newItem = GATTCharacteristicItem(
                    characteristic: characteristic,
                    lastHexValue: hex,
                    lastASCIIValue: ascii,
                    lastUpdated: now
                )
                self.gattCharacteristics.append(newItem)
            }
        }
    }

    func clearLogs() {
        DispatchQueue.main.async { [weak self] in
            self?.logs.removeAll()
        }
    }

    private func appendLog(_ type: LogEventType, _ message: String) {
        let entry = LogEntry(timestamp: Date(), type: type, message: message)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.logs.insert(entry, at: 0)
            if self.logs.count > 500 {
                self.logs.removeLast(self.logs.count - 500)
            }
        }
    }
}

private extension LogEventType {
    static var WARN_OR_ERR: LogEventType { .ERROR }
}
