import Foundation
import Combine

@MainActor
public final class HealthStore: ObservableObject {
    @Published public var stepRecords: [StepRecord] = []
    @Published public var heartRateRecords: [HeartRateRecord] = []
    @Published public var sleepSessions: [SleepSession] = []
    @Published public var spo2Records: [SpO2Record] = []

    private let fileManager = FileManager.default
    private var storageDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Fit3MacStudio", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var stepsFileURL: URL { storageDirectory.appendingPathComponent("steps_history.json") }
    private var hrFileURL: URL { storageDirectory.appendingPathComponent("heart_rate_history.json") }
    private var sleepFileURL: URL { storageDirectory.appendingPathComponent("sleep_sessions.json") }
    private var spo2FileURL: URL { storageDirectory.appendingPathComponent("spo2_history.json") }

    public init() {
        loadFromDisk()
        if stepRecords.isEmpty && heartRateRecords.isEmpty {
            seedSampleData()
        }
    }

    // MARK: - Ingestion

    public func addStepRecord(_ record: StepRecord) {
        if let idx = stepRecords.firstIndex(where: { Calendar.current.isDate($0.timestamp, inSameDayAs: record.timestamp) }) {
            stepRecords[idx].steps = record.steps
            stepRecords[idx].calories = record.calories
            stepRecords[idx].distanceMeters = record.distanceMeters
            stepRecords[idx].activeMinutes = record.activeMinutes
        } else {
            stepRecords.insert(record, at: 0)
        }
        saveSteps()
    }

    public func addHeartRateRecord(_ record: HeartRateRecord) {
        heartRateRecords.insert(record, at: 0)
        if heartRateRecords.count > 1000 {
            heartRateRecords.removeLast(heartRateRecords.count - 1000)
        }
        saveHeartRate()
    }

    public func addSleepSession(_ session: SleepSession) {
        if let idx = sleepSessions.firstIndex(where: { Calendar.current.isDate($0.endTime, inSameDayAs: session.endTime) }) {
            sleepSessions[idx] = session
        } else {
            sleepSessions.insert(session, at: 0)
        }
        saveSleep()
    }

    public func addSpO2Record(_ record: SpO2Record) {
        spo2Records.insert(record, at: 0)
        if spo2Records.count > 300 {
            spo2Records.removeLast(spo2Records.count - 300)
        }
        saveSpO2()
    }

    // MARK: - Persistence

    private func saveSteps() {
        if let data = try? JSONEncoder().encode(stepRecords) {
            try? data.write(to: stepsFileURL, options: .atomic)
        }
    }

    private func saveHeartRate() {
        if let data = try? JSONEncoder().encode(heartRateRecords) {
            try? data.write(to: hrFileURL, options: .atomic)
        }
    }

    private func saveSleep() {
        if let data = try? JSONEncoder().encode(sleepSessions) {
            try? data.write(to: sleepFileURL, options: .atomic)
        }
    }

    private func saveSpO2() {
        if let data = try? JSONEncoder().encode(spo2Records) {
            try? data.write(to: spo2FileURL, options: .atomic)
        }
    }

    private func loadFromDisk() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: stepsFileURL),
           let steps = try? decoder.decode([StepRecord].self, from: data) {
            self.stepRecords = steps
        }
        if let data = try? Data(contentsOf: hrFileURL),
           let hr = try? decoder.decode([HeartRateRecord].self, from: data) {
            self.heartRateRecords = hr
        }
        if let data = try? Data(contentsOf: sleepFileURL),
           let sleep = try? decoder.decode([SleepSession].self, from: data) {
            self.sleepSessions = sleep
        }
        if let data = try? Data(contentsOf: spo2FileURL),
           let spo2 = try? decoder.decode([SpO2Record].self, from: data) {
            self.spo2Records = spo2
        }
    }

    public func clearAllHistory() {
        stepRecords.removeAll()
        heartRateRecords.removeAll()
        sleepSessions.removeAll()
        spo2Records.removeAll()
        saveSteps()
        saveHeartRate()
        saveSleep()
        saveSpO2()
    }

    public func seedSampleData() {
        let now = Date()
        stepRecords = [
            StepRecord(timestamp: now, steps: 7248, calories: 312.5, distanceMeters: 5380.0, activeMinutes: 58),
            StepRecord(timestamp: now.addingTimeInterval(-86400), steps: 9840, calories: 420.0, distanceMeters: 7290.0, activeMinutes: 74),
            StepRecord(timestamp: now.addingTimeInterval(-172800), steps: 8430, calories: 360.0, distanceMeters: 6240.0, activeMinutes: 65)
        ]

        let bpms = [66, 68, 70, 72, 75, 78, 84, 98, 106, 92, 85, 76, 73, 72, 74]
        heartRateRecords = bpms.enumerated().map { index, bpm in
            HeartRateRecord(
                timestamp: now.addingTimeInterval(-Double(bpms.count - index) * 300),
                bpm: bpm,
                sensorContactDetected: true,
                rrIntervalMs: Int((60.0 / Double(bpm)) * 1000.0)
            )
        }

        let startOfToday = Calendar.current.startOfDay(for: now)
        let sleepEnd = startOfToday.addingTimeInterval(7 * 3600 + 15 * 60)
        let sleepStart = sleepEnd.addingTimeInterval(-(7 * 3600 + 20 * 60))
        sleepSessions = [
            SleepSession(
                startTime: sleepStart,
                endTime: sleepEnd,
                deepMinutes: 92,
                lightMinutes: 246,
                remMinutes: 98,
                awakeMinutes: 24,
                sleepScore: 88
            )
        ]

        spo2Records = [
            SpO2Record(timestamp: now, percentage: 98),
            SpO2Record(timestamp: now.addingTimeInterval(-3600), percentage: 97)
        ]

        saveSteps()
        saveHeartRate()
        saveSleep()
        saveSpO2()
    }

    // MARK: - CSV Export

    public func exportStepsCSV() -> URL? {
        let header = "ID,Timestamp,Steps,Calories,DistanceMeters,ActiveMinutes,Source\n"
        let rows = stepRecords.map {
            "\($0.id.uuidString),\($0.timestamp.ISO8601Format()),\($0.steps),\($0.calories),\($0.distanceMeters),\($0.activeMinutes),\($0.source)"
        }.joined(separator: "\n")
        let csv = header + rows

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Fit3_Pasos_\(Date().timeIntervalSince1970).csv")
        try? csv.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    public func exportHeartRateCSV() -> URL? {
        let header = "ID,Timestamp,BPM,SensorContact,RRIntervalMs,Source\n"
        let rows = heartRateRecords.map {
            "\($0.id.uuidString),\($0.timestamp.ISO8601Format()),\($0.bpm),\($0.sensorContactDetected),\($0.rrIntervalMs ?? 0),\($0.source)"
        }.joined(separator: "\n")
        let csv = header + rows

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Fit3_Pulso_\(Date().timeIntervalSince1970).csv")
        try? csv.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    public func exportSleepCSV() -> URL? {
        let header = "ID,StartTime,EndTime,TotalMinutes,DeepMinutes,LightMinutes,REMMinutes,AwakeMinutes,Score,Source\n"
        let rows = sleepSessions.map {
            "\($0.id.uuidString),\($0.startTime.ISO8601Format()),\($0.endTime.ISO8601Format()),\($0.totalSleepMinutes),\($0.deepMinutes),\($0.lightMinutes),\($0.remMinutes),\($0.awakeMinutes),\($0.sleepScore),\($0.source)"
        }.joined(separator: "\n")
        let csv = header + rows

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Fit3_Sueno_\(Date().timeIntervalSince1970).csv")
        try? csv.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }
}
