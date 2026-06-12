//
//  WindowSwitcherView.swift
//  Lineup
//

import SwiftUI

/// The app icon for a window/app row, backed by the shared icon cache.
struct AppIconView: View {
    let processID: pid_t
    @StateObject private var iconCache = AppIconCache.shared

    var body: some View {
        Group {
            if let icon = iconCache.getIcon(for: processID) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.2))
                    .overlay(
                        Image(systemName: "app.dashed")
                            .foregroundColor(.accentColor)
                            .font(.title2)
                    )
            }
        }
    }
}
