//
//  SwitcherComponents.swift
//  Lineup
//
//  Created for componentizing switcher views
//

import SwiftUI
import Foundation
import AppKit
import CoreGraphics

// MARK: - AnyShape Helper
struct AnyShape: Shape {
    private let _path: @Sendable (CGRect) -> Path
    
    init<S: Shape>(_ shape: S) {
        _path = { rect in
            shape.path(in: rect)
        }
    }
    
    func path(in rect: CGRect) -> Path {
        return _path(rect)
    }
}

// MARK: - Custom Uneven Rounded Rectangle for macOS 12.0 compatibility
struct CustomUnevenRoundedRectangle: Shape {
    let topLeadingRadius: CGFloat
    let bottomLeadingRadius: CGFloat
    let bottomTrailingRadius: CGFloat
    let topTrailingRadius: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let _ = rect.width
        let _ = rect.height
        
        // Start from top-left + radius
        path.move(to: CGPoint(x: rect.minX + topLeadingRadius, y: rect.minY))
        
        // Top edge
        path.addLine(to: CGPoint(x: rect.maxX - topTrailingRadius, y: rect.minY))
        
        // Top-right corner
        if topTrailingRadius > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - topTrailingRadius, y: rect.minY + topTrailingRadius),
                       radius: topTrailingRadius,
                       startAngle: Angle(degrees: -90),
                       endAngle: Angle(degrees: 0),
                       clockwise: false)
        }
        
        // Right edge
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomTrailingRadius))
        
        // Bottom-right corner
        if bottomTrailingRadius > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - bottomTrailingRadius, y: rect.maxY - bottomTrailingRadius),
                       radius: bottomTrailingRadius,
                       startAngle: Angle(degrees: 0),
                       endAngle: Angle(degrees: 90),
                       clockwise: false)
        }
        
        // Bottom edge
        path.addLine(to: CGPoint(x: rect.minX + bottomLeadingRadius, y: rect.maxY))
        
        // Bottom-left corner
        if bottomLeadingRadius > 0 {
            path.addArc(center: CGPoint(x: rect.minX + bottomLeadingRadius, y: rect.maxY - bottomLeadingRadius),
                       radius: bottomLeadingRadius,
                       startAngle: Angle(degrees: 90),
                       endAngle: Angle(degrees: 180),
                       clockwise: false)
        }
        
        // Left edge
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeadingRadius))
        
        // Top-left corner
        if topLeadingRadius > 0 {
            path.addArc(center: CGPoint(x: rect.minX + topLeadingRadius, y: rect.minY + topLeadingRadius),
                       radius: topLeadingRadius,
                       startAngle: Angle(degrees: 180),
                       endAngle: Angle(degrees: 270),
                       clockwise: false)
        }
        
        path.closeSubpath()
        return path
    }
}

// MARK: - Switcher Type Enum
enum SwitcherType {
    case ds2  // Lineup (same app window switching)
    case ct2  // Command+Tab enhanced (all app switching)
}

// MARK: - Switcher Configuration Protocol
protocol SwitcherConfig {
    var type: SwitcherType { get }
    var title: String { get }
}


// MARK: - DS2 Configuration
struct DS2Config: SwitcherConfig {
    let type: SwitcherType = .ds2
    let title: String = LocalizedStrings.windowSwitcherTitle
}

// MARK: - CT2 Configuration
struct CT2Config: SwitcherConfig {
    let type: SwitcherType = .ct2
    let title: String = LocalizedStrings.appSwitcherTitle
}

// MARK: - Generic Switcher View
struct BaseSwitcherView<ItemType>: View {
    let config: SwitcherConfig
    let items: [ItemType]
    let currentIndex: Int
    let onItemSelect: (Int) -> Void
    let itemContentBuilder: (ItemType, Bool, Bool, Int) -> AnyView
    
    @State private var hoveredIndex: Int? = nil
    @StateObject private var settingsManager = SettingsManager.shared
    
    var body: some View {
        listLayoutView
            .environmentObject(settingsManager)
    }

    // MARK: - List Layout View
    private var listLayoutView: some View {
        VStack(spacing: 0) {
            headerView
            itemListView
        }
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 20, x: 0, y: 10)
        .frame(maxWidth: 600, maxHeight: 400)
    }

    // MARK: - Header View
    private var headerView: some View {
        Group {
            switch settingsManager.settings.switcherHeaderStyle {
            case .default:
                defaultHeaderView
                Divider()
            case .simplified:
                EmptyView()
            }
        }
    }
    
    private var defaultHeaderView: some View {
        HStack {
            Image(systemName: headerIcon)
//                .symbolEffect(.breathe.plain.byLayer, options: .repeat(.continuous))
                .foregroundColor(settingsManager.settings.colorScheme.primaryColor)
                .font(.title2)
            
            Text(config.title)
                .font(.headline)
                .foregroundColor(.primary)
            
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.regularMaterial)
    }
    
    private var simplifiedHeaderView: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(height: 8)
    }
    
    // MARK: - Item List View
    private var itemListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        Button(action: {
                            onItemSelect(index)
                        }) {
                            itemContentBuilder(
                                item,
                                index == currentIndex,
                                index == hoveredIndex,
                                index
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .background(backgroundColorForIndex(index))
                        .clipShape(itemClipShape(for: index))
                        .id(index) // Add ID for scroll positioning
                        .onHover { isHovering in
                            hoveredIndex = isHovering ? index : nil
                        }
                    }
                }
            }
            .background(.ultraThinMaterial)
            .clipShape(scrollViewClipShape())
            .onChange(of: currentIndex) { newIndex in
                // Auto scroll to item when selection changes
                // Use shorter animation time to support fast switching
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onAppear {
                // Scroll to current selected item on initial display
                if currentIndex < items.count {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(currentIndex, anchor: .center)
                        }
                    }
                }
            }
        }
    }
    
    
    // MARK: - Helper Methods
    private var headerIcon: String {
        switch config.type {
        case .ds2:
            return "rectangle.2.swap"
        case .ct2:
            return "rectangle.3.group"
        }
    }
    
    private func logDisplayInfo() {
        let currentScreen = getCurrentFocusedScreen()
        let primaryScreen = getPrimaryScreen()
        
        let currentDisplayName = getDisplayName(for: currentScreen)
        let primaryDisplayName = getDisplayName(for: primaryScreen)
        
        Logger.log("🖥️ Switcher rendered - Current display: \(currentDisplayName), Primary display: \(primaryDisplayName)")
    }
    
    private func getCurrentFocusedScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                return screen
            }
        }
        return NSScreen.main
    }
    
    private func getPrimaryScreen() -> NSScreen? {
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let displayID = CGDirectDisplayID(screenNumber.uint32Value)
                if CGDisplayIsMain(displayID) != 0 {
                    return screen
                }
            }
        }
        return NSScreen.main
    }
    
    private func getDisplayName(for screen: NSScreen?) -> String {
        guard let screen = screen else { return "Unknown" }
        
        if #available(macOS 10.15, *) {
            return screen.localizedName
        } else {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let displayID = CGDirectDisplayID(screenNumber.uint32Value)
                
                if CGDisplayIsBuiltin(displayID) != 0 {
                    return "Built-in Display"
                } else {
                    return "External Display (\(displayID))"
                }
            }
            return "Unknown Display"
        }
    }
    
    private func backgroundColorForIndex(_ index: Int) -> Color {
        let colorScheme = settingsManager.settings.colorScheme
        if index == currentIndex {
            return colorScheme.primaryColor.opacity(0.15)
        } else if index == hoveredIndex {
            return colorScheme.primaryColor.opacity(0.05)
        } else {
            return Color.clear
        }
    }
    
    // MARK: - Clip Shape Helpers
    private func itemClipShape(for index: Int) -> some Shape {
        let isSimplified = settingsManager.settings.switcherHeaderStyle == .simplified
        let isFirstItem = index == 0
        let isLastItem = index == items.count - 1
        
        if isSimplified {
            if isFirstItem && isLastItem {
                return AnyShape(RoundedRectangle(cornerRadius: 12))
            } else if isFirstItem {
                return AnyShape(CustomUnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 12
                ))
            } else if isLastItem {
                return AnyShape(CustomUnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 12,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 0
                ))
            } else {
                return AnyShape(Rectangle())
            }
        } else {
            return AnyShape(Rectangle())
        }
    }
    
    private func scrollViewClipShape() -> some Shape {
        let isSimplified = settingsManager.settings.switcherHeaderStyle == .simplified
        
        if isSimplified {
            return AnyShape(RoundedRectangle(cornerRadius: 12))
        } else {
            return AnyShape(Rectangle())
        }
    }
}

// MARK: - Window State Badge
/// Small pill on a list item flagging where a window lives — the Dock (minimized)
/// or another desktop / Space.
struct WindowStateBadge: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.system(.caption2, design: .rounded).weight(.medium))
        .foregroundColor(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
        )
    }
}

// MARK: - Window Visual (thumbnail or icon)
/// Shows a window screenshot when one has been captured (with the app icon as a
/// small corner badge so the app is still obvious), otherwise the app icon alone.
struct WindowVisualView: View {
    let window: WindowInfo

    var body: some View {
        if let thumbnail = window.thumbnail {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 72, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                AppIconView(processID: window.processID)
                    .frame(width: 22, height: 22)
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
                    .padding(3)
            }
            .frame(width: 72, height: 48)
        } else {
            AppIconView(processID: window.processID)
                .frame(width: 48, height: 48)
        }
    }
}

// MARK: - Window Item Content View
struct WindowItemContentView: View {
    let window: WindowInfo
    let isSelected: Bool
    let isHovered: Bool
    let itemIndex: Int
    @EnvironmentObject private var settingsManager: SettingsManager
    
    private var showNumberKeys: Bool {
        settingsManager.settings.showNumberKeys
    }
    
    var body: some View {
        HStack(spacing: 16) {
            // A window screenshot when available (with the app icon as a small
            // overlay so each row is distinct), otherwise just the app icon.
            WindowVisualView(window: window)

            VStack(alignment: .leading, spacing: 4) {
                // Project name (main display)
                Text(window.projectName)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // App name, with a badge for windows in the Dock or on another desktop
                HStack(spacing: 6) {
                    Text(window.appName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if window.isMinimized {
                        WindowStateBadge(systemImage: "dock.rectangle",
                                         text: LocalizedStrings.minimizedInDock)
                    } else if window.isOnOtherSpace {
                        WindowStateBadge(systemImage: "macwindow.on.rectangle",
                                         text: window.spaceIndex > 0
                                            ? LocalizedStrings.desktopNumber(window.spaceIndex)
                                            : LocalizedStrings.onOtherDesktop)
                    }
                }

                // Full window title — always shown for windows that aren't on the
                // current screen so an off-Space / Dock window is identifiable.
                if window.title != window.projectName || window.isMinimized || window.isOnOtherSpace {
                    Text(window.title)
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Fixed width container for right indicators
            HStack(spacing: 8) {
                // Number key indicator (conditionally display based on settings)
                Group {
                    if showNumberKeys && itemIndex < 9 {
                        Text("\(itemIndex + 1)")
                            .font(.system(.caption, design: .rounded))
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.regularMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(.quaternary, lineWidth: 0.5)
                                    )
                                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                            )
                    } else if showNumberKeys {
                        Color.clear
                            .frame(width: 22, height: 18)
                    }
                }
                
                // Selection indicator (always reserve space)
                Group {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                            .font(.title3)
                    } else {
                        Image(systemName: "circle")
                            .foregroundColor(.clear)
                            .font(.title3)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .frame(width: showNumberKeys ? 52 : 24) // Dynamic width based on settings
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - App Item Content View
struct AppItemContentView: View {
    let app: AppInfo
    let isSelected: Bool
    let isHovered: Bool
    let itemIndex: Int
    @EnvironmentObject private var settingsManager: SettingsManager
    
    private var showNumberKeys: Bool {
        settingsManager.settings.showNumberKeys
    }
    
    var body: some View {
        HStack(spacing: 16) {
            // App icon
            AppIconView(processID: app.processID)
                .frame(width: 48, height: 48)
            
            VStack(alignment: .leading, spacing: 4) {
                // App name (main display)
                Text(app.appName)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                // Window count info
                if app.windowCount > 1 {
                    Text(LocalizedStrings.multipleWindows(app.windowCount))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(LocalizedStrings.singleWindow)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Fixed width container for right indicators
            HStack(spacing: 8) {
                // Number key indicator (conditionally display based on settings)
                Group {
                    if showNumberKeys && itemIndex < 9 {
                        Text("\(itemIndex + 1)")
                            .font(.system(.caption, design: .rounded))
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.regularMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(.quaternary, lineWidth: 0.5)
                                    )
                                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                            )
                    } else if showNumberKeys {
                        Color.clear
                            .frame(width: 22, height: 18)
                    }
                }
                
                // Selection indicator (always reserve space)
                Group {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(settingsManager.settings.colorScheme.primaryColor)
                            .font(.title3)
                    } else {
                        Image(systemName: "circle")
                            .foregroundColor(.clear)
                            .font(.title3)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .frame(width: showNumberKeys ? 52 : 24) // Dynamic width based on settings
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - DS2 Switcher View (Using Generic Components)
struct DS2SwitcherView: View {
    @ObservedObject var windowManager: WindowManager
    
    var body: some View {
        BaseSwitcherView(
            config: DS2Config(),
            items: windowManager.windows,
            currentIndex: windowManager.currentWindowIndex,
            onItemSelect: { index in
                windowManager.selectWindow(at: index)
            },
            itemContentBuilder: { window, isSelected, isHovered, itemIndex in
                AnyView(
                    WindowItemContentView(
                        window: window,
                        isSelected: isSelected,
                        isHovered: isHovered,
                        itemIndex: itemIndex
                    )
                )
            }
        )
    }
}

// MARK: - CT2 Switcher View (Using Generic Components)
struct CT2SwitcherView: View {
    @ObservedObject var windowManager: WindowManager
    
    var body: some View {
        BaseSwitcherView(
            config: CT2Config(),
            items: windowManager.apps,
            currentIndex: windowManager.currentAppIndex,
            onItemSelect: { index in
                windowManager.selectApp(at: index)
            },
            itemContentBuilder: { app, isSelected, isHovered, itemIndex in
                AnyView(
                    AppItemContentView(
                        app: app,
                        isSelected: isSelected,
                        isHovered: isHovered,
                        itemIndex: itemIndex
                    )
                )
            }
        )
    }
}
