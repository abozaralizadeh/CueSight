import Foundation

public enum EightBallGroup: String, Codable, CaseIterable, Sendable {
    case open, solids, stripes
}

public enum SnookerTurn: String, Codable, CaseIterable, Sendable {
    case red, colour
}

/// What the player is allowed to hit first.
public enum RulesContext: Codable, Hashable, Sendable {
    /// No rules. Every object ball is fair game.
    case free
    case eightBall(EightBallGroup)
    case snooker(SnookerTurn)

    public func legalTargets(in balls: [Ball]) -> [Ball] {
        let objects = balls.filter { $0.kind != .cue }
        switch self {
        case .free:
            return objects
        case .eightBall(let group):
            return eightBallTargets(objects, group)
        case .snooker(let turn):
            return snookerTargets(objects, turn)
        }
    }

    private func eightBallTargets(_ objects: [Ball], _ group: EightBallGroup) -> [Ball] {
        let unknown = objects.filter { $0.kind == .unknownObject }
        let eight = objects.filter { $0.kind == .eight }
        switch group {
        case .open:
            return objects.filter { $0.kind != .eight }
        case .solids:
            let mine = objects.filter { $0.kind == .solid } + unknown
            return mine.isEmpty ? eight : mine
        case .stripes:
            let mine = objects.filter { $0.kind == .stripe } + unknown
            return mine.isEmpty ? eight : mine
        }
    }

    private func snookerTargets(_ objects: [Ball], _ turn: SnookerTurn) -> [Ball] {
        let reds = objects.filter { $0.kind == .red }
        let unknown = objects.filter { $0.kind == .unknownObject }
        switch turn {
        case .red where !reds.isEmpty:
            return reds + unknown
        case .colour:
            return objects.filter { $0.kind.isColourInSnooker } + unknown
        case .red:
            // No reds left, so the lowest colour on the table is next.
            for colour in BallKind.snookerColourOrder {
                let match = objects.filter { $0.kind == colour }
                if !match.isEmpty { return match + unknown }
            }
            return unknown
        }
    }
}
