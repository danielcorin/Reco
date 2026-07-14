import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog

struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
    var keyName: String

    static let defaultHotkey = Hotkey(
        keyCode: 14,
        modifiers: CGEventFlags.maskControl.rawValue,
        keyName: "E"
    )

    var displayName: String {
        var result = ""
        let flags = CGEventFlags(rawValue: modifiers)
        if flags.contains(.maskControl) { result += "⌃" }
        if flags.contains(.maskAlternate) { result += "⌥" }
        if flags.contains(.maskShift) { result += "⇧" }
        if flags.contains(.maskCommand) { result += "⌘" }
        return result + keyName
    }

    static func from(_ event: NSEvent) -> Hotkey {
        var flags: CGEventFlags = []
        if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        if event.modifierFlags.contains(.shift) { flags.insert(.maskShift) }
        if event.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
        if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }

        return Hotkey(
            keyCode: event.keyCode,
            modifiers: flags.rawValue,
            keyName: keyName(for: event.keyCode)
        )
    }

    static func keyName(for code: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "Space", 50: "`", 36: "Return",
            48: "Tab", 51: "Delete", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        if let name = names[code] { return name }
        if (122...135).contains(code) {
            let functionKeys: [UInt16: String] = [
                122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            ]
            return functionKeys[code] ?? "Key (code)"
        }
        return "Key (code)"
    }
}

@MainActor
final class HotkeyMonitor {
    var hotkey: Hotkey = .defaultHotkey
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onCaptured: ((Hotkey?) -> Void)?

    private static let signature: OSType = 0x5245_434F  // "RECO"
    private static let identifier: UInt32 = 1

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Reco",
        category: "Hotkey"
    )
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var captureMonitor: Any?
    private var resumeHotkeyAfterCapture = false
    private var isKeyDown = false

    var isRunning: Bool {
        hotKeyRef != nil && eventHandlerRef != nil
    }

    @discardableResult
    func start() -> Bool {
        if eventHandlerRef == nil {
            var eventTypes = [
                EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyPressed)
                ),
                EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyReleased)
                ),
            ]
            let callback: EventHandlerUPP = { _, event, userInfo in
                guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handle(event: event)
            }

            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                callback,
                eventTypes.count,
                &eventTypes,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandlerRef
            )
            guard status == noErr else {
                logger.error("Could not install hotkey event handler: \(status)")
                return false
            }
        }

        return registerHotkey()
    }

    func stop() {
        endCapture(resumeHotkey: false)
        unregisterHotkey()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        eventHandlerRef = nil
        isKeyDown = false
    }

    @discardableResult
    func updateHotkey(_ newHotkey: Hotkey) -> Bool {
        let previousHotkey = hotkey
        let shouldRegister = eventHandlerRef != nil

        unregisterHotkey()
        hotkey = newHotkey
        guard !shouldRegister || registerHotkey() else {
            hotkey = previousHotkey
            _ = registerHotkey()
            return false
        }
        return true
    }

    @discardableResult
    func captureNextShortcut() -> Bool {
        endCapture(resumeHotkey: true)
        resumeHotkeyAfterCapture = eventHandlerRef != nil
        if resumeHotkeyAfterCapture {
            unregisterHotkey()
        }

        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.capture(event)
            return nil
        }
        return captureMonitor != nil
    }

    func cancelCapture() {
        endCapture(resumeHotkey: true)
    }

    private func registerHotkey() -> Bool {
        unregisterHotkey()
        guard eventHandlerRef != nil else { return false }

        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.identifier
        )
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            logger.error("Could not register \(self.hotkey.displayName, privacy: .public): \(status)")
            return false
        }
        hotKeyRef = reference
        logger.info("Registered \(self.hotkey.displayName, privacy: .public)")
        return true
    }

    private func unregisterHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        isKeyDown = false
    }

    private var carbonModifiers: UInt32 {
        let flags = CGEventFlags(rawValue: hotkey.modifiers)
        var modifiers: UInt32 = 0
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    private func handle(event: EventRef) -> OSStatus {
        var eventID = EventHotKeyID(signature: 0, id: 0)
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &eventID
        )
        guard parameterStatus == noErr,
            eventID.signature == Self.signature,
            eventID.id == Self.identifier
        else {
            return OSStatus(eventNotHandledErr)
        }

        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            guard !isKeyDown else { return noErr }
            isKeyDown = true
            logger.debug("Hotkey pressed")
            onKeyDown?()
        case UInt32(kEventHotKeyReleased):
            guard isKeyDown else { return noErr }
            isKeyDown = false
            logger.debug("Hotkey released")
            onKeyUp?()
        default:
            return OSStatus(eventNotHandledErr)
        }
        return noErr
    }

    private func capture(_ event: NSEvent) {
        let candidate = Hotkey.from(event)
        let shouldResumeHotkey = resumeHotkeyAfterCapture
        endCapture(resumeHotkey: false)

        if candidate.keyCode == 53 || candidate.modifiers == 0 {
            onCaptured?(nil)
        } else {
            logger.info("Captured \(candidate.displayName, privacy: .public)")
            onCaptured?(candidate)
        }

        if shouldResumeHotkey, hotKeyRef == nil {
            _ = registerHotkey()
        }
    }

    private func endCapture(resumeHotkey: Bool) {
        if let captureMonitor {
            NSEvent.removeMonitor(captureMonitor)
        }
        captureMonitor = nil

        if resumeHotkey, resumeHotkeyAfterCapture, hotKeyRef == nil {
            _ = registerHotkey()
        }
        resumeHotkeyAfterCapture = false
    }
}
