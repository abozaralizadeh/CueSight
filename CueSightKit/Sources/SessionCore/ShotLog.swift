import Foundation
import ShotEngine

/// What testers report, kept so the difficulty bands can be tuned from real shots.
public struct ShotResult: Codable, Hashable, Sendable {
    public var difficulty: Difficulty
    public var kind: ShotKind
    public var aimToleranceDegrees: Double
    public var potted: Bool

    public init(difficulty: Difficulty, kind: ShotKind, aimToleranceDegrees: Double, potted: Bool) {
        self.difficulty = difficulty
        self.kind = kind
        self.aimToleranceDegrees = aimToleranceDegrees
        self.potted = potted
    }

    public var logLine: String {
        "shot-result difficulty=\(difficulty.rawValue) kind=\(kind.rawValue) "
            + "tolerance=\(String(format: "%.3f", aimToleranceDegrees)) potted=\(potted)"
    }

    public init?(logLine: String) {
        guard let start = logLine.range(of: "shot-result ") else { return nil }
        var fields: [String: String] = [:]
        for part in logLine[start.upperBound...].split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        guard
            let difficulty = fields["difficulty"].flatMap(Difficulty.init(rawValue:)),
            let kind = fields["kind"].flatMap(ShotKind.init(rawValue:)),
            let tolerance = fields["tolerance"].flatMap(Double.init),
            let potted = fields["potted"].flatMap(Bool.init)
        else { return nil }
        self.init(difficulty: difficulty, kind: kind, aimToleranceDegrees: tolerance, potted: potted)
    }
}

public enum ShotLogSummary {
    /// Pot rate per difficulty band. A band is working if easy beats medium and medium beats hard.
    public static func potRates(_ results: [ShotResult]) -> [Difficulty: (potted: Int, total: Int)] {
        var rates: [Difficulty: (potted: Int, total: Int)] = [:]
        for result in results {
            var entry = rates[result.difficulty] ?? (0, 0)
            entry.total += 1
            if result.potted { entry.potted += 1 }
            rates[result.difficulty] = entry
        }
        return rates
    }
}

/// CSV for accuracy tests: a line per ball, `x_mm,y_mm`, with an optional header.
public enum PositionsCSV {
    public static func parse(_ text: String) -> [Vec2] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ",")
            guard parts.count >= 2,
                let x = Double(parts[parts.count - 2].trimmingCharacters(in: .whitespaces)),
                let y = Double(parts[parts.count - 1].trimmingCharacters(in: .whitespaces))
            else { return nil }
            return Vec2(x, y)
        }
    }

    public static func format(_ balls: [Ball]) -> String {
        "kind,x_mm,y_mm\n" + balls.map {
            "\($0.kind.rawValue),\(String(format: "%.1f", $0.position.x)),\(String(format: "%.1f", $0.position.y))"
        }.joined(separator: "\n") + "\n"
    }
}
