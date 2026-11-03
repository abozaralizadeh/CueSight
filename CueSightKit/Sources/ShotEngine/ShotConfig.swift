import Foundation

/// Every number the shot engine relies on, in one place, so it can be tuned from real results.
public struct ShotConfig: Codable, Hashable, Sendable {
    public var maxOptions = 3
    public var maxCutDegrees = 75.0

    // Features
    public var includeObjectBanks = true
    public var includeKicks = true
    public var useThrowCorrection = true
    public var adviseSpin = true

    // Physics
    public var cushionRestitution = 0.75
    /// How much of a rolling ball's roll into the cushion is still there after it bounces.
    /// That roll bends the ball back towards the cushion for a moment. A guess until it's measured.
    public var cushionSpinKept = 0.5
    public var rollingFriction = 0.01
    public var slidingFriction = 0.2
    public var ballToBallFriction = 0.06
    /// Speed the object ball should still have when it reaches the pocket, m/s.
    public var arrivalSpeed = 0.5
    /// Surface speed from a half-radius strike, as a share of the ball's speed.
    public var strikeSpinRatio = 1.25
    /// The hardest the advice will ask for, m/s off the tip, when it hits harder to keep draw.
    public var maxStartSpeed = 5.0

    // Advice bands
    public var softBelowMetresPerSecond = 1.2
    public var mediumBelowMetresPerSecond = 2.4
    /// The aim error a shot can take and still drop, in degrees.
    public var easyAimToleranceDegrees = 0.25
    public var mediumAimToleranceDegrees = 0.08
    public var bankTolerancePenalty = 0.45
    public var kickTolerancePenalty = 0.35
    public var scratchPenalty = 0.5
    /// Banks and kicks needing finer aim than this aren't offered. The cushion model is a guess
    /// (see `cushionSpinKept`), so it can't be trusted to a smaller angle than this.
    public var minCushionShotToleranceDegrees = 0.03

    public init() {}

    /// Direct pots only, with a centre strike and no throw correction.
    public static var directOnly: ShotConfig {
        var config = ShotConfig()
        config.includeObjectBanks = false
        config.includeKicks = false
        config.useThrowCorrection = false
        config.adviseSpin = false
        return config
    }
}
