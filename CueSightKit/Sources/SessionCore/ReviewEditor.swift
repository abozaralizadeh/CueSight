import Foundation
import ShotEngine

/// The player's fixes to a scan. One wrong ball makes all the advice wrong, so these matter.
public struct ReviewEditor: Equatable, Sendable {
    public private(set) var table: TableProfile
    public private(set) var balls: [Ball]
    public var lowConfidenceBelow = 0.55

    public init(table: TableProfile, balls: [Ball]) {
        self.table = table
        self.balls = balls
    }

    public var state: TableState { TableState(table: table, balls: balls) }

    public func needsCheck(_ ball: Ball) -> Bool {
        !ball.fixedByPlayer && ball.confidence < lowConfidenceBelow
    }

    public var problems: [String] {
        var list: [String] = []
        if !balls.contains(where: { $0.kind == .cue }) { list.append("Choose the cue ball.") }
        if balls.filter({ $0.kind != .cue }).isEmpty { list.append("Add at least one other ball.") }
        return list
    }

    public mutating func move(id: Int, to position: Vec2) {
        guard let i = balls.firstIndex(where: { $0.id == id }) else { return }
        let clamped = table.clamped(ballCentre: position)
        // Two balls can't share a spot, so stop the drag at the neighbour.
        let blocked = balls.contains {
            $0.id != id && $0.position.distance(to: clamped) < table.ballDiameterMm
        }
        guard !blocked else { return }
        balls[i].position = clamped
        balls[i].fixedByPlayer = true
        balls[i].confidence = 1
    }

    @discardableResult
    public mutating func add(at position: Vec2, kind: BallKind = .unknownObject) -> Ball? {
        let clamped = table.clamped(ballCentre: position)
        guard !balls.contains(where: { $0.position.distance(to: clamped) < table.ballDiameterMm }) else { return nil }
        let id = (balls.map(\.id).max() ?? 0) + 1
        let ball = Ball(id: id, position: clamped, kind: kind, confidence: 1, fixedByPlayer: true)
        balls.append(ball)
        return ball
    }

    public mutating func remove(id: Int) {
        balls.removeAll { $0.id == id }
    }

    /// There's only one cue ball, so the old one becomes an unknown object ball.
    public mutating func setCueBall(id: Int) {
        for i in balls.indices {
            if balls[i].id == id {
                balls[i].kind = .cue
                balls[i].fixedByPlayer = true
                balls[i].confidence = 1
            } else if balls[i].kind == .cue {
                balls[i].kind = .unknownObject
            }
        }
    }

    public mutating func setKind(id: Int, kind: BallKind) {
        if kind == .cue {
            setCueBall(id: id)
            return
        }
        guard let i = balls.firstIndex(where: { $0.id == id }) else { return }
        balls[i].kind = kind
        balls[i].fixedByPlayer = true
    }
}
