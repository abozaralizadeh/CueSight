import Foundation
import ShotEngine

public struct AppSettings: Codable, Equatable, Sendable {
    public var firstRunDone = false
    public var useInches = false
    public var testerMode = false
    /// Uses a generated table in place of the camera. Always on in the Simulator.
    public var demoMode = false
    public var selectedTableId = TableProfile.pool9.id
    public var rules: SavedRules = .free

    public init() {}

    /// Rules the player picked. Only the kind is kept between sessions.
    public enum SavedRules: String, Codable, CaseIterable, Sendable {
        case free, eightBall, snooker
    }
}

/// Saved tables and settings, as small JSON files. There's no account and nothing leaves the phone.
public final class TableStore: @unchecked Sendable {
    private let tablesURL: URL
    private let settingsURL: URL

    public init(directory: URL) {
        tablesURL = directory.appendingPathComponent("tables.json")
        settingsURL = directory.appendingPathComponent("settings.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func customTables() -> [TableProfile] {
        guard let data = try? Data(contentsOf: tablesURL) else { return [] }
        return (try? JSONDecoder().decode([TableProfile].self, from: data)) ?? []
    }

    public func allTables() -> [TableProfile] {
        TableProfile.standard + customTables()
    }

    public func save(custom table: TableProfile) throws {
        var tables = customTables().filter { $0.id != table.id }
        tables.append(table)
        try JSONEncoder().encode(tables).write(to: tablesURL, options: .atomic)
    }

    public func delete(customId id: String) throws {
        let tables = customTables().filter { $0.id != id }
        try JSONEncoder().encode(tables).write(to: tablesURL, options: .atomic)
    }

    public func settings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return AppSettings() }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public func save(settings: AppSettings) throws {
        try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
    }
}
