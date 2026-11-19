import Foundation

/// What the iPhone and the Watch send each other over the mirrored workout session.
struct RunStatus: Codable, Sendable, Equatable {
    var targetSecondsPerUnit: Double
    var unit: DistanceUnit
    var clickCadence: Double
    var measuredCadence: Double?
    var currentSecondsPerUnit: Double?
    var stepLength: Double?
    var distance: Double          // metres
    var elapsed: TimeInterval
    var holding: Bool
}

enum RemoteMessage: Codable, Sendable {
    case status(RunStatus)            // phone -> watch, every couple of seconds
    case setTarget(Double)            // watch -> phone: new target pace (seconds per unit)
    case setHold(Bool)                // watch -> phone
    case heartRate(Double)            // watch -> phone

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(_ d: Data) -> RemoteMessage? { try? JSONDecoder().decode(RemoteMessage.self, from: d) }
}
