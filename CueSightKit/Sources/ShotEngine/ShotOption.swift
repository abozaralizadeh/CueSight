import Foundation

public enum ShotKind: String, Codable, Sendable {
    case direct
    /// The object ball goes off one cushion, then into the pocket.
    case objectBank
    /// The cue ball goes off one cushion, then hits the object ball.
    case kick
}

public enum Strength: String, Codable, Sendable {
    case soft, medium, firm
}

public enum Difficulty: String, Codable, Sendable {
    case easy, medium, hard
}

public enum StrikePoint: String, Codable, CaseIterable, Sendable {
    case centre, top, bottom

    public var spinRatio: Double {
        switch self {
        case .centre: return 0
        case .top: return 1
        case .bottom: return -1
        }
    }
}

public struct ShotOption: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: ShotKind
    public var targetBallId: Int
    public var pocketName: String
    /// Where the cue ball's centre has to be at contact.
    public var ghostBall: Vec2
    public var cueBallPath: [Vec2]
    public var objectBallPath: [Vec2]
    public var cueBallAfterPath: [Vec2]
    public var strength: Strength
    public var startSpeed: Double
    public var strikePoint: StrikePoint
    public var difficulty: Difficulty
    public var cutDegrees: Double
    public var aimToleranceDegrees: Double
    /// How far the aim moved to allow for throw, in millimetres at the ghost ball.
    public var throwCorrectionMm: Double
    public var scratchRisk: Bool
    public var score: Double
}
