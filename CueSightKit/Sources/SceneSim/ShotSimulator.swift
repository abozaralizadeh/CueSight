import Foundation
import ShotEngine

/// A small table simulator, separate from the shot engine's formulas, used to check its advice.
/// It steps time forward with sliding and rolling friction, ball contact and cushions.
public struct ShotSimulator: Sendable {
    public var config: ShotConfig
    public var timeStep = 0.001
    public var maxSeconds = 12.0

    public init(config: ShotConfig = ShotConfig()) {
        self.config = config
    }

    public struct Outcome: Sendable {
        public var pottedIds: [Int]
        public var finalPositions: [Int: Vec2]
        public var firstBallHit: Int?
    }

    private struct Body {
        var id: Int
        var position: Vec2    // metres
        var velocity: Vec2
        var spin: Vec2        // surface speed of the rolling motion
        var potted = false
    }

    /// Plays one shot. `aimError` turns the cue's direction, in degrees.
    public func play(
        _ option: ShotOption,
        on state: TableState,
        aimErrorDegrees: Double = 0,
        speedScale: Double = 1
    ) -> Outcome {
        guard let cue = state.cueBall else {
            return Outcome(pottedIds: [], finalPositions: [:], firstBallHit: nil)
        }
        var aim = (option.cueBallPath[1] - option.cueBallPath[0]).normalized
        aim = aim.rotated(byRadians: aimErrorDegrees * .pi / 180)
        let speed = option.startSpeed * speedScale
        let spin = aim * (option.strikePoint.spinRatio * config.strikeSpinRatio * speed)
        return simulate(state: state, cueId: cue.id, velocity: aim * speed, spin: spin)
    }

    public func simulate(state: TableState, cueId: Int, velocity: Vec2, spin: Vec2) -> Outcome {
        var bodies = state.balls.map {
            Body(id: $0.id, position: $0.position / 1000, velocity: .zero, spin: .zero)
        }
        for i in bodies.indices where bodies[i].id == cueId {
            bodies[i].velocity = velocity
            bodies[i].spin = spin
        }

        let table = state.table
        let radius = table.ballRadiusMm / 1000
        let hx = table.lengthMm / 2000 - radius
        let hy = table.widthMm / 2000 - radius
        let pockets = table.pockets
        let slide = config.slidingFriction * CueBallPhysics.gravity
        let roll = config.rollingFriction * CueBallPhysics.gravity
        var potted: [Int] = []
        var firstHit: Int?

        var time = 0.0
        while time < maxSeconds {
            time += timeStep
            var moving = false

            for i in bodies.indices where !bodies[i].potted {
                var b = bodies[i]
                let speed = b.velocity.length
                let slip = b.velocity - b.spin
                if slip.length > 0.005 {
                    // Friction acts against the slip at the cloth.
                    let dir = slip.normalized
                    b.velocity = b.velocity - dir * (slide * timeStep)
                    b.spin = b.spin + dir * (2.5 * slide * timeStep)
                } else if speed > 0 {
                    let next = max(0, speed - roll * timeStep)
                    b.velocity = b.velocity.normalized * next
                    b.spin = b.velocity
                }
                if b.velocity.length < 0.003 {
                    b.velocity = .zero
                    b.spin = .zero
                } else {
                    moving = true
                }
                b.position = b.position + b.velocity * timeStep

                let mm = b.position * 1000
                for pocket in pockets where mm.distance(to: pocket.centre) < pocket.mouthWidth / 2 - table.ballDiameterMm / 4 {
                    b.potted = true
                    potted.append(b.id)
                }

                if !b.potted, !nearPocket(mm, pockets) {
                    if abs(b.position.x) > hx {
                        b.position.x = b.position.x > 0 ? hx : -hx
                        b.velocity.x *= -config.cushionRestitution
                        b.spin.x *= config.cushionSpinKept
                    }
                    if abs(b.position.y) > hy {
                        b.position.y = b.position.y > 0 ? hy : -hy
                        b.velocity.y *= -config.cushionRestitution
                        b.spin.y *= config.cushionSpinKept
                    }
                }
                if abs(b.position.x) > hx + 0.15 || abs(b.position.y) > hy + 0.15 {
                    b.potted = true
                }
                bodies[i] = b
            }

            for i in bodies.indices where !bodies[i].potted {
                for j in bodies.indices where j > i && !bodies[j].potted {
                    let delta = bodies[j].position - bodies[i].position
                    let gap = delta.length
                    guard gap < 2 * radius, gap > 0 else { continue }
                    let n = delta / gap
                    let closing = (bodies[i].velocity - bodies[j].velocity).dot(n)
                    guard closing > 0 else { continue }

                    if firstHit == nil {
                        if bodies[i].id == cueId { firstHit = bodies[j].id }
                        if bodies[j].id == cueId { firstHit = bodies[i].id }
                    }

                    // Equal masses swap the speed along the line of centres.
                    let relative = bodies[i].velocity - bodies[j].velocity
                    let tangent = relative - n * closing
                    var impulseTangent = Vec2.zero
                    if tangent.length > 1e-6 {
                        let t = tangent.normalized
                        let limit = min(config.ballToBallFriction * closing, tangent.length / 7)
                        impulseTangent = t * limit
                    }
                    bodies[i].velocity = bodies[i].velocity - n * closing - impulseTangent
                    bodies[j].velocity = bodies[j].velocity + n * closing + impulseTangent
                    let overlap = 2 * radius - gap
                    bodies[i].position = bodies[i].position - n * (overlap / 2)
                    bodies[j].position = bodies[j].position + n * (overlap / 2)
                    moving = true
                }
            }
            if !moving { break }
        }

        var finals: [Int: Vec2] = [:]
        for b in bodies where !b.potted { finals[b.id] = b.position * 1000 }
        return Outcome(pottedIds: potted, finalPositions: finals, firstBallHit: firstHit)
    }

    private func nearPocket(_ mm: Vec2, _ pockets: [Pocket]) -> Bool {
        pockets.contains { mm.distance(to: $0.centre) < $0.mouthWidth * 0.75 }
    }
}
