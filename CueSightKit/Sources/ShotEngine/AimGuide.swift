import Foundation

/// Helps the player line up from behind the cue ball, phone in hand. It knows the shot's aim line
/// and, given where the phone is and which way it faces on the table, says what to do next.
/// Everything is in table millimetres, seen from above. No camera code.
public struct AimGuide: Sendable {
    public enum Advice: Equatable, Sendable {
        /// The phone isn't behind the cue ball yet.
        case walkBehind
        /// Step sideways by this many millimetres to get onto the line.
        case moveLeft(Double)
        case moveRight(Double)
        /// Turn the phone by this many degrees to face along the line.
        case turnLeft(Double)
        case turnRight(Double)
        case onLine
    }

    public struct Reading: Equatable, Sendable {
        /// How far the phone is behind the cue ball, along the line. Negative means in front of it.
        public var behindMm: Double
        /// How far the phone is off the line. Positive means it's to the right, looking along the shot.
        public var sidewaysMm: Double
        /// How far the phone faces off the line. Positive means it's turned to the left.
        public var headingDegrees: Double
        public var advice: Advice
    }

    public var cueBall: Vec2
    /// Unit direction the cue ball starts off in: towards the ghost ball, or the cushion on a kick.
    public var aim: Vec2
    public var ballRadiusMm: Double
    public var strike: StrikePoint

    /// Closer than this to the line counts as on it. A hand-held phone won't do much better.
    public var sidewaysToleranceMm = 25.0
    public var headingToleranceDegrees = 3.0
    /// The phone has to be at least this far behind the ball before the line advice means anything.
    public var minBehindMm = 100.0

    public init?(shot: ShotOption, table: TableProfile) {
        guard shot.cueBallPath.count >= 2 else { return nil }
        let direction = shot.cueBallPath[1] - shot.cueBallPath[0]
        guard direction.length > 1e-6 else { return nil }
        cueBall = shot.cueBallPath[0]
        aim = direction.normalized
        ballRadiusMm = table.ballRadiusMm
        strike = shot.strikePoint
    }

    /// Where the cue should lie: from the back of the cue ball, straight back towards the player.
    public func cueLine(lengthMm: Double = 600) -> [Vec2] {
        let start = cueBall - aim * (ballRadiusMm * 1.6)
        return [start, start - aim * lengthMm]
    }

    /// Where to strike, on the back of the cue ball as the player sees it: a point on the line
    /// and its height above the cloth. Follow is above the middle and draw below, by half a radius.
    public var strikeMark: (point: Vec2, heightMm: Double) {
        let rise = strike.spinRatio * ballRadiusMm * 0.5
        let back = (ballRadiusMm * ballRadiusMm - rise * rise).squareRoot()
        return (cueBall - aim * back, ballRadiusMm + rise)
    }

    /// `viewer` is the phone's spot on the table plane, and `facing` which way it looks, seen from above.
    public func reading(viewer: Vec2, facing: Vec2) -> Reading {
        let offset = viewer - cueBall
        let right = Vec2(aim.y, -aim.x)
        let behind = -offset.dot(aim)
        let sideways = offset.dot(right)
        let look = facing.length > 1e-9 ? facing.normalized : aim
        let heading = atan2(aim.cross(look), aim.dot(look)) * 180 / .pi

        let advice: Advice
        if behind < minBehindMm || abs(sideways) > behind {
            advice = .walkBehind
        } else if abs(sideways) > sidewaysToleranceMm {
            advice = sideways > 0 ? .moveLeft(abs(sideways)) : .moveRight(abs(sideways))
        } else if abs(heading) > headingToleranceDegrees {
            advice = heading > 0 ? .turnRight(abs(heading)) : .turnLeft(abs(heading))
        } else {
            advice = .onLine
        }
        return Reading(behindMm: behind, sidewaysMm: sideways, headingDegrees: heading, advice: advice)
    }
}
