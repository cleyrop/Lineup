//
//  CompatibilityExtensions.swift
//  Lineup
//
//  Created for macOS version compatibility
//

import Foundation
import AppKit

// MARK: - NSApplication Compatibility Extension
extension NSApplication {
    func activateCompat() {
        if #available(macOS 14.0, *) {
            self.activate()
        } else {
            self.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - macOS Version Utilities
struct MacOSVersion {
    static let current = ProcessInfo.processInfo.operatingSystemVersion
    
    static var isMontereyOrLater: Bool {
        return current.majorVersion >= 12
    }
    
    static var isVenturaOrLater: Bool {
        return current.majorVersion >= 13
    }
    
    static var isSonomaOrLater: Bool {
        return current.majorVersion >= 14
    }
    
    static var displayString: String {
        return "\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)"
    }
} 