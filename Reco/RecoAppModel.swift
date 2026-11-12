import AppKit
import Combine
import Darwin
import Foundation
import RecoCore

@MainActor
final class RecoAppModel: ObservableObject {
    static let shared = RecoAppModel()

    @Published private(set) var configuration: AppConfiguration
    @Published private(set) var configurationError: String?

    let coordinator: DictationCoordinator
    let usage = UsageTracker()
    let configurationStore: AppConfigurationStore

    private var directoryWatcher: ConfigurationDirectoryWatcher?
    private var distributedObserver: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?
    private var recordingServer: RecordingServer?

    private init() {
        let store = AppConfigurationStore()
        configurationStore = store

        var initialConfiguration = AppConfiguration.defaults
        var initialError: String?
        do {
            try Self.migrateLegacyPreferencesIfNeeded(to: store)
            initialConfiguration = try store.load()
        } catch {
            initialError = error.localizedDescription
        }

        configuration = initialConfiguration
        configurationError = initialError
        let initialHotkey =
            (try? Hotkey.from(configurationValue: initialConfiguration.hotkey))
            ?? .defaultHotkey
        coordinator = DictationCoordinator(initialHotkey: initialHotkey)
        coordinator.onHotkeyChanged = { [weak self] hotkey in
            guard let self else { return }
            try self.persist(hotkey: hotkey)
        }
        coordinator.onTranscribed = { [usage] text in usage.record(text) }
    }

    func start() {
        coordinator.start()
        startConfigurationObservation()
        if recordingServer == nil {
            let server = RecordingServer(
                startRecording: { [coordinator] in try await coordinator.startCLIRecording() },
                transcribeFile: { [coordinator] url in try await coordinator.transcribeCLIFile(url) },
                finishRecording: { [coordinator] id in try await coordinator.finishCLIRecording(id) }
            )
            do {
                try server.start()
                recordingServer = server
            } catch {
                configurationError = "Couldn’t start recording commands: \(error.localizedDescription)"
            }
        }
    }

    func setShowMenuBarIcon(_ enabled: Bool) {
        guard configuration.showMenuBarIcon != enabled else { return }
        do {
            configuration = try configurationStore.set(
                .showMenuBarIcon,
                value: enabled ? "true" : "false"
            )
            setConfigurationError(nil)
        } catch {
            setConfigurationError(error.localizedDescription)
        }
    }

    func reloadConfiguration() {
        do {
            let loaded = try configurationStore.load()
            let configuredHotkey = try Hotkey.from(configurationValue: loaded.hotkey)
            try coordinator.applyConfiguredHotkey(configuredHotkey)
            if configuration != loaded {
                configuration = loaded
            }
            setConfigurationError(nil)
        } catch {
            setConfigurationError(error.localizedDescription)
        }
    }

    private func persist(hotkey: Hotkey) throws {
        configuration = try configurationStore.set(
            .hotkey,
            value: hotkey.configurationValue
        )
        setConfigurationError(nil)
    }

    private func setConfigurationError(_ message: String?) {
        if configurationError != message {
            configurationError = message
        }
    }

    private func startConfigurationObservation() {
        do {
            try configurationStore.prepareDirectory()
            directoryWatcher = try ConfigurationDirectoryWatcher(
                directoryURL: configurationStore.fileURL.deletingLastPathComponent()
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleReload()
                }
            }
        } catch {
            configurationError = "Couldn’t monitor the configuration file: \(error.localizedDescription)"
        }

        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: AppConfigurationStore.changeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleReload()
            }
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.reloadConfiguration()
        }
    }

    private static func migrateLegacyPreferencesIfNeeded(
        to store: AppConfigurationStore
    ) throws {
        let defaults = UserDefaults.standard
        let hotkeyData = defaults.data(forKey: "hotkey")
        let hasMenuBarValue = defaults.object(forKey: "showMenuBarIcon") != nil

        if !FileManager.default.fileExists(atPath: store.fileURL.path) {
            var values: [AppConfigurationKey: String] = [:]
            if let hotkeyData,
                let hotkey = try? JSONDecoder().decode(Hotkey.self, from: hotkeyData)
            {
                values[.hotkey] = hotkey.configurationValue
            }
            if hasMenuBarValue {
                values[.showMenuBarIcon] =
                    defaults.bool(forKey: "showMenuBarIcon")
                    ? "true" : "false"
            }
            if !values.isEmpty {
                try store.set(values)
            }
        }

        _ = try store.load()
        defaults.removeObject(forKey: "hotkey")
        defaults.removeObject(forKey: "showMenuBarIcon")
    }
}

private final class ConfigurationDirectoryWatcher: @unchecked Sendable {
    private let descriptor: Int32
    private let source: DispatchSourceFileSystemObject

    init(directoryURL: URL, onChange: @escaping @Sendable () -> Void) throws {
        descriptor = Darwin.open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadNoPermission)
        }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue(label: "com.danielcorin.Reco.configuration-watcher")
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { [descriptor] in
            Darwin.close(descriptor)
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
