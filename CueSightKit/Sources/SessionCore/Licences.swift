import Foundation

public struct LicenceEntry: Hashable, Sendable {
    public var name: String
    public var licence: String
    public var note: String
}

public enum Licences {
    /// Everything the app ships with. It has no third-party libraries or models right now, so
    /// this only lists Apple's system frameworks. Add to it whenever a dependency comes in.
    public static let entries: [LicenceEntry] = [
        LicenceEntry(name: "ARKit, RealityKit, SwiftUI", licence: "Part of iOS", note: "Used through Apple's developer agreement."),
    ]
}
