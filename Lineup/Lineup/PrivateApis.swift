//
//  PrivateApis.swift
//  Lineup
//
//  Private SkyLight (WindowServer) and HIServices SPI used to enumerate and
//  focus windows across ALL Spaces / desktops — something the public
//  Accessibility and CoreGraphics window lists cannot do. Declarations are
//  ported verbatim from AltTab (github.com/lwouis/alt-tab-macos), the canonical
//  open-source implementation. Internal tool — App Store review is not a concern.
//

import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - Connection

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64
typealias AXUIElementID = UInt64

/// Single global connection to the WindowServer, captured once.
let CGS_CONNECTION: CGSConnectionID = CGSMainConnectionID()

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

// MARK: - Spaces

/// Array of display dicts; each has a "Spaces" array (each space dict has "id64")
/// and a "Current Space" dict. Correct only when "Displays have separate Spaces"
/// is on, which is the macOS default.
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

// MARK: - Window enumeration (per space, z-ordered)

struct CGSCopyWindowsOptions: OptionSet {
    let rawValue: Int
    static let invisible1 = CGSCopyWindowsOptions(rawValue: 1 << 0)
    static let screenSaverLevel1000 = CGSCopyWindowsOptions(rawValue: 1 << 1)
    static let invisible2 = CGSCopyWindowsOptions(rawValue: 1 << 2)
}

struct CGSCopyWindowsTags: OptionSet {
    let rawValue: Int
}

@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
func CGSCopyWindowsWithOptionsAndTags(_ cid: CGSConnectionID, _ owner: Int, _ spaces: CFArray,
                                      _ options: Int, _ setTags: UnsafeMutablePointer<Int>,
                                      _ clearTags: UnsafeMutablePointer<Int>) -> CFArray

// MARK: - Window -> Spaces

enum CGSSpaceMask: Int {
    case current = 5
    case other = 6
    case all = 7
}

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: CGSSpaceMask.RawValue,
                             _ wids: CFArray) -> CFArray

// MARK: - Focus / activation

enum SLPSMode: UInt32 {
    case allWindows = 0x100
    case userGenerated = 0x200
    case noWindows = 0x400
}

// The SLPS* functions live in the private SkyLight framework, whose binary is
// only in the dyld shared cache on macOS 11+ (no on-disk stub to link against).
// SkyLight is already loaded into every GUI process via AppKit, so we resolve
// these two symbols at runtime with dlsym rather than at link time.

private typealias SLPSSetFrontProcessWithOptionsFn =
    @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
private typealias SLPSPostEventRecordToFn =
    @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

private let RTLD_DEFAULT_HANDLE = UnsafeMutableRawPointer(bitPattern: -2)

private let _slpsSetFrontProcessWithOptions: SLPSSetFrontProcessWithOptionsFn? = {
    guard let sym = dlsym(RTLD_DEFAULT_HANDLE, "_SLPSSetFrontProcessWithOptions") else { return nil }
    return unsafeBitCast(sym, to: SLPSSetFrontProcessWithOptionsFn.self)
}()

private let _slpsPostEventRecordTo: SLPSPostEventRecordToFn? = {
    guard let sym = dlsym(RTLD_DEFAULT_HANDLE, "SLPSPostEventRecordTo") else { return nil }
    return unsafeBitCast(sym, to: SLPSPostEventRecordToFn.self)
}()

/// Focuses the front process, scoped to a window id. Switching to a window on
/// another Space is a side-effect of this call (there is no public Set-current-
/// space API). * macOS 10.12+
@discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>,
                                     _ wid: CGWindowID, _ mode: SLPSMode.RawValue) -> CGError {
    return _slpsSetFrontProcessWithOptions?(psn, wid, mode) ?? .failure
}

/// Sends a synthesized event record to the WindowServer (used by makeKeyWindow).
@discardableResult
func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>,
                           _ bytes: UnsafeMutablePointer<UInt8>) -> CGError {
    return _slpsPostEventRecordTo?(psn, bytes) ?? .failure
}

/// pid -> ProcessSerialNumber (deprecated/removed public API, still available).
@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

// MARK: - AX <-> CGWindowID bridge

/// CGWindowID of an AXUIElement (missing from the public AXUIElement API).
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// AXUIElement from a 20-byte remote token: pid(4) + 0(4) + 0x636f636f(4) +
/// AXUIElementID(8). Lets us obtain elements for windows on OTHER Spaces, which
/// kAXWindowsAttribute omits.
@_silgen_name("_AXUIElementCreateWithRemoteToken") @discardableResult
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?
