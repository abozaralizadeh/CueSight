import Foundation
import ShotEngine

/// Merges sightings from many frames into one position per ball. Each sighting is weighted by
/// how well its viewing angle pins the ball down, so looking from two sides helps a lot.
public struct BallTracker: Sendable {
    public struct Track: Sendable {
        var infoXX: Double, infoXY: Double, infoYY: Double
        var weightedX: Double, weightedY: Double
        var count: Int
        var scoreSum: Double
        var colour: ColourEvidence
        var sightings: [Sighting] = []
        /// Frames in which this spot was in view, found or not.
        var views = 0

        init(_ s: Sighting) {
            infoXX = s.informationXX
            infoXY = s.informationXY
            infoYY = s.informationYY
            weightedX = s.informationXX * s.position.x + s.informationXY * s.position.y
            weightedY = s.informationXY * s.position.x + s.informationYY * s.position.y
            count = 1
            scoreSum = s.score
            colour = s.colour
            sightings = [s]
        }

        mutating func add(_ s: Sighting) {
            infoXX += s.informationXX
            infoXY += s.informationXY
            infoYY += s.informationYY
            weightedX += s.informationXX * s.position.x + s.informationXY * s.position.y
            weightedY += s.informationXY * s.position.x + s.informationYY * s.position.y
            count += 1
            scoreSum += s.score
            colour.merge(s.colour)
            sightings.append(s)
        }

        var position: Vec2 {
            let det = infoXX * infoYY - infoXY * infoXY
            guard det > 0 else { return .zero }
            return Vec2(
                (infoYY * weightedX - infoXY * weightedY) / det,
                (infoXX * weightedY - infoXY * weightedX) / det
            )
        }
    }

    public var table: TableProfile
    public private(set) var tracks: [Track] = []
    public var minSightings = 3
    /// A real ball is found in most frames that can see it. Noise isn't.
    public var minFoundShare = 0.5

    public init(table: TableProfile) {
        self.table = table
    }

    public mutating func add(_ sightings: [Sighting]) {
        let gate = table.ballDiameterMm * 0.75
        for sighting in sightings {
            var bestIndex: Int?
            var bestDistance = Double.infinity
            for (i, track) in tracks.enumerated() {
                let d = track.position.distance(to: sighting.position)
                if d < bestDistance {
                    bestDistance = d
                    bestIndex = i
                }
            }
            // Sightings from a low angle are long and thin, so give the gate some extra room
            // along the weak direction by testing with the sighting's own information.
            if let i = bestIndex, bestDistance < gate || withinGate(tracks[i].position, sighting) {
                tracks[i].add(sighting)
            } else {
                tracks.append(Track(sighting))
            }
        }
    }

    /// Call once per frame, after `add`, with a test for whether a table spot was in view.
    public mutating func noteFrame(isVisible: (Vec2) -> Bool) {
        for i in tracks.indices where isVisible(tracks[i].position) {
            tracks[i].views += 1
        }
    }

    private func withinGate(_ p: Vec2, _ s: Sighting) -> Bool {
        let d = p - s.position
        guard d.length < table.ballDiameterMm * 2 else { return false }
        let m = d.x * d.x * s.informationXX + 2 * d.x * d.y * s.informationXY + d.y * d.y * s.informationYY
        return m < 12
    }

    /// How well the views agree with each other, as a typical error in units of expected noise.
    /// Around 1 is healthy. A wrong table size or a table in the wrong place pushes it up,
    /// because each side of the table then sees the balls shifted a different way.
    public var viewDisagreement: Double {
        var values: [Double] = []
        for track in tracks where track.count >= minSightings {
            let p = track.position
            var total = 0.0
            for s in track.sightings {
                let d = p - s.position
                total += d.x * d.x * s.informationXX + 2 * d.x * d.y * s.informationXY + d.y * d.y * s.informationYY
            }
            values.append((total / Double(track.count)).squareRoot())
        }
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    public func finish() -> [Ball] {
        var usable = tracks.filter {
            $0.count >= minSightings && ($0.views == 0 || Double($0.count) >= minFoundShare * Double($0.views))
        }
        usable.sort { $0.count > $1.count }

        // Two tracks closer than a ball width can't both be real, so keep the stronger.
        var kept: [Track] = []
        for track in usable
        where !kept.contains(where: { $0.position.distance(to: track.position) < table.ballDiameterMm * 0.9 }) {
            kept.append(track)
        }

        let mostSightings = Double(kept.map(\.count).max() ?? 1)
        var balls = kept.enumerated().map { index, track in
            Ball(
                id: index + 1,
                position: table.clamped(ballCentre: track.position),
                kind: BallClassifier.kind(track.colour, game: table.game),
                confidence: min(1, track.scoreSum / Double(track.count)) * min(1, Double(track.count) / min(mostSightings, 6))
            )
        }

        // There's one cue ball. If colour finds several, keep the whitest. If it finds none,
        // the whitest ball is still the best guess, and review lets the player change it.
        let whitest = kept.indices.max { BallClassifier.cueLikeness(kept[$0].colour) < BallClassifier.cueLikeness(kept[$1].colour) }
        if let whitest {
            for i in balls.indices where balls[i].kind == .cue && i != whitest {
                balls[i].kind = .unknownObject
                balls[i].confidence *= 0.5
            }
            if balls[whitest].kind != .cue, BallClassifier.cueLikeness(kept[whitest].colour) > 0.3 {
                balls[whitest].kind = .cue
                balls[whitest].confidence *= 0.6
            }
        }
        return balls
    }
}
