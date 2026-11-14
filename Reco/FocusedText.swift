import AppKit
import ApplicationServices
import RecoCore

/// Text around the cursor in the focused field, read over Accessibility.
/// Native AppKit fields expose it; many Electron apps and terminals don't, and
/// then every reader here returns nil and Reco behaves as it did without
/// context. Ranges are UTF-16 offsets, as Accessibility reports them.
struct FocusedText {
    let element: AXUIElement
    /// The selection (or cursor, with length 0) the transcript will replace.
    let selection: CFRange
    let context: InsertionContext
    let windowTitle: String?

    static let contextLength = 300
    /// A hung app would otherwise block for Accessibility's default 6 seconds.
    static let messagingTimeout: Float = 0.15

    /// Reads the focused element's context, or nil when it isn't a readable
    /// text field. Password fields are never read.
    static func capture(from element: AXUIElement, includeTitle: Bool = false) -> FocusedText? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        if stringAttribute(kAXSubroleAttribute, of: element) == (kAXSecureTextFieldSubrole as String) {
            return nil
        }
        guard let selection = selectedRange(of: element), let count = characterCount(of: element) else {
            return nil
        }

        let beforeStart = max(0, selection.location - contextLength)
        let afterStart = min(count, selection.location + selection.length)
        let afterEnd = min(count, afterStart + contextLength)
        guard
            var before = string(
                in: CFRange(location: beforeStart, length: selection.location - beforeStart), of: element),
            var after = string(in: CFRange(location: afterStart, length: afterEnd - afterStart), of: element)
        else { return nil }

        // A window that starts or ends mid-word would hand a fragment to term
        // extraction; drop it.
        if beforeStart > 0, let space = before.firstIndex(where: \.isWhitespace) {
            before = String(before[space...])
        }
        if afterEnd < count, let space = after.lastIndex(where: \.isWhitespace) {
            after = String(after[...space])
        }

        return FocusedText(
            element: element,
            selection: selection,
            context: InsertionContext(before: before, after: after),
            windowTitle: includeTitle ? windowTitle(of: element) : nil
        )
    }

    static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        return range
    }

    static func characterCount(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success,
            let count = value as? Int
        {
            return count
        }
        return fullValue(of: element).map { ($0 as NSString).length }
    }

    /// The text in `range`, preferring the ranged attribute so a long
    /// document is never copied whole.
    static func string(in range: CFRange, of element: AXUIElement) -> String? {
        guard range.length > 0 else { return "" }
        var cfRange = range
        if let rangeValue = AXValueCreate(.cfRange, &cfRange) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value
            ) == .success, let text = value as? String {
                return text
            }
        }
        guard let full = fullValue(of: element) as NSString?,
            range.location + range.length <= full.length
        else { return nil }
        return full.substring(with: NSRange(location: range.location, length: range.length))
    }

    private static func fullValue(of element: AXUIElement) -> String? {
        stringAttribute(kAXValueAttribute, of: element)
    }

    private static func windowTitle(of element: AXUIElement) -> String? {
        var window: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success,
            let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return stringAttribute(kAXTitleAttribute, of: window as! AXUIElement)
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

/// A transcript Reco just inserted, remembered in memory (never on disk) so a
/// later edit to it can teach the vocabulary.
struct PendingInsertion {
    let element: AXUIElement
    /// UTF-16 offset where the transcript began.
    let location: Int
    let insertedText: String
    let beforeAnchor: String
    let afterAnchor: String
    let appliedFixes: [AppliedFix]

    /// The current text of the span that held the transcript, or nil when the
    /// field changed too much (or can't be read) to find it.
    func editedText() -> String? {
        AXUIElementSetMessagingTimeout(element, FocusedText.messagingTimeout)
        guard let count = FocusedText.characterCount(of: element) else { return nil }
        let insertedLength = (insertedText as NSString).length
        let start = max(0, min(count, location - 200))
        let end = min(count, location + insertedLength * 3 + 400)
        guard end > start,
            let region = FocusedText.string(in: CFRange(location: start, length: end - start), of: element)
        else { return nil }
        return EditRecovery.editedSpan(
            in: region,
            beforeAnchor: beforeAnchor,
            afterAnchor: afterAnchor,
            regionStartsField: start == 0,
            regionEndsField: end == count,
            maxLength: insertedText.count * 2 + 80
        )
    }
}
