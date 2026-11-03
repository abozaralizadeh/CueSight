import Foundation

/// Looks at every legal ball with every pocket and returns the best shots.
public struct ShotFinder: Sendable {
    public var config: ShotConfig

    public init(config: ShotConfig = ShotConfig()) {
        self.config = config
    }

    /// - Parameter targetBallId: limits the search to one ball, when the player tapped it.
    public func findShots(
        in state: TableState,
        rules: RulesContext = .free,
        targetBallId: Int? = nil
    ) -> [ShotOption] {
        guard let cue = state.cueBall else { return [] }
        let legal = rules.legalTargets(in: state.balls).filter { targetBallId == nil || $0.id == targetBallId }
        var options: [ShotOption] = []
        for target in legal {
            for pocket in state.table.pockets {
                options += shots(state: state, cue: cue, target: target, pocket: pocket)
            }
        }
        let sorted = options.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id
        }
        return Array(sorted.prefix(config.maxOptions))
    }

    private func shots(state: TableState, cue: Ball, target: Ball, pocket: Pocket) -> [ShotOption] {
        var found: [ShotOption] = []
        let table = state.table
        let direct = [target.position, pocket.centre]
        let roll = config.rollingFriction * CueBallPhysics.gravity

        if let shot = build(state, cue, target, pocket, objectPath: direct, kind: .direct) {
            found.append(shot)
        }
        if config.includeObjectBanks {
            for cushion in Cushion.allCases {
                // The object ball starts out sliding, and has to leave the cushion fast enough to reach the pocket.
                let bounce = settledBounce(from: target.position, to: pocket.centre, cushion, table, spinShare: 0) { start in
                    let leg = pocket.centre.distance(to: start) / 1000
                    return (self.config.arrivalSpeed * self.config.arrivalSpeed + 2 * roll * leg).squareRoot()
                }
                guard let bounce else { continue }
                let path = [target.position, bounce.contact, pocket.centre]
                if let shot = build(state, cue, target, pocket, objectPath: path, objectBounce: bounce, kind: .objectBank) {
                    found.append(shot)
                }
            }
        }
        if config.includeKicks {
            let line = (pocket.centre - target.position).normalized
            let ghost = ghostBall(object: target.position, direction: line, table)
            let objectSpeed = objectStartSpeed(objectPath: direct, objectBounce: nil)
            for cushion in Cushion.allCases {
                // Kicks are advised with a centre strike. The cue ball has to leave the cushion
                // fast enough to hit the object ball hard enough.
                let bounce = settledBounce(from: cue.position, to: ghost, cushion, table, spinShare: 0) { start in
                    let contact = self.contactSpeed(objectSpeed: objectSpeed, cut: self.angleBetween(ghost - start, line))
                    let leg = ghost.distance(to: start) / 1000
                    return (contact * contact + 2 * roll * leg).squareRoot()
                }
                guard let bounce else { continue }
                if let shot = build(state, cue, target, pocket, objectPath: direct, cueBounce: bounce, kind: .kick) {
                    found.append(shot)
                }
            }
        }
        return found
    }

    private func ghostBall(object: Vec2, direction: Vec2, _ table: TableProfile) -> Vec2 {
        object - direction * table.ballDiameterMm
    }

    /// A ball's bounce off a cushion on its way to somewhere.
    struct Bounce: Sendable {
        /// Where the ball touches the cushion line.
        var contact: Vec2
        /// The ball's path bends after the bounce, then runs straight. This is where that straight
        /// part, traced back, meets the cushion line.
        var lineStart: Vec2
        /// Where the short bend after the bounce ends.
        var bendEnd: Vec2
        /// How fast the ball has to set off, m/s, to leave the cushion at the speed asked for.
        var startSpeed: Double
    }

    /// Finds the bounce, then the start speed that gets the ball off the cushion fast enough, and
    /// repeats, because the bounce depends on how fast and how much rolling the ball arrives.
    /// `leavingSpeed` says how fast the ball must roll once it's off the cushion, given where its
    /// straight line starts. `spinShare` is its roll at the start, as a share of its speed.
    private func settledBounce(
        from a: Vec2, to b: Vec2, _ cushion: Cushion, _ table: TableProfile, spinShare: Double,
        leavingSpeed: (Vec2) -> Double
    ) -> Bounce? {
        let maxSpeed = 12.0
        var speed = 2.0
        var bounce: Bounce?
        for _ in 0..<5 {
            guard let hit = bouncePoint(from: a, to: b, cushion, table, startSpeed: speed, spinShare: spinShare) else { return nil }
            let wanted = leavingSpeed(hit.lineStart)
            var low = 0.05, high = maxSpeed
            for _ in 0..<40 {
                let mid = (low + high) / 2
                let off = offCushion(from: a, contact: hit.contact, cushion, table, startSpeed: mid, spinShare: spinShare)
                if (off?.speed ?? 0) < wanted { low = mid } else { high = mid }
            }
            guard high < maxSpeed * 0.99 else { return nil }
            speed = high
            let bend = offCushion(from: a, contact: hit.contact, cushion, table, startSpeed: speed, spinShare: spinShare)
            bounce = Bounce(contact: hit.contact, lineStart: hit.lineStart, bendEnd: bend?.bendEnd ?? hit.contact, startSpeed: speed)
        }
        return bounce
    }

    /// The cushion's frame: a unit vector along it, and its line's position across that.
    private func frame(_ cushion: Cushion, _ table: TableProfile) -> (along: Vec2, inward: Vec2, value: Double) {
        let line = table.cushionLine(cushion)
        let along = line.alongX ? Vec2(1, 0) : Vec2(0, 1)
        let sign: Double = line.value > 0 ? -1 : 1
        let inward = line.alongX ? Vec2(0, sign) : Vec2(sign, 0)
        return (along, inward, line.value)
    }

    /// What a ball sent from `a` does after touching the cushion at `contact`: where its straight
    /// leaving line starts, which way it goes, and how fast it rolls.
    private func offCushion(
        from a: Vec2, contact: Vec2, _ cushion: Cushion, _ table: TableProfile, startSpeed: Double, spinShare: Double
    ) -> (start: Vec2, direction: Vec2, speed: Double, bendEnd: Vec2)? {
        let f = frame(cushion, table)
        let toCushion = contact - a
        let length = toCushion.length
        guard length > 1 else { return nil }
        let arriving = CueBallPhysics.state(
            startSpeed: startSpeed, startSpin: spinShare * startSpeed, distance: length / 1000, config: config
        )
        guard arriving.speed > 0.01 else { return nil }
        let heading = toCushion / length
        let out = CueBallPhysics.rebound(
            along: arriving.speed * heading.dot(f.along),
            into: arriving.speed * -heading.dot(f.inward),
            spinShare: arriving.spin / arriving.speed,
            config: config
        )
        guard out.away > 1e-6 else { return nil }
        let leaving = f.along * out.along + f.inward * out.away
        let bendEnd = contact + (f.along * out.bendEnd.x + f.inward * out.bendEnd.y) * 1000
        return (contact + f.along * (out.lineOffset * 1000), leaving.normalized, leaving.length, bendEnd)
    }

    /// Where a ball sent from `a` at `startSpeed` m/s has to touch the cushion to get to `b`.
    /// It comes off flatter than a mirror and bends for a moment, see `CueBallPhysics.rebound`.
    func bouncePoint(
        from a: Vec2, to b: Vec2, _ cushion: Cushion, _ table: TableProfile, startSpeed: Double = 2, spinShare: Double = 0
    ) -> (contact: Vec2, lineStart: Vec2)? {
        let f = frame(cushion, table)
        let origin = (Vec2(1, 1) - f.along) * f.value
        func point(_ u: Double) -> Vec2 { origin + f.along * u }
        let aDepth = (a - origin).dot(f.inward), bDepth = (b - origin).dot(f.inward)
        guard aDepth > 1, bDepth > 1, startSpeed > 0 else { return nil }
        let aAlong = a.dot(f.along), bAlong = b.dot(f.along)

        // For a contact `u` along the cushion: how far along the leaving line is from b, at b's depth.
        func miss(_ u: Double) -> Double? {
            guard let off = offCushion(from: a, contact: point(u), cushion, table, startSpeed: startSpeed, spinShare: spinShare),
                  off.direction.dot(f.inward) > 1e-6 else { return nil }
            let along = off.start.dot(f.along) + bDepth * off.direction.dot(f.along) / off.direction.dot(f.inward)
            return along - bAlong
        }

        // Start from a plain mirror, walk until the miss changes sign, then halve the gap.
        var low = (bAlong * aDepth + aAlong * bDepth) / (aDepth + bDepth)
        guard let first = miss(low) else { return nil }
        let direction: Double = first > 0 ? -1 : 1
        var high = low
        var step = 2.0
        var bracketed = abs(first) < 0.01
        while !bracketed && step < 4000 {
            high = low + direction * step
            guard let next = miss(high) else { return nil }
            if (next > 0) != (first > 0) { bracketed = true } else { low = high; step *= 1.5 }
        }
        guard bracketed else { return nil }
        for _ in 0..<40 {
            let mid = (low + high) / 2
            guard let m = miss(mid), let l = miss(low) else { return nil }
            if (m > 0) == (l > 0) { low = mid } else { high = mid }
        }
        let contact = point((low + high) / 2)
        guard let off = offCushion(from: a, contact: contact, cushion, table, startSpeed: startSpeed, spinShare: spinShare) else { return nil }

        guard table.contains(ballCentre: contact, tolerance: 1) else { return nil }
        // A pocket mouth has no cushion to bounce off.
        for pocket in table.pockets where contact.distance(to: pocket.centre) < pocket.mouthWidth {
            return nil
        }
        return (contact, off.start)
    }

    private func isClear(_ path: [Vec2], ignoring ignored: Set<Int>, in state: TableState) -> Bool {
        let clearance = state.table.ballDiameterMm - 0.5
        for ball in state.balls where !ignored.contains(ball.id) {
            for (a, b) in zip(path, path.dropFirst()) where ball.position.distance(toSegment: a, b) < clearance {
                return false
            }
        }
        return true
    }

    /// How fast the object ball has to leave the cue ball, m/s, to reach the pocket at `arrivalSpeed`.
    /// A hit ball has no roll yet, so it slides before it rolls.
    private func objectStartSpeed(objectPath: [Vec2], objectBounce: Bounce?) -> Double {
        if let bounce = objectBounce { return bounce.startSpeed }
        return startSpeed(forContactSpeed: config.arrivalSpeed, distance: objectPath.pathLength / 1000, strike: .centre)
    }

    /// The cue ball speed needed at contact: a cut only passes on the share along the line of centres.
    private func contactSpeed(objectSpeed: Double, cut: Double) -> Double {
        objectSpeed / max(cos(cut), 0.15)
    }

    private func build(
        _ state: TableState,
        _ cue: Ball,
        _ target: Ball,
        _ pocket: Pocket,
        objectPath: [Vec2],
        objectBounce: Bounce? = nil,
        cueBounce: Bounce? = nil,
        kind: ShotKind
    ) -> ShotOption? {
        let table = state.table
        let d = table.ballDiameterMm
        let wanted = (objectPath[1] - objectPath[0]).normalized
        var line = wanted
        var ghost = ghostBall(object: target.position, direction: line, table)
        // After a cushion the cue ball arrives along the straight part of its bent path.
        let cueStart = cueBounce?.lineStart ?? cue.position

        var cut = angleBetween(ghost - cueStart, line)
        var throwShift = 0.0
        if config.useThrowCorrection {
            let correction = throwAngle(cutRadians: cut)
            let side = (ghost - cueStart).normalized.cross(line) >= 0 ? 1.0 : -1.0
            line = wanted.rotated(byRadians: side * correction)
            let corrected = ghostBall(object: target.position, direction: line, table)
            throwShift = corrected.distance(to: ghost)
            ghost = corrected
            cut = angleBetween(ghost - cueStart, line)
        }

        guard cut * 180 / .pi <= config.maxCutDegrees, table.contains(ballCentre: ghost) else { return nil }

        let lastLeg = (objectPath[objectPath.count - 1] - (objectBounce?.lineStart ?? objectPath[objectPath.count - 2])).normalized
        let opening = pocket.effectiveOpening(arrivingAlong: lastLeg)
        let margin = (opening - d) / 2
        guard margin > 1 else { return nil }

        let cuePrefix = cueBounce.map { [$0.contact] } ?? []
        let cuePath = [cue.position] + cuePrefix + [ghost]
        guard isClear(cuePath, ignoring: [cue.id, target.id], in: state) else { return nil }
        guard isClear(objectPath, ignoring: [cue.id, target.id], in: state) else { return nil }
        // Off a cushion the ball bends, then runs along a slightly different line from the drawn one.
        for (bounce, end) in [(cueBounce, ghost), (objectBounce, pocket.centre)] {
            guard let bounce else { continue }
            guard isClear([bounce.contact, bounce.bendEnd, end], ignoring: [cue.id, target.id], in: state) else { return nil }
        }

        let objectDistance = max(objectPath.pathLength, d) / 1000
        let cueDistance = max(cuePath.pathLength, d) / 1000
        let contactSpeed = contactSpeed(objectSpeed: objectStartSpeed(objectPath: objectPath, objectBounce: objectBounce), cut: cut)

        let incoming = (ghost - cueStart).normalized
        let after = chooseStrike(
            incoming: incoming, line: line, ghost: ghost, contactSpeed: contactSpeed,
            distance: cueDistance, kickSpeed: cueBounce?.startSpeed, state: state, cue: cue, target: target,
            objectReturn: objectBounce.map { [$0.lineStart, pocket.centre] } ?? []
        )
        // Every strike sends the cue ball across the object ball's way back off the cushion.
        guard !after.kiss else { return nil }
        let startSpeed = after.startSpeed

        // How far off the aim can be: the room at the pocket, scaled back to the cue ball.
        var tolerance = margin / (objectDistance * 1000) * d * cos(cut) / (cueDistance * 1000)
        if kind == .objectBank { tolerance *= config.bankTolerancePenalty }
        if kind == .kick { tolerance *= config.kickTolerancePenalty }
        let toleranceDegrees = tolerance * 180 / .pi
        if kind != .direct && toleranceDegrees < config.minCushionShotToleranceDegrees { return nil }

        var score = toleranceDegrees
        if after.scratch { score *= config.scratchPenalty }

        return ShotOption(
            id: "\(target.id)-\(pocket.name)-\(kind.rawValue)-\(objectPath.count)-\(cuePrefix.first.map { "\(Int($0.x)),\(Int($0.y))" } ?? "")",
            kind: kind,
            targetBallId: target.id,
            pocketName: pocket.name,
            ghostBall: ghost,
            cueBallPath: cuePath,
            objectBallPath: objectPath,
            cueBallAfterPath: after.path,
            strength: strength(for: startSpeed),
            startSpeed: startSpeed,
            strikePoint: after.strike,
            difficulty: difficulty(for: toleranceDegrees),
            cutDegrees: cut * 180 / .pi,
            aimToleranceDegrees: toleranceDegrees,
            throwCorrectionMm: throwShift,
            scratchRisk: after.scratch,
            score: score
        )
    }

    private func angleBetween(_ a: Vec2, _ b: Vec2) -> Double {
        acos(max(-1, min(1, a.normalized.dot(b.normalized))))
    }

    /// Contact friction pushes the object ball a little towards the side the cue ball is moving.
    /// It's limited by friction on a full ball and by the sideways speed on a thin one.
    func throwAngle(cutRadians cut: Double) -> Double {
        let normal = cos(cut)
        guard normal > 0.01 else { return 0 }
        return atan(min(config.ballToBallFriction * normal, sin(cut) / 7) / normal)
    }

    private func strength(for speed: Double) -> Strength {
        if speed < config.softBelowMetresPerSecond { return .soft }
        return speed < config.mediumBelowMetresPerSecond ? .medium : .firm
    }

    private func difficulty(for tolerance: Double) -> Difficulty {
        if tolerance >= config.easyAimToleranceDegrees { return .easy }
        return tolerance >= config.mediumAimToleranceDegrees ? .medium : .hard
    }

    /// The speed the cue ball needs off the tip to reach a point `distance` metres away at `speed`.
    /// The ball slides at first, and backspin makes it lose speed faster while it does, so the
    /// answer depends on where it's struck. Arrival speed only grows with start speed, so halve
    /// the range until it fits.
    func startSpeed(forContactSpeed speed: Double, distance: Double, strike: StrikePoint) -> Double {
        let spinShare = strike.spinRatio * config.strikeSpinRatio
        var low = speed * 0.5, high = max(speed * 6, 12)
        for _ in 0..<40 {
            let start = (low + high) / 2
            let arriving = CueBallPhysics.state(
                startSpeed: start, startSpin: spinShare * start, distance: distance, config: config
            ).speed
            if arriving < speed { low = start } else { high = start }
        }
        return high
    }

    private func chooseStrike(
        incoming: Vec2,
        line: Vec2,
        ghost: Vec2,
        contactSpeed: Double,
        distance: Double,
        kickSpeed: Double?,
        state: TableState,
        cue: Ball,
        target: Ball,
        objectReturn: [Vec2]
    ) -> (strike: StrikePoint, startSpeed: Double, path: [Vec2], scratch: Bool, kiss: Bool) {
        // A kick's bounce was worked out for a centre strike, so it keeps one.
        let choices: [StrikePoint] = config.adviseSpin && kickSpeed == nil ? [.centre, .top, .bottom] : [.centre]
        var first: (StrikePoint, Double, [Vec2], Bool)?
        var allKiss = true
        for strike in choices {
            let startSpeed: Double
            let contact: CueBallPhysics.State
            if let kickSpeed {
                startSpeed = kickSpeed
                // Off the cushion it's rolling again by the time it gets to the object ball.
                contact = CueBallPhysics.State(speed: contactSpeed, spin: contactSpeed)
            } else {
                startSpeed = self.startSpeed(forContactSpeed: contactSpeed, distance: distance, strike: strike)
                contact = CueBallPhysics.state(
                    startSpeed: startSpeed,
                    startSpin: strike.spinRatio * config.strikeSpinRatio * startSpeed,
                    distance: distance,
                    config: config
                )
            }
            let leaving = CueBallPhysics.directionAfterContact(
                incoming: incoming, objectDirection: line,
                contactSpeed: contact.speed, contactSpin: contact.spin
            )
            let trace = traceCueBall(
                from: ghost, direction: leaving.direction, speed: leaving.speed,
                state: state, ignoring: [cue.id, target.id]
            )
            // On a bank the object ball comes back off the cushion, and the cue ball mustn't be in its way.
            let kiss = paths(trace.path, objectReturn, comeWithin: state.table.ballDiameterMm)
            if kiss { continue }
            allKiss = false
            if first == nil { first = (strike, startSpeed, trace.path, trace.scratch) }
            if !trace.scratch { return (strike, startSpeed, trace.path, false, false) }
        }
        guard let first else { return (.centre, contactSpeed, [ghost], false, allKiss) }
        // Draw wears off on the way, so if everything scratches, try hitting harder with draw.
        if kickSpeed == nil && config.adviseSpin {
            for factor in [1.5, 2.0, 2.5] {
                let faster = contactSpeed * factor
                let startSpeed = self.startSpeed(forContactSpeed: faster, distance: distance, strike: .bottom)
                guard startSpeed <= config.maxStartSpeed else { break }
                let contact = CueBallPhysics.state(
                    startSpeed: startSpeed, startSpin: -config.strikeSpinRatio * startSpeed, distance: distance, config: config
                )
                let leaving = CueBallPhysics.directionAfterContact(
                    incoming: incoming, objectDirection: line, contactSpeed: contact.speed, contactSpin: contact.spin
                )
                let trace = traceCueBall(
                    from: ghost, direction: leaving.direction, speed: leaving.speed, state: state, ignoring: [cue.id, target.id]
                )
                if !trace.scratch && !paths(trace.path, objectReturn, comeWithin: state.table.ballDiameterMm) {
                    return (.bottom, startSpeed, trace.path, false, false)
                }
            }
        }
        return (first.0, first.1, first.2, first.3, false)
    }

    /// True when any part of one path comes closer than `gap` to any part of the other.
    func paths(_ p: [Vec2], _ q: [Vec2], comeWithin gap: Double) -> Bool {
        for (a, b) in zip(p, p.dropFirst()) {
            for (c, d) in zip(q, q.dropFirst()) {
                let ab = b - a, cd = d - c
                let denominator = ab.cross(cd)
                if abs(denominator) > 1e-9 {
                    let t = (c - a).cross(cd) / denominator
                    let u = (c - a).cross(ab) / denominator
                    if t >= 0, t <= 1, u >= 0, u <= 1 { return true }
                }
                let closest = min(
                    a.distance(toSegment: c, d), b.distance(toSegment: c, d),
                    c.distance(toSegment: a, b), d.distance(toSegment: a, b)
                )
                if closest < gap { return true }
            }
        }
        return false
    }

    /// Follows the cue ball after contact, off cushions, until it stops, hits a ball or finds a pocket.
    func traceCueBall(
        from start: Vec2,
        direction: Vec2,
        speed: Double,
        state: TableState,
        ignoring ignored: Set<Int>
    ) -> (path: [Vec2], scratch: Bool) {
        let table = state.table
        let roll = config.rollingFriction * CueBallPhysics.gravity
        var remaining = min(speed * speed / (2 * roll) * 1000, 6000)
        var position = table.clamped(ballCentre: start)
        var heading = direction
        var path = [position]
        guard heading.length > 0 else { return (path, false) }

        for _ in 0..<4 {
            guard remaining > 1 else { break }
            let (cushionHit, normal) = nextCushion(from: position, heading: heading, table)
            let legLength = min(remaining, position.distance(to: cushionHit))
            var end = position + heading * legLength

            let segmentEnd = end
            for pocket in table.pockets {
                let reach = pocket.mouthWidth / 2
                if pocket.centre.distance(toSegment: position, segmentEnd) < reach {
                    path.append(pocket.centre)
                    return (path, true)
                }
            }

            var hitBall = false
            for ball in state.balls where !ignored.contains(ball.id) {
                let t = firstContactDistance(from: position, heading: heading, ball: ball.position, table.ballDiameterMm)
                if let t, t >= 0, t < position.distance(to: end) {
                    end = position + heading * t
                    hitBall = true
                }
            }
            path.append(end)
            if hitBall { break }

            remaining -= position.distance(to: end)
            guard remaining > 1, let normal else { break }
            // Off the cushion as in CueBallPhysics.rebound, without drawing the short bend.
            let incoming = heading.dot(normal)
            let tangent = heading - normal * incoming
            let out = CueBallPhysics.rebound(along: tangent.length, into: -incoming, spinShare: 1, config: config)
            heading = (tangent + normal * out.away).normalized
            remaining *= out.along * out.along + out.away * out.away
            position = end
        }
        return (path, false)
    }

    private func nextCushion(from p: Vec2, heading h: Vec2, _ table: TableProfile) -> (Vec2, Vec2?) {
        let mx = table.lengthMm / 2 - table.ballRadiusMm
        let my = table.widthMm / 2 - table.ballRadiusMm
        var best = Double.greatestFiniteMagnitude
        var normal: Vec2?
        if h.x > 1e-9, (mx - p.x) / h.x < best { best = (mx - p.x) / h.x; normal = Vec2(-1, 0) }
        if h.x < -1e-9, (-mx - p.x) / h.x < best { best = (-mx - p.x) / h.x; normal = Vec2(1, 0) }
        if h.y > 1e-9, (my - p.y) / h.y < best { best = (my - p.y) / h.y; normal = Vec2(0, -1) }
        if h.y < -1e-9, (-my - p.y) / h.y < best { best = (-my - p.y) / h.y; normal = Vec2(0, 1) }
        return (p + h * max(0, best), normal)
    }

    private func firstContactDistance(from p: Vec2, heading h: Vec2, ball c: Vec2, _ diameter: Double) -> Double? {
        let toBall = c - p
        let along = toBall.dot(h)
        let offSquared = toBall.dot(toBall) - along * along
        let reach = diameter * diameter - offSquared
        guard reach >= 0 else { return nil }
        return along - reach.squareRoot()
    }
}
