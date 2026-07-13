import AppKit
import ApplicationServices

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

    func matches(_ event: CGEvent) -> Bool {
        UInt16(event.getIntegerValueField(.keyboardEventKeycode)) == keyCode
            && Self.normalized(event.flags).rawValue == modifiers
    }

    static func from(_ event: CGEvent) -> Hotkey {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        return Hotkey(
            keyCode: code,
            modifiers: normalized(event.flags).rawValue,
            keyName: keyName(for: code)
        )
    }

    static func normalized(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
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
            48: "Tab", 51: "Delete", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        if let name = names[code] { return name }
        if (122...135).contains(code) {
            let functionKeys: [UInt16: String] = [
                122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
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

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyDown = false
    private var capturing = false

    @discardableResult
    func start() -> Bool {
        stop()

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        isKeyDown = false
    }

    func captureNextShortcut() {
        capturing = true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if capturing, type == .keyDown {
            capturing = false
            let candidate = Hotkey.from(event)
            if candidate.keyCode == 53 {
                onCaptured?(nil)
            } else if candidate.modifiers == 0 {
                onCaptured?(nil)
            } else {
                onCaptured?(candidate)
            }
            return nil
        }

        guard hotkey.matches(event) else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            guard !isKeyDown else { return nil }
            isKeyDown = true
            onKeyDown?()
            return nil
        case .keyUp:
            guard isKeyDown else { return nil }
            isKeyDown = false
            onKeyUp?()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
