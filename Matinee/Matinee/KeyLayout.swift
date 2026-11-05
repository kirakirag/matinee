import AppKit
import Carbon.HIToolbox

/// Shortcuts by physical key: with a non-Latin layout (Greek, Arabic…) a key press is read as the letter that key
/// has on the user's Latin layout, so Q, J, X or ⌘, mean the same whichever layout is active. Text fields keep the
/// typed characters.
enum KeyLayout {
    /// The event with Latin characters when its own aren't ASCII; otherwise the event unchanged.
    static func latin(_ event: NSEvent) -> NSEvent {
        guard event.type == .keyDown, let typed = event.charactersIgnoringModifiers, !typed.isEmpty,
              !typed.unicodeScalars.allSatisfy(\.isASCII),
              let latin = translate(event.keyCode, shift: event.modifierFlags.contains(.shift)) else { return event }
        return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                characters: latin, charactersIgnoringModifiers: latin, isARepeat: event.isARepeat,
                                keyCode: event.keyCode) ?? event
    }

    /// The key's character on the current ASCII-capable layout (the user's Latin one), with or without Shift.
    static func translate(_ keyCode: UInt16, shift: Bool) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw in
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!, keyCode, UInt16(kUCKeyActionDown),
                           shift ? UInt32(shiftKey >> 8) & 0xFF : 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        return s.unicodeScalars.allSatisfy(\.isASCII) ? s : nil
    }
}
