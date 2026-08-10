import Foundation
import TOML

public struct AppConfiguration: Equatable, Sendable {
    public static let defaults = AppConfiguration(
        hotkey: "control+e",
        showMenuBarIcon: true
    )

    public var hotkey: String
    public var showMenuBarIcon: Bool

    public init(hotkey: String, showMenuBarIcon: Bool) {
        self.hotkey = hotkey
        self.showMenuBarIcon = showMenuBarIcon
    }
}

public enum AppConfigurationKey: String, CaseIterable, Codable, Sendable {
    case hotkey
    case showMenuBarIcon = "show-menu-bar-icon"

    public var valueType: String {
        switch self {
        case .hotkey: "string"
        case .showMenuBarIcon: "boolean"
        }
    }

    public var documentation: String {
        switch self {
        case .hotkey:
            "Global recording shortcut, such as control+e or command+shift+space."
        case .showMenuBarIcon:
            "Whether Reco's waveform icon appears in the menu bar."
        }
    }
}

public enum AppConfigurationValue: Equatable, Sendable, Codable {
    case string(String)
    case boolean(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        }
    }

    public var displayValue: String {
        switch self {
        case .string(let value): value
        case .boolean(let value): value ? "true" : "false"
        }
    }
}

public enum AppConfigurationSource: String, Codable, Sendable {
    case defaults
    case user
}

public struct AppConfigurationEntry: Equatable, Sendable, Codable {
    public var key: AppConfigurationKey
    public var value: AppConfigurationValue
    public var source: AppConfigurationSource
    public var documentation: String

    public init(
        key: AppConfigurationKey,
        value: AppConfigurationValue,
        source: AppConfigurationSource,
        documentation: String
    ) {
        self.key = key
        self.value = value
        self.source = source
        self.documentation = documentation
    }
}

public enum AppConfigurationError: LocalizedError, Sendable {
    case invalidKey(String)
    case invalidValue(key: String, value: String, reason: String)
    case invalidFile(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let key):
            "Unknown configuration key '\(key)'."
        case .invalidValue(let key, let value, let reason):
            "Invalid value '\(value)' for \(key): \(reason)"
        case .invalidFile(let path, let reason):
            "Invalid configuration at \(path): \(reason)"
        }
    }
}

public struct HotkeySetting: Equatable, Sendable {
    public enum Modifier: String, CaseIterable, Sendable {
        case control
        case option
        case shift
        case command
    }

    public let modifiers: [Modifier]
    public let key: String

    public init(_ value: String) throws {
        let pieces =
            value
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard pieces.count >= 2, let rawKey = pieces.last, !rawKey.isEmpty else {
            throw AppConfigurationError.invalidValue(
                key: AppConfigurationKey.hotkey.rawValue,
                value: value,
                reason: "use at least one modifier and one key"
            )
        }

        var parsedModifiers: Set<Modifier> = []
        for rawModifier in pieces.dropLast() {
            let modifier: Modifier?
            switch rawModifier {
            case "control", "ctrl": modifier = .control
            case "option", "alt": modifier = .option
            case "shift": modifier = .shift
            case "command", "cmd": modifier = .command
            default: modifier = nil
            }
            guard let modifier, parsedModifiers.insert(modifier).inserted else {
                throw AppConfigurationError.invalidValue(
                    key: AppConfigurationKey.hotkey.rawValue,
                    value: value,
                    reason: "unknown or repeated modifier '\(rawModifier)'"
                )
            }
        }

        let normalizedKey = Self.normalizeKey(rawKey)
        guard Self.supportedKeys.contains(normalizedKey) else {
            throw AppConfigurationError.invalidValue(
                key: AppConfigurationKey.hotkey.rawValue,
                value: value,
                reason: "unsupported key '\(rawKey)'"
            )
        }

        modifiers = Modifier.allCases.filter { parsedModifiers.contains($0) }
        key = normalizedKey
    }

    public var canonicalValue: String {
        (modifiers.map(\.rawValue) + [key]).joined(separator: "+")
    }

    private static func normalizeKey(_ key: String) -> String {
        switch key {
        case "escape": "esc"
        case "left-arrow", "arrow-left": "left"
        case "right-arrow", "arrow-right": "right"
        case "up-arrow", "arrow-up": "up"
        case "down-arrow", "arrow-down": "down"
        default: key
        }
    }

    private static let supportedKeys: Set<String> = {
        var keys = Set("abcdefghijklmnopqrstuvwxyz".map(String.init))
        keys.formUnion((0...9).map(String.init))
        keys.formUnion((1...12).map { "f\($0)" })
        keys.formUnion([
            "space", "return", "tab", "delete", "esc", "left", "right", "up", "down",
            "=", "-", "]", "[", "'", ";", "\\", ",", "/", ".", "`",
        ])
        return keys
    }()
}

public struct AppConfigurationStore: Sendable {
    public static let changeNotification = Notification.Name("com.danielcorin.Reco.configurationChanged")

    public let fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let baseDirectory: URL
        if let configured = environment["XDG_CONFIG_HOME"],
            !configured.isEmpty,
            configured.hasPrefix("/")
        {
            baseDirectory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            baseDirectory = homeDirectory.appendingPathComponent(".config", isDirectory: true)
        }
        return
            baseDirectory
            .appendingPathComponent("reco", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    public func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    public func load() throws -> AppConfiguration {
        try resolvedConfiguration(from: loadOverrides())
    }

    public func validate() throws {
        _ = try load()
    }

    public func entry(for key: AppConfigurationKey) throws -> AppConfigurationEntry {
        let overrides = try loadOverrides()
        let configuration = try resolvedConfiguration(from: overrides)
        return entry(for: key, configuration: configuration, overrides: overrides)
    }

    public func entries(changesOnly: Bool) throws -> [AppConfigurationEntry] {
        let overrides = try loadOverrides()
        let configuration = try resolvedConfiguration(from: overrides)
        return AppConfigurationKey.allCases.compactMap { key in
            let entry = entry(for: key, configuration: configuration, overrides: overrides)
            return !changesOnly || entry.source == .user ? entry : nil
        }
    }

    @discardableResult
    public func set(_ key: AppConfigurationKey, value: String) throws -> AppConfiguration {
        try set([key: value])
    }

    @discardableResult
    public func set(_ values: [AppConfigurationKey: String]) throws -> AppConfiguration {
        var overrides = try loadOverrides()
        for (key, value) in values {
            switch key {
            case .hotkey:
                let normalized = try HotkeySetting(value).canonicalValue
                overrides.hotkey = normalized == AppConfiguration.defaults.hotkey ? nil : normalized
            case .showMenuBarIcon:
                guard value == "true" || value == "false" else {
                    throw AppConfigurationError.invalidValue(
                        key: key.rawValue,
                        value: value,
                        reason: "expected true or false"
                    )
                }
                let enabled = value == "true"
                overrides.showMenuBarIcon =
                    enabled == AppConfiguration.defaults.showMenuBarIcon
                    ? nil : enabled
            }
        }
        try write(overrides)
        return try resolvedConfiguration(from: overrides)
    }

    @discardableResult
    public func unset(_ key: AppConfigurationKey) throws -> AppConfiguration {
        var overrides = try loadOverrides()
        switch key {
        case .hotkey: overrides.hotkey = nil
        case .showMenuBarIcon: overrides.showMenuBarIcon = nil
        }
        try write(overrides)
        return try resolvedConfiguration(from: overrides)
    }

    private func entry(
        for key: AppConfigurationKey,
        configuration: AppConfiguration,
        overrides: ConfigurationOverrides
    ) -> AppConfigurationEntry {
        switch key {
        case .hotkey:
            AppConfigurationEntry(
                key: key,
                value: .string(configuration.hotkey),
                source: overrides.hotkey == nil ? .defaults : .user,
                documentation: key.documentation
            )
        case .showMenuBarIcon:
            AppConfigurationEntry(
                key: key,
                value: .boolean(configuration.showMenuBarIcon),
                source: overrides.showMenuBarIcon == nil ? .defaults : .user,
                documentation: key.documentation
            )
        }
    }

    private func loadOverrides() throws -> ConfigurationOverrides {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ConfigurationOverrides()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try TOMLDecoder().decode(ConfigurationOverrides.self, from: data)
        } catch {
            throw AppConfigurationError.invalidFile(
                path: fileURL.path,
                reason: String(describing: error)
            )
        }
    }

    private func resolvedConfiguration(
        from overrides: ConfigurationOverrides
    ) throws -> AppConfiguration {
        let hotkey =
            try overrides.hotkey.map { try HotkeySetting($0).canonicalValue }
            ?? AppConfiguration.defaults.hotkey
        return AppConfiguration(
            hotkey: hotkey,
            showMenuBarIcon: overrides.showMenuBarIcon
                ?? AppConfiguration.defaults.showMenuBarIcon
        )
    }

    private func write(_ overrides: ConfigurationOverrides) throws {
        let fileManager = FileManager.default
        if overrides.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            return
        }

        try prepareDirectory()
        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(overrides)
        let header = """
            # Reco configuration
            # Only values that differ from Reco's built-in defaults are stored here.
            # Use `reco config list --all` to inspect the effective configuration.

            """
        var data = Data(header.utf8)
        data.append(encoded)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

private struct ConfigurationOverrides: Codable, Sendable {
    var hotkey: String?
    var showMenuBarIcon: Bool?

    var isEmpty: Bool {
        hotkey == nil && showMenuBarIcon == nil
    }

    init(hotkey: String? = nil, showMenuBarIcon: Bool? = nil) {
        self.hotkey = hotkey
        self.showMenuBarIcon = showMenuBarIcon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let knownKeys = Set(AppConfigurationKey.allCases.map(\.rawValue))
        if let unknown = container.allKeys.map(\.stringValue).first(where: { !knownKeys.contains($0) }) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown configuration key '\(unknown)'."
                )
            )
        }
        hotkey = try container.decodeIfPresent(
            String.self,
            forKey: DynamicCodingKey(AppConfigurationKey.hotkey.rawValue)
        )
        showMenuBarIcon = try container.decodeIfPresent(
            Bool.self,
            forKey: DynamicCodingKey(AppConfigurationKey.showMenuBarIcon.rawValue)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encodeIfPresent(
            hotkey,
            forKey: DynamicCodingKey(AppConfigurationKey.hotkey.rawValue)
        )
        try container.encodeIfPresent(
            showMenuBarIcon,
            forKey: DynamicCodingKey(AppConfigurationKey.showMenuBarIcon.rawValue)
        )
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
