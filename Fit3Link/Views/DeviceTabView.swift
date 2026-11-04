import SwiftUI
import SwiftData

struct DeviceTabView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var bleManager: BLEManager
    @EnvironmentObject private var healthSyncBridge: HealthSyncBridge

    @State private var showShortcutGuideSheet: Bool = false
    @State private var showJSONPreviewSheet: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    deviceStatusBannerCard
                    findMyBandAndANCSCard
                    appleHealthBridgeCard
                    bleScannerCard
                    simulationAndSettingsCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(SamsungHealthTheme.background.ignoresSafeArea())
            .navigationTitle("Galaxy Fit 3")
            .sheet(isPresented: $showShortcutGuideSheet) {
                ShortcutSetupGuideSheet(shortcutName: healthSyncBridge.shortcutName)
            }
            .sheet(isPresented: $showJSONPreviewSheet) {
                JSONPreviewSheet(jsonText: healthSyncBridge.lastExportedJSONPreview)
            }
        }
    }

    // MARK: - 1. Device Status Banner

    private var deviceStatusBannerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(SamsungHealthTheme.mintSteps.opacity(0.16))
                        .frame(width: 58, height: 58)
                    Image(systemName: "applewatch.side.right")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(SamsungHealthTheme.mintSteps)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(bleManager.connectedDeviceName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Modelo: \(bleManager.modelNumber) • FW: \(bleManager.firmwareVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(bleManager.statusBannerMessage)
                        .font(.caption2)
                        .foregroundStyle(SamsungHealthTheme.mintSteps)
                        .lineLimit(2)
                }
                Spacer()
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack {
                infoBadge(title: "Batería", value: bleManager.batteryLevel > 0 ? "\(bleManager.batteryLevel)%" : "—", icon: "battery.100percent")
                Spacer()
                infoBadge(title: "Señal RSSI", value: "\(bleManager.lastRSSI) dBm", icon: "wifi")
                Spacer()
                infoBadge(title: "Background", value: "Activo", icon: "clock.arrow.circlepath")
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(SamsungHealthTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(SamsungHealthTheme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func infoBadge(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(SamsungHealthTheme.cyanActivity)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - 2. "Encontrar mi pulsera" & ANCS/AMS Card

    private var findMyBandAndANCSCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Acciones Rápidas y Notificaciones")
                .font(.headline)
                .foregroundStyle(.white)

            // Botón Encontrar mi pulsera
            Button {
                bleManager.triggerFindMyBand()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: bleManager.isFindMyBandActive ? "bell.and.waves.left.and.right.fill" : "bell.badge.fill")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bleManager.isFindMyBandActive ? "Detener Alerta en Pulsera" : "Encontrar mi pulsera (Alerta BLE)")
                            .font(.subheadline.weight(.bold))
                        Text("Envía comando GATT 0x1802 / Trama de vibración Samsung")
                            .font(.caption2)
                            .opacity(0.85)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(bleManager.isFindMyBandActive ? SamsungHealthTheme.coralHeart : SamsungHealthTheme.cyanActivity.opacity(0.22))
                )
                .foregroundStyle(.white)
            }

            // Estado ANCS & AMS Bonding
            HStack(spacing: 12) {
                Image(systemName: bleManager.isBondedForANCS ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(bleManager.isBondedForANCS ? SamsungHealthTheme.mintSteps : SamsungHealthTheme.orangeCalories)

                VStack(alignment: .leading, spacing: 3) {
                    Text(bleManager.isBondedForANCS ? "ANCS y AMS Habilitados (Bonding Activo)" : "Enlace Seguro ANCS Pendiente")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Permite recibir WhatsApp/llamadas del iPhone y controlar la música desde el Galaxy Fit 3.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    bleManager.requestANCSAndAMSBonding()
                } label: {
                    Text("Enlazar")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .foregroundStyle(SamsungHealthTheme.mintSteps)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.04)))
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(SamsungHealthTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(SamsungHealthTheme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - 3. Apple Health Sync Bridge (Sideloadly Workaround)

    private var appleHealthBridgeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "heart.text.square.fill")
                    .foregroundStyle(SamsungHealthTheme.coralHeart)
                Text("Sincronización con Apple Health")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    showShortcutGuideSheet = true
                } label: {
                    Label("Cómo configurar Atajo", systemImage: "questionmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SamsungHealthTheme.cyanActivity)
                }
            }

            Picker("Método de Sincronización", selection: $healthSyncBridge.selectedSyncMethod) {
                ForEach(HealthSyncMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)

            if healthSyncBridge.selectedSyncMethod == .iosShortcutsBridge {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nombre del Atajo en iOS:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Fit3 Health Sync", text: $healthSyncBridge.shortcutName)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                }
            }

            Button {
                Task {
                    await healthSyncBridge.syncPendingRecords(modelContext: modelContext, bleManager: bleManager)
                }
            } label: {
                HStack {
                    if healthSyncBridge.isSyncing {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "bolt.horizontal.circle.fill")
                    }
                    Text("Sincronizar con Apple Health vía Atajo")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(SamsungHealthTheme.mintSteps)
                )
                .foregroundStyle(.black)
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        await healthSyncBridge.copyJSONOnly(modelContext: modelContext, bleManager: bleManager)
                    }
                } label: {
                    Label("Copiar JSON", systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                        .foregroundStyle(.white)
                }

                Button {
                    Task {
                        if healthSyncBridge.lastExportedJSONPreview.isEmpty {
                            await healthSyncBridge.copyJSONOnly(modelContext: modelContext, bleManager: bleManager)
                        }
                        showJSONPreviewSheet = true
                    }
                } label: {
                    Label("Ver Payload JSON", systemImage: "curlybraces")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                        .foregroundStyle(.white)
                }
            }

            Text(healthSyncBridge.lastSyncStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(SamsungHealthTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(SamsungHealthTheme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - 4. BLE Scanner Card

    private var bleScannerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Escáner Bluetooth LE", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                if bleManager.connectionState == .scanning {
                    Button("Detener") {
                        bleManager.stopScanning()
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SamsungHealthTheme.coralHeart)
                } else {
                    Button("Buscar Pulsera") {
                        bleManager.startScanning()
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SamsungHealthTheme.mintSteps)
                }
            }

            Toggle("Mostrar todos los periféricos BLE cercanos", isOn: $bleManager.showAllBLEDevicesInScanner)
                .font(.caption)
                .tint(SamsungHealthTheme.mintSteps)

            if bleManager.scannedPeripherals.isEmpty {
                Text(bleManager.isMockModeEnabled
                     ? "Modo Simulación activo. Desactívalo abajo si deseas buscar una Galaxy Fit 3 física por Bluetooth."
                     : "Pulsa 'Buscar Pulsera' con tu Galaxy Fit 3 encendida y cerca del iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(bleManager.scannedPeripherals) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                if item.isLikelyFit3 {
                                    Text("FIT 3")
                                        .font(.system(size: 9, weight: .heavy))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(SamsungHealthTheme.mintSteps.opacity(0.25)))
                                        .foregroundStyle(SamsungHealthTheme.mintSteps)
                                }
                            }
                            Text("RSSI: \(item.rssi) dBm • UUID: \(item.id.uuidString.prefix(8))...")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Conectar") {
                            bleManager.connectToScannedPeripheral(item)
                        }
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(SamsungHealthTheme.mintSteps))
                        .foregroundStyle(.black)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(SamsungHealthTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(SamsungHealthTheme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - 5. Simulation Mode & Settings Card

    private var simulationAndSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Modo Simulación (Mock Mode)", systemImage: "cpu.fill")
                .font(.headline)
                .foregroundStyle(.white)

            Toggle("Simular Samsung Galaxy Fit 3 Conectada", isOn: $bleManager.isMockModeEnabled)
                .font(.subheadline.weight(.medium))
                .tint(SamsungHealthTheme.mintSteps)

            Text("Genera pulsaciones, pasos, SpO2, sueño y paquetes hexadecimales BLE simulados para validar SwiftData, gráficas y la exportación a Apple Health sin hardware físico.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    bleManager.seedMockHistoryIfNeeded()
                } label: {
                    Label("Poblar Historial Demo", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                        .foregroundStyle(SamsungHealthTheme.mintSteps)
                }

                Button(role: .destructive) {
                    bleManager.forgetSavedDevice()
                } label: {
                    Label("Olvidar Pulsera", systemImage: "trash")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                        .foregroundStyle(SamsungHealthTheme.coralHeart)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(SamsungHealthTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(SamsungHealthTheme.cardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Shortcut Setup Guide Sheet

struct ShortcutSetupGuideSheet: View {
    let shortcutName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Cómo funciona el Puente con Apple Health (Sin cuenta de desarrollador de pago)")
                        .font(.headline)

                    Text("Al instalar Fit3 Link desde Windows con Sideloadly usando un Apple ID gratuito, Apple restringe el entitlement privado de HealthKit. Sin embargo, la app nativa 'Atajos' (Shortcuts) de iOS sí tiene permiso oficial de Apple para escribir en Salud.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        stepItem(number: "1", title: "Abre la app 'Atajos' en tu iPhone", detail: "Crea un nuevo Atajo llamado exactamente '\(shortcutName)'.")
                        stepItem(number: "2", title: "Añade 'Obtener portapapeles'", detail: "Añade la acción 'Obtener el contenido del portapapeles' y 'Obtener diccionario de la entrada'.")
                        stepItem(number: "3", title: "Extrae las claves del JSON", detail: "Lee 'summaryStepsToday' (Pasos), 'summaryLatestHeartRateBPM' (Frecuencia cardíaca) y 'summaryLatestSpO2Percent' (Oxígeno en sangre).")
                        stepItem(number: "4", title: "Añade 'Registrar muestra de Salud'", detail: "Usa la acción nativa 'Registrar muestra de Salud' de iOS para guardar Pasos, Frecuencia Cardíaca y Sueño en Apple Health.")
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
                }
                .padding()
            }
            .navigationTitle("Guía de Atajo iOS")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func stepItem(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(SamsungHealthTheme.mintSteps))
                .foregroundStyle(.black)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.bold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - JSON Preview Sheet

struct JSONPreviewSheet: View {
    let jsonText: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(jsonText.isEmpty ? "Aún no se ha generado ningún payload JSON." : jsonText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Payload JSON Exportado")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
