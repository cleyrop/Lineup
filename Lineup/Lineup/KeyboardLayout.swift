//
//  KeyboardLayout.swift
//  Lineup
//
//  Maps a virtual key code to the character it actually produces on the user's
//  CURRENT keyboard layout. The TriggerKey cases are ANSI physical positions
//  (kVK_ANSI_Semicolon, …), so their static labels are wrong on AZERTY / QWERTZ
//  / other ISO layouts: the key at the ANSI ";" position types "M" on a French
//  AZERTY keyboard. UCKeyTranslate resolves what the user will really press.
//

import Foundation
import Carbon.HIToolbox

enum KeyboardLayout {
    /// The character produced by `keyCode` with no modifiers on the active
    /// layout, uppercased for display. Returns nil for dead keys or when the
    /// layout data is unavailable, so callers can fall back to a static label.
    static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0

        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                base,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0, // no modifier keys
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }

        guard status == noErr, length > 0 else { return nil }
        let produced = String(utf16CodeUnits: chars, count: length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return produced.isEmpty ? nil : produced.uppercased()
    }
}
