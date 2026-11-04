import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Binding var selectedTab: Int

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var bleManager: BLEManager
    @EnvironmentObject private var healthSyncBridge: HealthSyncBridge

    @Query(sort: \HeartRateRecord.timestamp, order: .reverse)
    private var heartRateRecords: [HeartRateRecord]

    @Query(sort: \SleepSession.endTime, order: .reverse)
    private var sleepSessions: [SleepSession]

    @Query(sort: \SpO2Record.timestamp, order: .reverse)
    private var spo2Records: [SpO2Record]

    private let stepGoal: Double = 10_000
    private let calorieGoal: Double = 400
    private let activeMinutesGoal: Double = 60

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    connectionHeaderCard
                    activityRingsCard
                    heartRateChartCard
                    spo2AndCadenceRow
                    sleepStagesCard
                    quickHealthSyncCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(SamsungHealthTheme.background.ignoresSafeArea())
            .navigationTitle("Fit3 Link")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        bleManager.isMockModeEnabled.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: bleManager.isMockModeEnabled ? "waveform.badge.checkmark" : "antenna.radiowaves.left.and.right")
                            Text(bleManager.isMockModeEnabled ? "Simulación ON" : "BLE Real")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(bleManager.isMockModeEnabled
                                      ? SamsungHealthTheme.mintSteps.opacity(0.22)
                                      : Color.white.opacity(0.1))
                        )
                        .foregroundStyle(bleManager.isMockModeEnabled ? SamsungHealthTheme.mintSteps : .white)
                    }
                }
            }
        }
    }

    // MARK: - 1. Connection & Battery Header Card

    private var connectionHeaderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.18))
                        .frame(width: 48, height: 48)
                    Image(systemName: "applewatch.watchface")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(bleManager.connectedDeviceName)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                        if bleManager.isBondedForANCS {
                            Text("ANCS")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(SamsungHealthTheme.cyanActivity.opacity(0.25)))
                                .foregroundStyle(SamsungHealthTheme.cyanActivity)
                        }
                    }
                    Text("\(bleManager.connectionState.rawValue) • \(bleManager.modelNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if bleManager.batteryLevel > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: batteryIconName(for: bleManager.batteryLevel))
                            .foregroundStyle(SamsungHealthTheme.mintSteps)
                        Text("\(bleManager.batteryLevel)%")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                } else {
                    Button {
                        selectedTab = 1
                    } label: {
                        Text("Conectar")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(SamsungHealthTheme.mintSteps))
                            .foregroundStyle(.black)
                    }
                }
            }

            if bleManager.connectionState == .disconnected && !bleManager.isMockModeEnabled {
                HStack {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text("¿Sin la pulsera a mano? Activa 'Simulación ON' arriba a la derecha para probar gráficas y exportación a Salud.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(SamsungHealthTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(SamsungHealthTheme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - 2. Activity Rings Card (Samsung Health Style)

    private var activityRingsCard: some View {
        let stepsProgress = min(Double(bleManager.todaySteps) / stepGoal, 1.0)
        let calProgress = min(bleManager.todayCalories / calorieGoal, 1.0)
        let activeProgress = min(Double(bleManager.todayActiveMinutes) / activeMinutesGoal, 1.0)

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Actividad Diaria", systemImage: "flame.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: "%.2f km", bleManager.todayDistanceMeters / 1000.0))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SamsungHealthTheme.mintSteps)
            }

            HStack(spacing: 24) {
                // Triple Concentric Rings
                ZStack {
                    ActivityRingShape(progress: stepsProgress, lineWidth: 13)
                        .stroke(
                            SamsungHealthTheme.mintSteps,
                            style: StrokeStyle(lineWidth: 13, lineCap: .round)
                        )
                        .background(
                            Circle().stroke(SamsungHealthTheme.mintSteps.opacity(0.16), lineWidth: 13)
                        )
                        .frame(width: 126, height: 126)

                    ActivityRingShape(progress: calProgress, lineWidth: 13)
                        .stroke(
                            SamsungHealthTheme.orangeCalories,
                            style: StrokeStyle(lineWidth: 13, lineCap: .round)
                        )
                        .background(
                            Circle().stroke(SamsungHealthTheme.orangeCalories.opacity(0.16), lineWidth: 13)
                        )
                        .frame(width: 94, height: 94)

                    ActivityRingShape(progress: activeProgress, lineWidth: 13)
                        .stroke(
                            SamsungHealthTheme.cyanActivity,
                            style: StrokeStyle(lineWidth: 13, lineCap: .round)
                        )
                        .background(
                            Circle().stroke(SamsungHealthTheme.cyanActivity.opacity(0.16), lineWidth: 13)
                        )
                        .frame(width: 62, height: 62)

                    Image(systemName: "figure.walk")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(SamsungHealthTheme.mintSteps)
                }
                .padding(.leading, 6)

                VStack(alignment: .leading, spacing: 12) {
                    metricRow(
                        title: "Pasos",
                        value: "\(bleManager.todaySteps.formatted())",
                        goal: "/ \(Int(stepGoal).formatted())",
                        color: SamsungHealthTheme.mintSteps,
                        icon: "shoeprints.fill"
                    )
                    metricRow(
                        title: "Calorías Activas",
                        value: "\(Int(bleManager.todayCalories))",
                        goal: "/ \(Int(calorieGoal)) kcal",
                        color: SamsungHealthTheme.orangeCalories,
                        icon: "flame.fill"
                    )
                    metricRow(
                        title: "Tiempo Activo",
                        value: "\(bleManager.todayActiveMinutes)",
                        goal: "/ \(Int(activeMinutesGoal)) min",
                        color: SamsungHealthTheme.cyanActivity,
                        icon: "bolt.heart.fill"
                    )
                }
                Spacer(minLength: 0)
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

    private func metricRow(title: String, value: String, goal: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(goal)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 3. Heart Rate Chart Card (GATT 0x180D)

    private var heartRateChartCard: some View {
        let recentSamples = Array(heartRateRecords.prefix(20).reversed())
        let minBPM = recentSamples.map(\.bpm).min() ?? 60
        let maxBPM = recentSamples.map(\.bpm).max() ?? 110

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(SamsungHealthTheme.coralHeart)
                    Text("Frecuencia Cardíaca")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(bleManager.currentHeartRate > 0 ? "\(bleManager.currentHeartRate)" : "—")
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(SamsungHealthTheme.coralHeart)
                    Text("BPM")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            if recentSamples.isEmpty {
                Text("Sin lecturas de pulso aún. Conecta tu Fit 3 o activa el Modo Simulación.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            } else {
                Chart(recentSamples) { item in
                    AreaMark(
                        x: .value("Hora", item.timestamp),
                        y: .value("BPM", item.bpm)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                SamsungHealthTheme.coralHeart.opacity(0.38),
                                SamsungHealthTheme.coralHeart.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Hora", item.timestamp),
                        y: .value("BPM", item.bpm)
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .foregroundStyle(SamsungHealthTheme.coralHeart)

                    PointMark(
                        x: .value("Hora", item.timestamp),
                        y: .value("BPM", item.bpm)
                    )
                    .symbolSize(22)
                    .foregroundStyle(SamsungHealthTheme.coralHeart)
                }
                .chartYScale(domain: max(45, minBPM - 10)...min(200, maxBPM + 12))
                .frame(height: 145)

                HStack {
                    Text("Mín: \(minBPM) BPM")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Servicio GATT 0x180D (0x2A37)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Máx: \(maxBPM) BPM")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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

    // MARK: - 4. SpO2 & Running Speed/Cadence Row

    private var spo2AndCadenceRow: some View {
        HStack(spacing: 14) {
            // SpO2 Card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "lungs.fill")
                        .foregroundStyle(SamsungHealthTheme.cyanActivity)
                    Text("Oxígeno (SpO2)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(bleManager.currentSpO2)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(SamsungHealthTheme.cyanActivity)
                    Text("%")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Text(bleManager.currentSpO2 >= 95 ? "Nivel normal (95–100%)" : "Nivel bajo en reposo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(SamsungHealthTheme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(SamsungHealthTheme.cardBorder, lineWidth: 1)
                    )
            )

            // Cadence & Speed Card (0x1814)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "figure.run")
                        .foregroundStyle(SamsungHealthTheme.mintSteps)
                    Text("Cadencia RSC")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(bleManager.instantaneousCadence > 0 ? bleManager.instantaneousCadence : (bleManager.isMockModeEnabled ? 84 : 0))")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(SamsungHealthTheme.mintSteps)
                    Text("spm")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text("GATT 0x1814 • \(String(format: "%.1f km/h", bleManager.instantaneousSpeedKmh > 0 ? bleManager.instantaneousSpeedKmh : (bleManager.isMockModeEnabled ? 4.8 : 0.0)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(SamsungHealthTheme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(SamsungHealthTheme.cardBorder, lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - 5. Sleep Stages Card

    private var sleepStagesCard: some View {
        let latestSleep = sleepSessions.first
        let deep = latestSleep?.deepMinutes ?? 88
        let light = latestSleep?.lightMinutes ?? 242
        let rem = latestSleep?.remMinutes ?? 96
        let awake = latestSleep?.awakeMinutes ?? 22
        let total = max(deep + light + rem + awake, 1)
        let score = latestSleep?.sleepScore ?? 87

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "bed.double.fill")
                        .foregroundStyle(SamsungHealthTheme.purpleSleep)
                    Text("Fases de Sueño")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                Spacer()
                HStack(spacing: 6) {
                    Text("Puntuación \(score)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(SamsungHealthTheme.purpleSleep.opacity(0.22)))
                        .foregroundStyle(SamsungHealthTheme.purpleSleep)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                let sleepOnly = deep + light + rem
                Text("\(sleepOnly / 60)h \(sleepOnly % 60)m")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("tiempo total dormido")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Segmented horizontal sleep bar
            GeometryReader { geo in
                let width = geo.size.width
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(SamsungHealthTheme.indigoDeepSleep)
                        .frame(width: max(12, width * (CGFloat(deep) / CGFloat(total))))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(SamsungHealthTheme.purpleSleep)
                        .frame(width: max(12, width * (CGFloat(light) / CGFloat(total))))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(SamsungHealthTheme.cyanActivity)
                        .frame(width: max(12, width * (CGFloat(rem) / CGFloat(total))))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(SamsungHealthTheme.coralHeart)
                        .frame(width: max(8, width * (CGFloat(awake) / CGFloat(total))))
                }
            }
            .frame(height: 16)

            // Breakdown legend
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                sleepStagePill(label: "Profundo", minutes: deep, color: SamsungHealthTheme.indigoDeepSleep)
                sleepStagePill(label: "Ligero", minutes: light, color: SamsungHealthTheme.purpleSleep)
                sleepStagePill(label: "REM", minutes: rem, color: SamsungHealthTheme.cyanActivity)
                sleepStagePill(label: "Despierto", minutes: awake, color: SamsungHealthTheme.coralHeart)
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

    private func sleepStagePill(label: String, minutes: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(minutes / 60)h \(minutes % 60)m")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    // MARK: - 6. Quick Apple Health Bridge Card

    private var quickHealthSyncCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "heart.text.square.fill")
                    .foregroundStyle(SamsungHealthTheme.coralHeart)
                Text("Puente Apple Health (Sideloadly Ready)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
            }

            Text(healthSyncBridge.lastSyncStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task {
                    await healthSyncBridge.syncPendingRecords(modelContext: modelContext, bleManager: bleManager)
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    Text("Sincronizar con Apple Health vía Atajo")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(SamsungHealthTheme.mintSteps)
                )
                .foregroundStyle(.black)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(SamsungHealthTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(SamsungHealthTheme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch bleManager.connectionState {
        case .connected, .simulating:
            return SamsungHealthTheme.mintSteps
        case .scanning, .connecting:
            return SamsungHealthTheme.orangeCalories
        case .disconnected:
            return .gray
        }
    }

    private func batteryIconName(for level: Int) -> String {
        switch level {
        case 85...100: return "battery.100percent"
        case 60..<85: return "battery.75percent"
        case 35..<60: return "battery.50percent"
        case 15..<35: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

// MARK: - Concentric Ring Shape

struct ActivityRingShape: Shape {
    var progress: Double
    var lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let startAngle = Angle(degrees: -90)
        let endAngle = Angle(degrees: -90 + (360 * max(0.02, min(progress, 1.0))))
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        return path
    }
}
