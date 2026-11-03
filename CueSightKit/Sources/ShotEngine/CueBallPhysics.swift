import Foundation

/// A ball moving in a straight line, with sliding friction until it starts to roll.
/// `spin` is the surface speed of the ball's forward roll, so spin equal to speed means pure rolling.
public enum CueBallPhysics {
    public static let gravity = 9.81

    public struct State: Hashable, Sendable {
        public var speed: Double
        public var spin: Double
    }

    /// Speed and spin after travelling `distance` metres.
    public static func state(
        startSpeed v0: Double,
        startSpin w0: Double,
        distance: Double,
        config: ShotConfig
    ) -> State {
        let slide = config.slidingFriction * gravity
        let roll = config.rollingFriction * gravity
        let slideTime = max(0, (v0 - w0) / (3.5 * slide))
        let slideDistance = v0 * slideTime - 0.5 * slide * slideTime * slideTime

        if distance < slideDistance {
            let root = max(0, v0 * v0 - 2 * slide * distance).squareRoot()
            let t = (v0 - root) / slide
            return State(speed: v0 - slide * t, spin: w0 + 2.5 * slide * t)
        }
        let rollSpeed = v0 - slide * slideTime
        let left = max(0, rollSpeed * rollSpeed - 2 * roll * (distance - slideDistance)).squareRoot()
        return State(speed: left, spin: left)
    }

    /// The cue ball's direction once it's rolling again after contact, using the same
    /// sliding-then-rolling sum as the 30 degree rule: (5 * velocity + 2 * spin) / 7.
    public static func directionAfterContact(
        incoming: Vec2,
        objectDirection n: Vec2,
        contactSpeed: Double,
        contactSpin: Double
    ) -> (direction: Vec2, speed: Double) {
        let v = incoming * contactSpeed
        let tangentVelocity = v - n * v.dot(n)
        let spin = incoming * contactSpin
        let final = (tangentVelocity * 5 + spin * 2) / 7
        return (final.normalized, final.length)
    }

    /// A ball off a cushion. The cushion sends the ball back at `cushionRestitution` of its speed
    /// into the cushion, but some of its roll into the cushion survives (`cushionSpinKept`). So it
    /// slides for a moment and bends back towards the cushion before it rolls again.
    ///
    /// Speeds are m/s in the cushion's frame: `along` the cushion and `into` it. `spinShare` is the
    /// ball's forward roll as a share of its speed when it gets there: 1 when it's rolling, 0 when
    /// it was just hit and is still sliding. The result is the rolling velocity it ends up with,
    /// how far along the cushion (metres) that final straight line crosses the cushion, measured
    /// from the real contact point, and where the bend ends, as (along, away) metres from it.
    public static func rebound(
        along: Double, into: Double, spinShare: Double, config: ShotConfig
    ) -> (along: Double, away: Double, lineOffset: Double, bendEnd: Vec2) {
        let slide = config.slidingFriction * gravity
        // Velocity and spin just after the bounce, as (along, away from the cushion).
        let velocity = Vec2(along, config.cushionRestitution * into)
        let spin = Vec2(spinShare * along, -config.cushionSpinKept * spinShare * into)
        let rolling = (velocity * 5 + spin * 2) / 7
        let slip = velocity - spin
        guard into > 0, rolling.y > 1e-6, slip.length > 1e-9 else { return (rolling.x, max(rolling.y, 0), 0, .zero) }
        // Friction works against the slip until the ball rolls, so the path is a short curve.
        let time = slip.length / (3.5 * slide)
        let end = velocity * time - slip.normalized * (0.5 * slide * time * time)
        return (rolling.x, rolling.y, end.x - end.y * rolling.x / rolling.y, end)
    }
}
