import Foundation
import ShotEngine
import TableVision

/// Takes shots advised from measured positions and plays them on the true positions.
/// That shows how much measuring error costs, with a perfect player and a perfect stroke.
public struct AdviceCheck: Sendable {
    public var config = ShotConfig()
    public var rules: RulesContext = .free

    public init() {}

    public struct Result: Sendable {
        public var played = 0
        public var potted = 0
        public var perfectInfoPotted = 0

        public init() {}

        public var rate: Double { played > 0 ? Double(potted) / Double(played) : 0 }
        public var perfectRate: Double { played > 0 ? Double(perfectInfoPotted) / Double(played) : 0 }

        public mutating func merge(_ o: Result) {
            played += o.played
            potted += o.potted
            perfectInfoPotted += o.perfectInfoPotted
        }
    }

    public func run(truth: TableState, measured: [Ball]) -> Result {
        var result = Result()
        let measuredState = TableState(table: truth.table, balls: measured)
        guard let cue = measuredState.cueBall, let trueCue = truth.cueBall else { return result }
        // Advice only makes sense if the app picked the right cue ball.
        guard cue.position.distance(to: trueCue.position) < truth.table.ballDiameterMm else { return result }

        let simulator = ShotSimulator(config: config)
        for shot in ShotFinder(config: config).findShots(in: measuredState, rules: rules) {
            guard
                let measuredTarget = measured.first(where: { $0.id == shot.targetBallId }),
                let trueTarget = truth.balls.min(by: {
                    $0.position.distance(to: measuredTarget.position) < $1.position.distance(to: measuredTarget.position)
                }),
                trueTarget.position.distance(to: measuredTarget.position) < truth.table.ballDiameterMm
            else { continue }

            result.played += 1
            // The cue ball really is at its true spot, so the shot is played along the advised
            // line from there, aimed at the ghost ball the app showed.
            var played = shot
            played.cueBallPath[0] = trueCue.position
            if simulator.play(played, on: truth).pottedIds.contains(trueTarget.id) {
                result.potted += 1
            }

            let finder = ShotFinder(config: config)
            if let best = finder.findShots(in: truth, targetBallId: trueTarget.id).first(where: {
                $0.pocketName == shot.pocketName && $0.kind == shot.kind
            }), simulator.play(best, on: truth).pottedIds.contains(trueTarget.id) {
                result.perfectInfoPotted += 1
            }
        }
        return result
    }
}
