import Foundation

/// SplitMix64, so every generated scene can be repeated from its seed.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }

    public mutating func range(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * unit()
    }

    /// Normal distribution with mean 0.
    public mutating func gaussian(_ sigma: Double = 1) -> Double {
        let a = max(unit(), 1e-12), b = unit()
        return sigma * (-2 * log(a)).squareRoot() * cos(2 * .pi * b)
    }
}
