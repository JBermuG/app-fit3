import SwiftUI
import UIKit
import CoreBluetooth

// MARK: - ShareSheet Compatible con iOS 15+ (UIActivityViewController)
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Vista Principal con 4 Pestañas (TabView)
struct ContentView: View {
    @StateObject private var bleManager = BLEManager()
    @ObservedObject private var storageManager = BiometricStorageManager.shared

    var body: some View {
        TabView {
            DashboardTabView(bleManager: bleManager, storageManager: storageManager)
                .tabItem {
                    Label("Dashboard", systemImage: "applewatch.radiowaves.left.and.right")
                }

            HistoryCSVTabView(storageManager: storageManager)
                .tabItem {
                    Label("Historial y CSV", systemImage: "heart.text.square.fill")
                }

            GATTInspectorTabView(bleManager: bleManager)
                .tabItem {
                    Label("Inspector GATT", systemImage: "cpu")
                }

            BLEConsoleTabView(bleManager: bleManager)
                .tabItem {
                    Label("Consola BLE", systemImage: "terminal.fill")
                }
        }
    }
}

// MARK: - PESTAÑA 1: Dashboard
struct DashboardTabView: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var storageManager: BiometricStorageManager

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    connectionHeaderCard
                    metricsCardsRow
                    actionsCard
                    scannerSectionCard
                }
                .padding()
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Galaxy Fit 3 BLE")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var connectionHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(bleManager.isConnected ? Color.green : (bleManager.isScanning ? Color.orange : Color.red))
                    .frame(width: 12, height: 12)
                Text(bleManager.connectionStatusText)
                    .font(.headline)
                Spacer()
                if bleManager.isConnected {
                    Button(role: .destructive) {
                        bleManager.disconnect()
                    } label: {
                        Text("Desconectar")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.15))
                            .cornerRadius(8)
                    }
                }
            }

            Text("Estado CoreBluetooth: \(bleManager.bluetoothStateText)")
                .font(.caption)
                .foregroundColor(.secondary)

            if bleManager.isConnected {
                Text("Dispositivo activo: \(bleManager.connectedDeviceName) • Servicios/Caract.: \(bleManager.gattCharacteristics.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private var metricsCardsRow: some View {
        HStack(spacing: 14) {
            // Tarjeta de Frecuencia Cardíaca en Tiempo Real
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.red)
                    Text("Pulso Actual")
                        .font(.subheadline.bold())
                        .foregroundColor(.secondary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(bleManager.currentBPM.map { "\($0)" } ?? "--")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    Text("BPM")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }

                Text("Muestras guardadas: \(storageManager.records.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)

            // Tarjeta de Batería
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: batteryIconName(for: bleManager.batteryLevel))
                        .foregroundColor(.green)
                    Text("Batería Fit 3")
                        .font(.subheadline.bold())
                        .foregroundColor(.secondary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(bleManager.batteryLevel.map { "\($0)" } ?? "--")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    Text("%")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }

                Text("Servicio GATT 180F / 2A19")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)
        }
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Acciones del Reloj (SM-R390)")
                .font(.subheadline.bold())
                .foregroundColor(.secondary)

            Button {
                bleManager.syncTimeToWatch()
            } label: {
                HStack {
                    Image(systemName: "clock.arrow.2.circlepath")
                    Text("Sincronizar Hora con el Reloj")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(bleManager.isConnected ? Color.blue : Color.gray.opacity(0.4))
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(!bleManager.isConnected)

            Button {
                bleManager.forcePairingAndANCS()
            } label: {
                HStack {
                    Image(systemName: "bell.badge.fill")
                    Text("Forzar Emparejamiento (ANCS / Notificaciones iOS)")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color.indigo.opacity(0.15))
                .foregroundColor(.indigo)
                .cornerRadius(10)
            }
            .disabled(!bleManager.isConnected)

            Text("Estado Sync Hora: \(bleManager.lastSyncTimeStatus)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private var scannerSectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Escáner de Dispositivos BLE")
                    .font(.headline)
                Spacer()
                Button {
                    if bleManager.isScanning {
                        bleManager.stopScanning()
                    } else {
                        bleManager.startScanning()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if bleManager.isScanning {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                        Text(bleManager.isScanning ? "Detener" : "Escanear")
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(bleManager.isScanning ? Color.orange : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            }

            Toggle("Filtrar solo 'Galaxy' / 'Fit 3'", isOn: $bleManager.filterGalaxyOnly)
                .font(.subheadline)
                .onChange(of: bleManager.filterGalaxyOnly) { _ in
                    if bleManager.isScanning {
                        bleManager.startScanning()
                    }
                }

            Divider()

            if bleManager.discoveredDevices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "applewatch.watchface")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(bleManager.isScanning
                         ? "Buscando Samsung Galaxy Fit 3 cerca..."
                         : "Pulsa 'Escanear' para descubrir tu Galaxy Fit 3 (o desactiva el filtro para ver todos los periféricos).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ForEach(bleManager.discoveredDevices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name)
                                .font(.body.weight(.semibold))
                            Text(device.id.uuidString)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(device.rssi) dBm")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .padding(.trailing, 4)

                        Button {
                            bleManager.connect(to: device)
                        } label: {
                            Text(bleManager.connectedPeripheral?.identifier == device.id && bleManager.isConnected ? "Conectado" : "Conectar")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(bleManager.connectedPeripheral?.identifier == device.id && bleManager.isConnected ? Color.green : Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private func batteryIconName(for level: Int?) -> String {
        guard let lvl = level else { return "battery.0" }
        switch lvl {
        case 0..<20: return "battery.25"
        case 20..<60: return "battery.50"
        case 60..<90: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - PESTAÑA 2: Historial y CSV
struct HistoryCSVTabView: View {
    @ObservedObject var storageManager: BiometricStorageManager
    @State private var isShowingShareSheet = false
    @State private var isShowingClearConfirmation = false

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                headerControlsSection
                Divider()

                if storageManager.records.isEmpty {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("No hay lecturas de pulso registradas aún")
                            .font(.headline)
                        Text("Las lecturas del servicio 180D (2A37) se guardarán automáticamente en galaxy_fit3_heartrate.csv.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(storageManager.records) { record in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(record.bpm) BPM")
                                        .font(.headline)
                                        .foregroundColor(.red)
                                    Text(dateFormatter.string(from: record.timestamp))
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if let battery = record.batteryLevel {
                                    Label("\(battery)%", systemImage: "battery.100")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .navigationTitle("Historial y CSV")
            .sheet(isPresented: $isShowingShareSheet) {
                if let csvURL = storageManager.getCSVFileURL() {
                    ShareSheet(activityItems: [csvURL])
                }
            }
            .alert("¿Borrar todo el historial local?", isPresented: $isShowingClearConfirmation) {
                Button("Cancelar", role: .cancel) {}
                Button("Borrar Todo", role: .destructive) {
                    storageManager.clearHistory()
                }
            } message: {
                Text("Se eliminarán todos los registros de memoria y se reiniciará el archivo galaxy_fit3_heartrate.csv.")
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var headerControlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total de muestras registradas")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(storageManager.records.count) lecturas")
                        .font(.title3.bold())
                }
                Spacer()

                Button {
                    isShowingShareSheet = true
                } label: {
                    Label("Exportar CSV", systemImage: "square.and.arrow.up")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }

                Button(role: .destructive) {
                    isShowingClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .padding(8)
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .cornerRadius(10)
                }
            }

            Divider()

            Toggle(isOn: $storageManager.useAppleHealth) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Intentar sincronizar con Apple Health (Opcional)")
                        .font(.subheadline.weight(.medium))
                    Text(storageManager.healthKitStatusMessage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
    }
}

// MARK: - PESTAÑA 3: Inspector GATT
struct GATTInspectorTabView: View {
    @ObservedObject var bleManager: BLEManager
    @State private var hexInputs: [String: String] = [:]

    private var groupedByService: [(serviceUUID: String, serviceName: String, items: [GATTCharacteristicItem])] {
        let dict = Dictionary(grouping: bleManager.gattCharacteristics, by: { $0.serviceUUID })
        return dict.keys.sorted().map { key in
            let items = dict[key] ?? []
            let name = items.first?.serviceName ?? key
            return (serviceUUID: key, serviceName: name, items: items.sorted { $0.uuidString < $1.uuidString })
        }
    }

    var body: some View {
        NavigationView {
            Group {
                if bleManager.gattCharacteristics.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "cpu")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("Sin Servicios GATT Descubiertos")
                            .font(.headline)
                        Text("Conéctate al Samsung Galaxy Fit 3 desde la pestaña Dashboard para inspeccionar todos sus servicios estándar y propietarios de 128 bits.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    List {
                        ForEach(groupedByService, id: \.serviceUUID) { serviceGroup in
                            Section(header: Text("\(serviceGroup.serviceName) [\(serviceGroup.items.count)]")) {
                                ForEach(serviceGroup.items) { item in
                                    GATTCharacteristicRowView(
                                        item: item,
                                        hexInput: Binding(
                                            get: { hexInputs[item.id] ?? "" },
                                            set: { hexInputs[item.id] = $0 }
                                        ),
                                        onRead: { bleManager.readCharacteristic(item) },
                                        onToggleNotify: { bleManager.toggleNotify(for: item) },
                                        onWriteHex: { hex in
                                            bleManager.writeHexCommand(hex, to: item.characteristic)
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(InsetGroupedListStyle())
                }
            }
            .navigationTitle("Inspector GATT (\(bleManager.gattCharacteristics.count))")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct GATTCharacteristicRowView: View {
    let item: GATTCharacteristicItem
    @Binding var hexInput: String
    let onRead: () -> Void
    let onToggleNotify: () -> Void
    let onWriteHex: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.characteristicName)
                        .font(.subheadline.bold())
                    Text(item.uuidString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(item.shortPermissionsBadge)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(.accentColor)
                    .cornerRadius(6)
            }

            Text("Propiedades: \(item.propertiesText)")
                .font(.caption2)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text("HEX:")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Text(item.lastHexValue)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                }
                HStack(alignment: .top) {
                    Text("ASCII:")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Text(item.lastASCIIValue)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.tertiarySystemGroupedBackground))
            .cornerRadius(8)

            // Botones de Read y Notify
            HStack(spacing: 10) {
                if item.canRead {
                    Button(action: onRead) {
                        Label("Leer (Read)", systemImage: "arrow.down.circle")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(8)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }

                if item.canNotify {
                    Button(action: onToggleNotify) {
                        Label(
                            item.isNotifying ? "Notify: ON" : "Notify: OFF",
                            systemImage: item.isNotifying ? "bell.fill" : "bell.slash"
                        )
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(item.isNotifying ? Color.green.opacity(0.2) : Color.gray.opacity(0.15))
                        .foregroundColor(item.isNotifying ? .green : .primary)
                        .cornerRadius(8)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
            }

            // Campo para enviar comando en Hexadecimal
            HStack(spacing: 8) {
                TextField("Comando Hex (ej. 0102FF)", text: $hexInput)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .disableAutocorrection(true)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                Button {
                    onWriteHex(hexInput)
                } label: {
                    Text("Enviar TX")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(BorderlessButtonStyle())
                .disabled(hexInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - PESTAÑA 4: Consola BLE
struct BLEConsoleTabView: View {
    @ObservedObject var bleManager: BLEManager
    @State private var selectedFilter: LogEventType? = nil
    @State private var copiedBannerVisible = false

    private var filteredLogs: [LogEntry] {
        guard let filter = selectedFilter else { return bleManager.logs }
        return bleManager.logs.filter { $0.type == filter }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                consoleToolbar
                Divider()

                if filteredLogs.isEmpty {
                    Spacer()
                    Text("No hay eventos registrados en la consola.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    List(filteredLogs) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.type.rawValue)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(badgeColor(for: entry.type).opacity(0.2))
                                .foregroundColor(badgeColor(for: entry.type))
                                .cornerRadius(4)

                            Text(entry.formattedLine)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .navigationTitle("Consola BLE (\(filteredLogs.count))")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var consoleToolbar: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(title: "Todos", type: nil)
                    ForEach(LogEventType.allCases, id: \.self) { type in
                        filterChip(title: type.rawValue, type: type)
                    }
                }
            }

            HStack {
                Button {
                    let fullText = bleManager.logs
                        .reversed()
                        .map { $0.formattedLine }
                        .joined(separator: "\n")
                    UIPasteboard.general.string = fullText
                    copiedBannerVisible = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedBannerVisible = false
                    }
                } label: {
                    Label(
                        copiedBannerVisible ? "¡Log Copiado!" : "Copiar Log al Portapapeles",
                        systemImage: copiedBannerVisible ? "checkmark.circle.fill" : "doc.on.doc"
                    )
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(copiedBannerVisible ? Color.green : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }

                Spacer()

                Button(role: .destructive) {
                    bleManager.clearLogs()
                } label: {
                    Label("Limpiar", systemImage: "trash")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
    }

    private func filterChip(title: String, type: LogEventType?) -> some View {
        let isSelected = selectedFilter == type
        return Button {
            selectedFilter = type
        } label: {
            Text(title)
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.gray.opacity(0.15))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(14)
        }
    }

    private func badgeColor(for type: LogEventType) -> Color {
        switch type {
        case .INFO: return .blue
        case .RX: return .green
        case .TX: return .orange
        case .ERROR: return .red
        }
    }
}
