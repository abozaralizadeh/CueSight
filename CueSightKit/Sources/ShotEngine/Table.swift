import Foundation

public enum Game: String, Codable, CaseIterable, Sendable {
    case pool
    case snooker
}

public struct Pocket: Codable, Hashable, Sendable {
    public var name: String
    /// The middle of the pocket mouth.
    public var centre: Vec2
    public var jawLeft: Vec2
    public var jawRight: Vec2
    /// Points from the table into the pocket.
    public var inward: Vec2

    public var mouthWidth: Double { jawLeft.distance(to: jawRight) }

    /// How wide the mouth looks to a ball arriving along `direction`.
    public func effectiveOpening(arrivingAlong direction: Vec2) -> Double {
        mouthWidth * max(0, direction.normalized.dot(inward))
    }
}

public enum Cushion: String, CaseIterable, Codable, Sendable {
    case top, bottom, left, right
}

/// Coordinates are millimetres, with the origin at the centre of the playing area.
/// x runs along the long side and y along the short side.
public struct TableProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var game: Game
    public var lengthMm: Double
    public var widthMm: Double
    public var ballDiameterMm: Double
    public var cornerMouthMm: Double
    public var sideMouthMm: Double

    public init(
        id: String,
        name: String,
        game: Game,
        lengthMm: Double,
        widthMm: Double,
        ballDiameterMm: Double,
        cornerMouthMm: Double,
        sideMouthMm: Double
    ) {
        self.id = id
        self.name = name
        self.game = game
        self.lengthMm = lengthMm
        self.widthMm = widthMm
        self.ballDiameterMm = ballDiameterMm
        self.cornerMouthMm = cornerMouthMm
        self.sideMouthMm = sideMouthMm
    }

    public var ballRadiusMm: Double { ballDiameterMm / 2 }

    public static let pool7 = TableProfile(
        id: "pool7", name: "7 ft pool", game: .pool, lengthMm: 1981, widthMm: 991,
        ballDiameterMm: 57.15, cornerMouthMm: 121, sideMouthMm: 135
    )
    public static let pool8 = TableProfile(
        id: "pool8", name: "8 ft pool", game: .pool, lengthMm: 2235, widthMm: 1118,
        ballDiameterMm: 57.15, cornerMouthMm: 121, sideMouthMm: 135
    )
    public static let pool9 = TableProfile(
        id: "pool9", name: "9 ft pool", game: .pool, lengthMm: 2540, widthMm: 1270,
        ballDiameterMm: 57.15, cornerMouthMm: 117, sideMouthMm: 133
    )
    public static let snooker12 = TableProfile(
        id: "snooker12", name: "Full-size snooker", game: .snooker, lengthMm: 3569, widthMm: 1778,
        ballDiameterMm: 52.5, cornerMouthMm: 88, sideMouthMm: 108
    )
    public static let snooker10 = TableProfile(
        id: "snooker10", name: "10 ft snooker", game: .snooker, lengthMm: 2972, widthMm: 1486,
        ballDiameterMm: 52.5, cornerMouthMm: 88, sideMouthMm: 108
    )

    public static let standard: [TableProfile] = [.pool7, .pool8, .pool9, .snooker10, .snooker12]

    public static func custom(game: Game, lengthMm: Double, widthMm: Double) -> TableProfile {
        let base: TableProfile = game == .pool ? .pool9 : .snooker12
        var table = base
        table.id = "custom-\(game.rawValue)-\(Int(lengthMm))x\(Int(widthMm))"
        table.name = "Custom \(game.rawValue) \(Int(lengthMm)) x \(Int(widthMm)) mm"
        table.lengthMm = lengthMm
        table.widthMm = widthMm
        return table
    }

    public var pockets: [Pocket] {
        let hl = lengthMm / 2, hw = widthMm / 2
        let cornerStep = cornerMouthMm / 2.0.squareRoot()
        let halfSide = sideMouthMm / 2
        func corner(_ name: String, _ sx: Double, _ sy: Double) -> Pocket {
            let a = Vec2(sx * (hl - cornerStep), sy * hw)
            let b = Vec2(sx * hl, sy * (hw - cornerStep))
            return Pocket(
                name: name, centre: (a + b) / 2, jawLeft: a, jawRight: b,
                inward: Vec2(sx, sy).normalized
            )
        }
        func side(_ name: String, _ sy: Double) -> Pocket {
            Pocket(
                name: name, centre: Vec2(0, sy * hw),
                jawLeft: Vec2(-halfSide, sy * hw), jawRight: Vec2(halfSide, sy * hw),
                inward: Vec2(0, sy)
            )
        }
        return [
            corner("top left", -1, 1), side("top side", 1), corner("top right", 1, 1),
            corner("bottom left", -1, -1), side("bottom side", -1), corner("bottom right", 1, -1),
        ]
    }

    /// True when a ball centre at this point is on the cloth, allowing for the cushions.
    public func contains(ballCentre p: Vec2, tolerance: Double = 0.5) -> Bool {
        abs(p.x) <= lengthMm / 2 - ballRadiusMm + tolerance
            && abs(p.y) <= widthMm / 2 - ballRadiusMm + tolerance
    }

    /// Keeps a ball centre on the cloth.
    public func clamped(ballCentre p: Vec2) -> Vec2 {
        let mx = lengthMm / 2 - ballRadiusMm, my = widthMm / 2 - ballRadiusMm
        return Vec2(max(-mx, min(mx, p.x)), max(-my, min(my, p.y)))
    }

    /// The line a ball centre touches when it reaches this cushion: a mirror axis plus a coordinate.
    func cushionLine(_ cushion: Cushion) -> (alongX: Bool, value: Double) {
        switch cushion {
        case .top: return (true, widthMm / 2 - ballRadiusMm)
        case .bottom: return (true, -(widthMm / 2 - ballRadiusMm))
        case .right: return (false, lengthMm / 2 - ballRadiusMm)
        case .left: return (false, -(lengthMm / 2 - ballRadiusMm))
        }
    }
}
