import Foundation
import ShotEngine

/// Compares measured ball positions with the true ones. Used on generated scenes now, and on
/// ruler measurements from a real table later, with the same maths and pass marks.
public struct AccuracyReport: Sendable {
    public struct PassMarks: Sendable {
        public var medianMm = 5.0
        public var p95Mm = 10.0
        public var foundShare = 0.95
        public init() {}
    }

    public var errorsMm: [Double]
    public var trueBalls: Int
    public var falseBalls: Int

    public init(errorsMm: [Double], trueBalls: Int, falseBalls: Int) {
        self.errorsMm = errorsMm.sorted()
        self.trueBalls = trueBalls
        self.falseBalls = falseBalls
    }

    /// Pairs each true position with its nearest measured one, within one ball width.
    public static func compare(measured: [Vec2], truth: [Vec2], matchWithinMm: Double) -> AccuracyReport {
        var pairs: [(distance: Double, truth: Int, measured: Int)] = []
        for (t, tp) in truth.enumerated() {
            for (m, mp) in measured.enumerated() {
                let d = tp.distance(to: mp)
                if d <= matchWithinMm { pairs.append((d, t, m)) }
            }
        }
        pairs.sort { $0.distance < $1.distance }
        var usedTruth = Set<Int>(), usedMeasured = Set<Int>()
        var errors: [Double] = []
        for pair in pairs where !usedTruth.contains(pair.truth) && !usedMeasured.contains(pair.measured) {
            usedTruth.insert(pair.truth)
            usedMeasured.insert(pair.measured)
            errors.append(pair.distance)
        }
        return AccuracyReport(errorsMm: errors, trueBalls: truth.count, falseBalls: measured.count - usedMeasured.count)
    }

    public static func merged(_ reports: [AccuracyReport]) -> AccuracyReport {
        AccuracyReport(
            errorsMm: reports.flatMap(\.errorsMm),
            trueBalls: reports.reduce(0) { $0 + $1.trueBalls },
            falseBalls: reports.reduce(0) { $0 + $1.falseBalls }
        )
    }

    public var foundShare: Double { trueBalls > 0 ? Double(errorsMm.count) / Double(trueBalls) : 0 }

    public var medianMm: Double { percentile(0.5) }
    public var p95Mm: Double { percentile(0.95) }

    public func percentile(_ p: Double) -> Double {
        guard !errorsMm.isEmpty else { return .infinity }
        let index = min(errorsMm.count - 1, Int((Double(errorsMm.count) * p).rounded(.up)) - 1)
        return errorsMm[max(0, index)]
    }

    public func passes(_ marks: PassMarks = PassMarks()) -> Bool {
        medianMm <= marks.medianMm && p95Mm <= marks.p95Mm && foundShare >= marks.foundShare
    }

    public var summary: String {
        let found = String(format: "%.1f", foundShare * 100)
        return "median \(String(format: "%.1f", medianMm)) mm, 95% within \(String(format: "%.1f", p95Mm)) mm, "
            + "found \(found)% of \(trueBalls), false balls \(falseBalls)"
    }
}
