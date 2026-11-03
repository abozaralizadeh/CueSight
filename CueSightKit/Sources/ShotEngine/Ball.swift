import Foundation

public enum BallKind: String, Codable, CaseIterable, Sendable {
    case cue
    /// An object ball the app couldn't identify. Treated as legal, so the player decides.
    case unknownObject
    case solid, stripe, eight
    case red, yellow, green, brown, blue, pink, black

    public var isColourInSnooker: Bool {
        BallKind.snookerColourOrder.contains(self)
    }

    /// The order colours are potted once the reds are gone.
    public static let snookerColourOrder: [BallKind] = [.yellow, .green, .brown, .blue, .pink, .black]
}

public struct Ball: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var position: Vec2
    public var kind: BallKind
    public var confidence: Double
    public var fixedByPlayer: Bool

    public init(
        id: Int,
        position: Vec2,
        kind: BallKind = .unknownObject,
        confidence: Double = 1,
        fixedByPlayer: Bool = false
    ) {
        self.id = id
        self.position = position
        self.kind = kind
        self.confidence = confidence
        self.fixedByPlayer = fixedByPlayer
    }
}

public struct TableState: Codable, Hashable, Sendable {
    public var table: TableProfile
    public var balls: [Ball]
    public var scannedAt: Date

    public init(table: TableProfile, balls: [Ball], scannedAt: Date = Date()) {
        self.table = table
        self.balls = balls
        self.scannedAt = scannedAt
    }

    public var cueBall: Ball? { balls.first { $0.kind == .cue } }
    public var objectBalls: [Ball] { balls.filter { $0.kind != .cue } }
}
