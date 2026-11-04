import Foundation
import CoreBluetooth

// MARK: - Health & Sensor Records

public struct StepRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public var steps: Int
    public var calories: Double
    public var distanceMeters: Double
    public var activeMinutes: Int
    public var source: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        steps: Int,
        calories: Double,
        distanceMeters: Double,
        activeMinutes: Int = 0,
        source: String = "Galaxy Fit3 (78DC)"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.steps = steps
        self.calories = calories
        self.distanceMeters = distanceMeters
        self.activeMinutes = activeMinutes
        self.source = source
    }
}

public struct HeartRateRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let bpm: Int
    public let sensorContactDetected: Bool
    public let rrIntervalMs: Int?
    public let source: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        bpm: Int,
        sensorContactDetected: Bool = true,
        rrIntervalMs: Int? = nil,
        source: String = "Galaxy Fit3 (78DC)"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.bpm = bpm
        self.sensorContactDetected = sensorContactDetected
        self.rrIntervalMs = rrIntervalMs
        self.source = source
    }
}

public struct SleepSession: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let startTime: Date
    public let endTime: Date
    public var deepMinutes: Int
    public var lightMinutes: Int
    public var remMinutes: Int
    public var awakeMinutes: Int
    public var sleepScore: Int
    public var source: String

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date,
        deepMinutes: Int,
        lightMinutes: Int,
        remMinutes: Int,
        awakeMinutes: Int,
        sleepScore: Int = 85,
        source: String = "Galaxy Fit3 (78DC)"
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
    }

    public var totalSleepMinutes: Int {
        deepMinutes + lightMinutes + remMinutes
    }

    public var totalInBedMinutes: Int {
        deepMinutes + lightMinutes + remMinutes + awakeMinutes
    }

    public var formattedDuration: String {
        let hours = totalSleepMinutes / 60
        let mins = totalSleepMinutes % 60
        return "\(hours)h \(mins)m"
    }
}

public struct SpO2Record: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let percentage: Int
    public let source: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        percentage: Int,
        source: String = "Galaxy Fit3 (78DC)"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.percentage = percentage
        self.source = source
    }
}
