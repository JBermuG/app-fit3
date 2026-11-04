import SwiftUI
import UIKit

struct BLEDiagnosticsView: View {
    @EnvironmentObject private var bleManager: BLEManager

    @State private var selectedSection: Int = 0
    @State private var selectedTagFilter: BLEHeuristicTag = .all
    @State private var uuidSearchText: String = ""

    // Envío manual de tramas Hex
    @State private var targetServiceUUID: String = "FD5A"
    @State private var targetCharacteristicUUID: String = "FEA1"
    @State private var customHexCommand: String = "FE A1 01 00"
    @State private var copiedDumpConfirmation: Bool = false

    private static let timestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    private var filteredPackets: [BLEPacketLog] {
        bleManager.packetLogs.filter { packet in
            let matchesTag = (selectedTagFilter == .all) || (packet.heuristicTag == selectedTagFilter)
            let matchesSearch = uuidSearchText.isEmpty
                || packet.characteristicUUID.localizedCaseInsensitiveContains(uuidSearchText)
                || packet.serviceUUID.localizedCaseInsensitiveContains(uuidSearchText)
                || packet.hexString.localizedCaseInsensitiveContains(uuidSearchText)
            return matchesTag && matchesSearch
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Vista de Diagnóstico", selection: $selectedSection) {
                    Text("Consola Hex en Vivo (\(bleManager.packetLogs.count))").tag(0)
                    Text("Inspector UUIDs (\(bleManager.discoveredServices.count))").tag(1)
                    Text("Mapeo & TX Hex").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 6)

                if selectedSection == 0 {
                    liveHexSnifferConsole
                } else if selectedSection == 1 {
                    gattUUIDInspectorList
                } else {
                    customMappingAndHexTransmitterView
                }
            }
            .background(SamsungHealthTheme.background.ignoresSafeArea())
            .navigationTitle("Diagnóstico BLE")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        bleManager.isSnifferPaused.toggle()
                    } label: {
                        Image(systemName: bleManager.isSnifferPaused ? "play.fill" : "pause.fill")
                            .foregroundStyle(bleManager.isSnifferPaused ? SamsungHealthTheme.orangeCalories : SamsungHealthTheme.mintSteps)
                    }

                    Button {
                        copySnifferLogToClipboard()
                    } label: {
                        Image(systemName: copiedDumpConfirmation ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundStyle(SamsungHealthTheme.cyanActivity)
                    }

                    Button(role: .destructive) {
                        bleManager.clearPacketLogs()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(SamsungHealthTheme.coralHeart)
                    }
                }
            }
        }
    }

    // MARK: - Subview 0: Live Hex & UTF-8 Sniffer Console

    private var liveHexSnifferConsole: some View {
        VStack(spacing: 10) {
            // Barra de filtro por etiqueta heurística y búsqueda UUID/Hex
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BLEHeuristicTag.allCases, id: \.self) { tag in
                        Button {
                            selectedTagFilter = tag
                        } label: {
                            Text(tag.rawValue)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(selectedTagFilter == tag
                                              ? SamsungHealthTheme.mintSteps
                                              : Color.white.opacity(0.08))
                                )
                                .foregroundStyle(selectedTagFilter == tag ? .black : .white)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filtrar por UUID (ej. FEA1, 2A37) o bytes Hex...", text: $uuidSearchText)
                    .font(.caption.monospaced())
                if !uuidSearchText.isEmpty {
                    Button {
                        uuidSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(SamsungHealthTheme.cardBackground))
            .padding(.horizontal, 16)

            if filteredPackets.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Esperando paquetes BLE entrantes...")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Conecta tu Galaxy Fit 3 o activa el Modo Simulación para inspeccionar tramas en hexadecimal, UTF-8 y enteros Little-Endian.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredPackets) { log in
                            packetLogRow(log)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func packetLogRow(_ log: BLEPacketLog) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(log.direction.rawValue)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(log.direction == .incoming
                                       ? SamsungHealthTheme.mintSteps.opacity(0.22)
                                       : SamsungHealthTheme.orangeCalories.opacity(0.25))
                    )
                    .foregroundStyle(log.direction == .incoming ? SamsungHealthTheme.mintSteps : SamsungHealthTheme.orangeCalories)

                Text("Svc: \(log.serviceUUID) • Char: \(log.characteristicUUID)")
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(.white)

                Spacer()

                Text(Self.timestampFormatter.string(from: log.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Hexadecimal payload
            HStack(alignment: .top, spacing: 6) {
                Text("HEX:")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(SamsungHealthTheme.cyanActivity)
                Text(log.hexString)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            }

            // UTF-8 + Little-Endian Integer Decoder
            HStack(spacing: 12) {
                Text("UTF8: \"\(log.utf8Preview)\"")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(log.decodedNumbersSummary)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(SamsungHealthTheme.mintSteps)
            }

            if let note = log.note {
                HStack {
                    Text(log.heuristicTag.rawValue)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .foregroundStyle(SamsungHealthTheme.purpleSleep)
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SamsungHealthTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(SamsungHealthTheme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Subview 1: GATT Services & Proprietary UUIDs Inspector

    private var gattUUIDInspectorList: some View {
        ScrollView {
            VStack(spacing: 14) {
                if bleManager.discoveredServices.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass.circle")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No hay servicios GATT descubiertos todavía.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Conecta tu Galaxy Fit 3 o activa el Modo Simulación para inspeccionar su árbol de UUIDs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                } else {
                    ForEach(bleManager.discoveredServices) { service in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text("Service 0x\(service.uuid)")
                                            .font(.subheadline.weight(.bold).monospaced())
                                            .foregroundStyle(.white)
                                        if service.isProprietarySamsung {
                                            Text("PROPIETARIO SAMSUNG")
                                                .font(.system(size: 9, weight: .heavy))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(SamsungHealthTheme.purpleSleep.opacity(0.25)))
                                                .foregroundStyle(SamsungHealthTheme.purpleSleep)
                                        }
                                    }
                                    Text(service.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }

                            Divider().overlay(Color.white.opacity(0.08))

                            ForEach(service.characteristics) { char in
                                characteristicInspectorRow(service: service, char: char)
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(SamsungHealthTheme.cardBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(SamsungHealthTheme.cardBorder, lineWidth: 1)
                                )
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func characteristicInspectorRow(service: DiscoveredServiceInfo, char: DiscoveredCharacteristicInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Char 0x\(char.uuid)")
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(SamsungHealthTheme.cyanActivity)
                Text("• \(char.name)")
                    .font(.caption)
                    .foregroundStyle(.white)
                Spacer()
                Text(char.propertiesDescription)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text("Último HEX: \(char.lastHexValue)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SamsungHealthTheme.mintSteps)

            HStack(spacing: 8) {
                if char.canRead {
                    Button {
                        bleManager.readCharacteristic(serviceUUID: service.uuid, characteristicUUID: char.uuid)
                    } label: {
                        Text("Read")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                            .foregroundStyle(.white)
                    }
                }

                if char.canNotify {
                    Button {
                        bleManager.toggleNotification(serviceUUID: service.uuid, characteristicUUID: char.uuid)
                    } label: {
                        Text(char.isNotifying ? "Notify ON" : "Notify OFF")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(char.isNotifying
                                               ? SamsungHealthTheme.mintSteps.opacity(0.25)
                                               : Color.white.opacity(0.1))
                            )
                            .foregroundStyle(char.isNotifying ? SamsungHealthTheme.mintSteps : .white)
                    }
                }

                Button {
                    bleManager.customStepsCharacteristicUUID = char.uuid
                } label: {
                    Text(bleManager.customStepsCharacteristicUUID.uppercased() == char.uuid.uppercased() ? "✓ UUID Pasos" : "Mapear Pasos")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .foregroundStyle(SamsungHealthTheme.orangeCalories)
                }

                Button {
                    bleManager.customSleepCharacteristicUUID = char.uuid
                } label: {
                    Text(bleManager.customSleepCharacteristicUUID.uppercased() == char.uuid.uppercased() ? "✓ UUID Sueño" : "Mapear Sueño")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .foregroundStyle(SamsungHealthTheme.purpleSleep)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
    }

    // MARK: - Subview 2: Custom UUID Mapper & Manual Hex Transmitter

    private var customMappingAndHexTransmitterView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Mapeo dinámico de características propietarias
                VStack(alignment: .leading, spacing: 12) {
                    Label("Mapeo Dinámico de UUIDs Propietarios", systemImage: "slider.horizontal.3")
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text("Cuando identifiques en la consola en vivo qué característica propietaria del Galaxy Fit 3 emite el contador de pasos o las fases de sueño, introduce su UUID aquí para que Fit3 Link lo decodifique y guarde automáticamente en SwiftData.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("UUID Característica de Pasos (UInt32 Little-Endian):")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SamsungHealthTheme.mintSteps)
                        TextField("FEA1", text: $bleManager.customStepsCharacteristicUUID)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline.monospaced())
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("UUID Característica de Sueño:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SamsungHealthTheme.purpleSleep)
                        TextField("FEA2", text: $bleManager.customSleepCharacteristicUUID)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline.monospaced())
                    }

                    Toggle("Suscribir automáticamente a todos los UUIDs propietarios al conectar", isOn: $bleManager.autoSubscribeProprietaryUUIDs)
                        .font(.caption)
                        .tint(SamsungHealthTheme.mintSteps)
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(SamsungHealthTheme.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(SamsungHealthTheme.cardBorder, lineWidth: 1)
                        )
                )

                // Transmisor de paquetes Hex
                VStack(alignment: .leading, spacing: 12) {
                    Label("Inyector de Comandos Hexadecimales (TX)", systemImage: "paperplane.fill")
                        .font(.headline)
                        .foregroundStyle(.white)

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Service UUID")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            TextField("FD5A", text: $targetServiceUUID)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Characteristic UUID")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            TextField("FEA1", text: $targetCharacteristicUUID)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Payload Hexadecimal (separado por espacios)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("FE A1 01 00", text: $customHexCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline.monospaced())
                    }

                    Button {
                        bleManager.writeHexPayload(
                            customHexCommand,
                            toService: targetServiceUUID,
                            characteristic: targetCharacteristicUUID
                        )
                    } label: {
                        HStack {
                            Image(systemName: "bolt.fill")
                            Text("Enviar Trama Hex a la Pulsera")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(SamsungHealthTheme.cyanActivity))
                        .foregroundStyle(.black)
                    }
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(SamsungHealthTheme.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(SamsungHealthTheme.cardBorder, lineWidth: 1)
                        )
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Helpers

    private func copySnifferLogToClipboard() {
        let lines = bleManager.packetLogs.map { log in
            "[\(Self.timestampFormatter.string(from: log.timestamp))] \(log.direction.rawValue) Svc:\(log.serviceUUID) Char:\(log.characteristicUUID) | HEX: \(log.hexString) | UTF8: \(log.utf8Preview) | \(log.decodedNumbersSummary)"
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        copiedDumpConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            copiedDumpConfirmation = false
        }
    }
}
