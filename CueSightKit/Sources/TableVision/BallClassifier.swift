import Foundation
import ShotEngine

/// Colour counts from pixels on a ball. Adding many views together gives a fairer picture of
/// a striped ball, which looks different from every side.
public struct ColourEvidence: Codable, Hashable, Sendable {
    public var samples = 0.0
    public var white = 0.0
    public var black = 0.0
    public var coloured = 0.0
    /// Sum of hue directions, so hues near 0 and 360 average correctly.
    public var hueX = 0.0
    public var hueY = 0.0
    public var saturationSum = 0.0
    public var valueSum = 0.0

    public init() {}

    public mutating func add(_ c: HSV) {
        samples += 1
        if c.value < 0.2 {
            black += 1
        } else if c.saturation < 0.25 && c.value > 0.45 {
            white += 1
        } else if c.saturation >= 0.25 {
            coloured += 1
            let a = c.hue * .pi / 180
            hueX += cos(a)
            hueY += sin(a)
            saturationSum += c.saturation
            valueSum += c.value
        }
    }

    public mutating func merge(_ o: ColourEvidence) {
        samples += o.samples
        white += o.white
        black += o.black
        coloured += o.coloured
        hueX += o.hueX
        hueY += o.hueY
        saturationSum += o.saturationSum
        valueSum += o.valueSum
    }

    public var whiteShare: Double { samples > 0 ? white / samples : 0 }
    public var blackShare: Double { samples > 0 ? black / samples : 0 }
    public var colouredShare: Double { samples > 0 ? coloured / samples : 0 }
    public var meanSaturation: Double { coloured > 0 ? saturationSum / coloured : 0 }
    public var meanValue: Double { coloured > 0 ? valueSum / coloured : 0 }

    public var hue: Double {
        let h = atan2(hueY, hueX) * 180 / .pi
        return h < 0 ? h + 360 : h
    }
}

public enum BallClassifier {
    public static func kind(_ e: ColourEvidence, game: Game) -> BallKind {
        guard e.samples > 0 else { return .unknownObject }
        switch game {
        case .pool: return pool(e)
        case .snooker: return snooker(e)
        }
    }

    /// How much this ball looks like the cue ball, from 0 to 1.
    public static func cueLikeness(_ e: ColourEvidence) -> Double {
        e.whiteShare
    }

    private static func pool(_ e: ColourEvidence) -> BallKind {
        if e.whiteShare > 0.72 { return .cue }
        if e.blackShare > 0.5 { return .eight }
        if e.whiteShare > 0.2 && e.colouredShare > 0.2 { return .stripe }
        if e.colouredShare > 0.3 || e.blackShare > 0.3 { return .solid }
        return .unknownObject
    }

    private static func snooker(_ e: ColourEvidence) -> BallKind {
        if e.whiteShare > 0.6 { return .cue }
        if e.blackShare > 0.55 { return .black }
        guard e.colouredShare > 0.2 else { return .unknownObject }
        let h = e.hue, s = e.meanSaturation, v = e.meanValue
        if h >= 185 && h < 275 { return .blue }
        if h >= 75 && h < 185 { return .green }
        if h >= 42 && h < 75 { return .yellow }
        // What's left is the warm end: red, brown and pink.
        if s < 0.62 && v > 0.55 { return .pink }
        if v < 0.55 && h >= 8 && h < 42 { return .brown }
        return .red
    }
}
