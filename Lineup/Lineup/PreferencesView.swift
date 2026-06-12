//
//  PreferencesView.swift
//  Lineup
//
//  Created by river on 2025-07-26.
//

import SwiftUI

// MARK: - Preferences Sections

enum PrefSection: String, CaseIterable, Identifiable {
    case general, shortcuts, switcher, appearance, windowTitles, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return LocalizedStrings.generalSettingsTabTitle
        case .shortcuts: return LocalizedStrings.hotkeySettings
        case .switcher: return LocalizedStrings.switcherDisplaySectionTitle
        case .appearance: return LocalizedStrings.colorSchemeLabel
        case .windowTitles: return LocalizedStrings.windowTitleSectionTitle
        case .about: return LocalizedStrings.aboutTabTitle
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .switcher: return "macwindow.on.rectangle"
        case .appearance: return "paintpalette"
        case .windowTitles: return "textformat"
        case .about: return "info.circle"
        }
    }
}

struct SidebarRow: View {
    let section: PrefSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundColor(isSelected ? .white : .accentColor)
                Text(section.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PreferencesView: View {
    @State private var selection: PrefSection = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailColumn
        }
        .frame(width: 800, height: 600)
        .onReceive(NotificationCenter.default.publisher(for: .languageChanged)) { _ in }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "rectangle.2.swap")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lineup").font(.headline)
                    Text(LocalizedStrings.preferencesSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            VStack(spacing: 2) {
                ForEach(PrefSection.allCases) { section in
                    SidebarRow(section: section, isSelected: selection == section) {
                        selection = section
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .frame(width: 198)
        .background(.regularMaterial)
    }

    private var detailColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(selection.title)
                    .font(.title2)
                    .fontWeight(.bold)
                detail
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general: GeneralPaneView()
        case .shortcuts: ShortcutsPaneView()
        case .switcher: SwitcherPaneView()
        case .appearance: AppearancePaneView()
        case .windowTitles: WindowTitleConfigView()
        case .about: AboutView()
        }
    }
}

// MARK: - General Settings Section
struct GeneralSettingsSection: View {
    @ObservedObject var settingsManager: SettingsManager
    
    var body: some View {
        SettingsSection(title: LocalizedStrings.generalSettingsSectionTitle) {
            SettingsRow(title: LocalizedStrings.launchAtStartup,
                        subtitle: LocalizedStrings.launchAtStartupDescription) {
                Toggle("", isOn: Binding(
                    get: { settingsManager.settings.launchAtStartup },
                    set: { settingsManager.updateLaunchAtStartup($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }
}

// MARK: - Language Settings Section
struct LanguageSettingsSection: View {
    @ObservedObject var languageManager: LanguageManager
    
    var body: some View {
        SettingsSection(title: LocalizedStrings.languageSectionTitle,
                        footer: LocalizedStrings.languageRestartNote) {
            SettingsRow(title: LocalizedStrings.languageSelectionLabel) {
                Picker("", selection: $languageManager.currentLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: languageManager.currentLanguage) { newLanguage in
                    languageManager.setLanguage(newLanguage)
                }
            }
            RowDivider()
            SettingsRow(title: LocalizedStrings.languageRestartNowButton) {
                Button(LocalizedStrings.languageRestartNowButton) {
                    restartApplication()
                }
                .controlSize(.small)
            }
        }
    }
    
    // MARK: - Private Methods
    private func restartApplication() {
        relaunchApp()
    }
}

// MARK: - DS2 Hotkey Settings Section
struct DS2HotkeySettingsSection: View {
    @Binding var selectedModifier: ModifierKey
    @Binding var selectedTrigger: TriggerKey
    let onApply: () -> Void
    let onReset: () -> Void
    
    var body: some View {
        SettingsSection(title: LocalizedStrings.ds2HotkeySectionTitle) {
            SettingsStackedRow(title: LocalizedStrings.ds2SameAppWindowSwitching,
                               subtitle: LocalizedStrings.ds2HotkeyDescription) {
                HotkeyEditor(modifier: $selectedModifier, trigger: $selectedTrigger,
                             onApply: onApply, onReset: onReset)
            }
        }
    }
}

// MARK: - Reusable Hotkey Editor
struct HotkeyEditor: View {
    @Binding var modifier: ModifierKey
    @Binding var trigger: TriggerKey
    let onApply: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $modifier) {
                    ForEach(ModifierKey.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)

                Text("+").foregroundStyle(.secondary)

                Picker("", selection: $trigger) {
                    ForEach(TriggerKey.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)

                Spacer(minLength: 8)

                Button(LocalizedStrings.hotkeyApply, action: onApply)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(LocalizedStrings.hotkeyReset, action: onReset)
                    .controlSize(.small)
            }

            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(LocalizedStrings.currentHotkeyDisplay(modifier.displayName, trigger.displayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - CT2 Hotkey Settings Section
struct CT2HotkeySettingsSection: View {
    @Binding var ct2Enabled: Bool
    @Binding var selectedModifier: ModifierKey
    @Binding var selectedTrigger: TriggerKey
    let onApply: () -> Void
    let onReset: () -> Void
    let settingsManager: SettingsManager
    
    var body: some View {
        SettingsSection(title: LocalizedStrings.ct2HotkeySectionTitle) {
            SettingsRow(title: LocalizedStrings.ct2AppSwitcher,
                        subtitle: LocalizedStrings.ct2HotkeyDescription) {
                Toggle("", isOn: $ct2Enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: ct2Enabled) { newValue in
                        settingsManager.updateCT2Enabled(newValue)
                        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
                    }
            }
            if ct2Enabled {
                RowDivider()
                SettingsStackedRow(title: LocalizedStrings.currentCT2Hotkey) {
                    HotkeyEditor(modifier: $selectedModifier, trigger: $selectedTrigger,
                                 onApply: onApply, onReset: onReset)
                }
            }
        }
    }
}

// MARK: - General Pane
struct GeneralPaneView: View {
    @StateObject private var settingsManager = SettingsManager.shared
    @StateObject private var languageManager = LanguageManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            GeneralSettingsSection(settingsManager: settingsManager)
            LanguageSettingsSection(languageManager: languageManager)
        }
    }
}

// MARK: - Shortcuts Pane
struct ShortcutsPaneView: View {
    @StateObject private var settingsManager = SettingsManager.shared
    @State private var selectedModifier: ModifierKey
    @State private var selectedTrigger: TriggerKey

    @State private var ct2Enabled: Bool
    @State private var selectedCT2Modifier: ModifierKey
    @State private var selectedCT2Trigger: TriggerKey

    init() {
        let settings = SettingsManager.shared.settings
        _selectedModifier = State(initialValue: settings.modifierKey)
        _selectedTrigger = State(initialValue: settings.triggerKey)
        _ct2Enabled = State(initialValue: settings.ct2Enabled)
        _selectedCT2Modifier = State(initialValue: settings.ct2ModifierKey)
        _selectedCT2Trigger = State(initialValue: settings.ct2TriggerKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            DS2HotkeySettingsSection(
                selectedModifier: $selectedModifier,
                selectedTrigger: $selectedTrigger,
                onApply: applyDS2HotkeySettings,
                onReset: resetDS2HotkeySettings
            )

            CT2HotkeySettingsSection(
                ct2Enabled: $ct2Enabled,
                selectedModifier: $selectedCT2Modifier,
                selectedTrigger: $selectedCT2Trigger,
                onApply: applyCT2HotkeySettings,
                onReset: resetCT2HotkeySettings,
                settingsManager: settingsManager
            )
        }
    }

    private func applyDS2HotkeySettings() {
        settingsManager.updateHotkey(modifier: selectedModifier, trigger: selectedTrigger)
        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
    }

    private func resetDS2HotkeySettings() {
        selectedModifier = .command
        selectedTrigger = .grave
        applyDS2HotkeySettings()
    }

    private func applyCT2HotkeySettings() {
        settingsManager.updateCT2Enabled(ct2Enabled)
        settingsManager.updateCT2Hotkey(modifier: selectedCT2Modifier, trigger: selectedCT2Trigger)
        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
    }

    private func resetCT2HotkeySettings() {
        ct2Enabled = true
        selectedCT2Modifier = .command
        selectedCT2Trigger = .tab
        applyCT2HotkeySettings()
    }
}


// MARK: - Window Title Header View
struct WindowTitleHeaderView: View {
    var body: some View {
        HStack {
            Text(LocalizedStrings.windowTitleSectionTitle)
                .font(.title3)
                .fontWeight(.semibold)
            
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }
}

// MARK: - Window Title Settings Content View
struct WindowTitleSettingsContentView: View {
    @Binding var selectedDefaultStrategy: TitleExtractionStrategy
    @Binding var defaultCustomSeparator: String
    @ObservedObject var configManager: ConfigurationExportImportManager
    @ObservedObject var settingsManager: SettingsManager
    @Binding var showingAddAppDialog: Bool
    let onImport: () -> Void
    let onExport: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DefaultStrategySection(
                selectedDefaultStrategy: $selectedDefaultStrategy,
                defaultCustomSeparator: $defaultCustomSeparator,
                settingsManager: settingsManager
            )
            
            AppConfigsSection(
                configManager: configManager,
                settingsManager: settingsManager,
                showingAddAppDialog: $showingAddAppDialog,
                onImport: onImport,
                onExport: onExport
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
}

// MARK: - Default Strategy Section
struct DefaultStrategySection: View {
    @Binding var selectedDefaultStrategy: TitleExtractionStrategy
    @Binding var defaultCustomSeparator: String
    @ObservedObject var settingsManager: SettingsManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(LocalizedStrings.defaultStrategyDescription)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Button(LocalizedStrings.defaultStrategyApply) {
                    settingsManager.updateDefaultTitleStrategy(selectedDefaultStrategy, customSeparator: defaultCustomSeparator)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStrings.extractionStrategyLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    Picker(LocalizedStrings.defaultExtractionStrategy, selection: $selectedDefaultStrategy) {
                        ForEach(TitleExtractionStrategy.allCases, id: \.self) { strategy in
                            Text(strategy.displayName).tag(strategy)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(maxWidth: .infinity)
                }
                
                if selectedDefaultStrategy != .fullTitle {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStrings.customSeparatorLabel)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        
                        TextField(LocalizedStrings.separatorExample, text: $defaultCustomSeparator)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - App Configs Section
struct AppConfigsSection: View {
    @ObservedObject var configManager: ConfigurationExportImportManager
    @ObservedObject var settingsManager: SettingsManager
    @Binding var showingAddAppDialog: Bool
    let onImport: () -> Void
    let onExport: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(LocalizedStrings.appConfigsDescription)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button(LocalizedStrings.appConfigImport) {
                        onImport()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(configManager.isProcessing)
                    
                    Button(LocalizedStrings.appConfigExport) {
                        onExport()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(settingsManager.settings.appTitleConfigs.isEmpty || configManager.isProcessing)
                    
                    Button(LocalizedStrings.appConfigAdd) {
                        showingAddAppDialog = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            
            if settingsManager.settings.appTitleConfigs.isEmpty {
                VStack {
                    Image(systemName: "tray")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text(LocalizedStrings.noAppConfigsMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(30)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(settingsManager.settings.appTitleConfigs.values), id: \.bundleId) { config in
                        AppConfigRowView(config: config) {
                            settingsManager.removeAppTitleConfig(for: config.bundleId)
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Window Title Configuration View
struct WindowTitleConfigView: View {
    @StateObject private var settingsManager = SettingsManager.shared
    @StateObject private var configManager = ConfigurationExportImportManager()
    @State private var selectedDefaultStrategy: TitleExtractionStrategy
    @State private var defaultCustomSeparator: String
    @State private var showingAddAppDialog = false
    @State private var newAppBundleId = ""
    @State private var newAppName = ""
    @State private var newAppStrategy: TitleExtractionStrategy = .beforeFirstSeparator
    @State private var newAppCustomSeparator = " - "
    
    @State private var showingImportResult = false
    @State private var importResultMessage = ""
    @State private var importResultTitle = ""
    @State private var importResultIsSuccess = false
    
    init() {
        let settings = SettingsManager.shared.settings
        _selectedDefaultStrategy = State(initialValue: settings.defaultTitleStrategy)
        _defaultCustomSeparator = State(initialValue: settings.defaultCustomSeparator)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WindowTitleHeaderView()
            WindowTitleSettingsContentView(
                selectedDefaultStrategy: $selectedDefaultStrategy,
                defaultCustomSeparator: $defaultCustomSeparator,
                configManager: configManager,
                settingsManager: settingsManager,
                showingAddAppDialog: $showingAddAppDialog,
                onImport: importConfiguration,
                onExport: exportConfiguration
            )
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.purple.opacity(0.1), lineWidth: 1)
        )
        .sheet(isPresented: $showingAddAppDialog) {
            AddAppConfigView(
                bundleId: $newAppBundleId,
                appName: $newAppName,
                strategy: $newAppStrategy,
                customSeparator: $newAppCustomSeparator
            ) {
                let config = AppTitleConfig(
                    bundleId: newAppBundleId,
                    appName: newAppName,
                    strategy: newAppStrategy,
                    customSeparator: newAppStrategy == .fullTitle ? nil : (newAppCustomSeparator.isEmpty ? getDefaultSeparator(for: newAppStrategy) : newAppCustomSeparator)
                )
                settingsManager.setAppTitleConfig(config)
                showingAddAppDialog = false
                // Reset form
                newAppBundleId = ""
                newAppName = ""
                newAppStrategy = .beforeFirstSeparator
                newAppCustomSeparator = " - "
            }
        }
        .alert(importResultTitle, isPresented: $showingImportResult) {
            Button(LocalizedStrings.confirm, role: .cancel) { }
        } message: {
            Text(importResultMessage)
        }
    }
    
    
    private func exportConfiguration() {
        Task { @MainActor in
            switch configManager.saveConfigurationToFile() {
            case .success(let url):
                showImportResult(
                    title: LocalizedStrings.exportSuccess,
                    message: LocalizedStrings.exportSuccessMessage(url.lastPathComponent),
                    isSuccess: true
                )
            case .failure(let error):
                if case ConfigurationError.userCancelled = error {
                    return
                }
                showImportResult(
                    title: LocalizedStrings.exportFailed,
                    message: error.localizedDescription,
                    isSuccess: false
                )
            }
        }
    }
    
    private func importConfiguration() {
        Task { @MainActor in
            switch configManager.importConfigurationFromFile() {
            case .success(let result):
                if result.isEmpty {
                    showImportResult(
                        title: LocalizedStrings.importNoData,
                        message: LocalizedStrings.importNoDataMessage,
                        isSuccess: false
                    )
                } else if result.isSuccess {
                    showImportResult(
                        title: LocalizedStrings.importSuccess,
                        message: LocalizedStrings.importSuccessMessage(result.newConfigs, result.updatedConfigs),
                        isSuccess: true
                    )
                } else {
                    let errorMsg = result.errors.joined(separator: "\n")
                    showImportResult(
                        title: LocalizedStrings.importPartialSuccess,
                        message: LocalizedStrings.importPartialSuccessMessage(result.totalImported) + "\n\n" + errorMsg,
                        isSuccess: false
                    )
                }
            case .failure(let error):
                if case ConfigurationError.userCancelled = error {
                    return
                }
                showImportResult(
                    title: LocalizedStrings.importFailed,
                    message: error.localizedDescription,
                    isSuccess: false
                )
            }
        }
    }
    
    private func showImportResult(title: String, message: String, isSuccess: Bool) {
        importResultTitle = title
        importResultMessage = message
        importResultIsSuccess = isSuccess
        showingImportResult = true
    }
    
    private func getDefaultSeparator(for strategy: TitleExtractionStrategy) -> String {
        switch strategy {
        case .firstPart, .lastPart:
            return " - "
        case .beforeFirstSeparator:
            return " — "
        case .afterLastSeparator:
            return " - "
        case .fullTitle:
            return ""
        }
    }
}

// MARK: - Preview Section View
struct PreviewSectionView: View {
    let windowTitles: [String]
    @Binding var selectedWindowTitle: String
    let strategy: TitleExtractionStrategy
    let customSeparator: String
    let isLoading: Bool
    let errorMessage: String
    let settingsManager: SettingsManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStrings.previewWindowTitles)
                .font(.subheadline)
                .fontWeight(.medium)
            
            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(LocalizedStrings.loading)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .italic()
            } else if windowTitles.isEmpty {
                Text(LocalizedStrings.noWindowsFound)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(LocalizedStrings.selectWindowTitle, selection: $selectedWindowTitle) {
                        ForEach(windowTitles, id: \.self) { title in
                            Text(title).tag(title)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if !selectedWindowTitle.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(LocalizedStrings.selectedTitle + ":")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(selectedWindowTitle)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                    .help(LocalizedStrings.copyTitle)
                            }
                            .frame(height: 44)
                        }
                        
                        VStack(alignment: .leading, spacing: 12) {
                            Text(LocalizedStrings.extractionResult)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            HStack(spacing: 20) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(LocalizedStrings.currentStrategy): \(strategy.displayName)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    if strategy != .fullTitle {
                                        let currentSeparator = customSeparator.isEmpty ? getDefaultSeparator(for: strategy) : customSeparator
                                        Text("\(LocalizedStrings.currentSeparator): \"\(currentSeparator)\"")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Spacer()
                            }
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            
                            HStack {
                                Text(getExtractionResult())
                                    .font(.system(.title3, design: .monospaced))
                                    .fontWeight(.semibold)
                                    .foregroundColor(.accentColor)
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 2)
                                    )
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: strategy) { _ in
        }
        .onChange(of: customSeparator) { _ in
        }
    }
    
    private func getExtractionResult() -> String {
        guard !selectedWindowTitle.isEmpty else { return "" }
        
        let separator = strategy == .fullTitle ? nil : (customSeparator.isEmpty ? getDefaultSeparator(for: strategy) : customSeparator)
        
        return settingsManager.extractProjectName(
            from: selectedWindowTitle,
            using: strategy,
            customSeparator: separator
        )
    }
    
    private func getDefaultSeparator(for strategy: TitleExtractionStrategy) -> String {
        switch strategy {
        case .firstPart, .lastPart:
            return " - "
        case .beforeFirstSeparator:
            return " — "
        case .afterLastSeparator:
            return " - "
        case .fullTitle:
            return ""
        }
    }
}

struct AppConfigRowView: View {
    let config: AppTitleConfig
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(config.appName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Text(config.strategy.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                }
                
                Text(config.bundleId)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                if let separator = config.customSeparator, !separator.isEmpty, config.strategy != .fullTitle {
                    HStack(spacing: 4) {
                        Image(systemName: "scissors")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(LocalizedStrings.separatorLabel(separator))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help(LocalizedStrings.deleteConfigTooltip)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

struct AddAppConfigView: View {
    @Binding var bundleId: String
    @Binding var appName: String
    @Binding var strategy: TitleExtractionStrategy
    @Binding var customSeparator: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var windowTitles: [String] = []
    @State private var selectedWindowTitle: String = ""
    @State private var isLoadingPreview = false
    @State private var previewErrorMessage: String = ""
    @State private var showingPreview = false
    @StateObject private var windowManager = WindowManager()
    @StateObject private var settingsManager = SettingsManager.shared
    
    @State private var selectedApp: InstalledAppInfo? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(LocalizedStrings.addAppConfig)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.1), lineWidth: 1),
                alignment: .top
            )
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(LocalizedStrings.appSelectionSection)
                                .font(.headline)
                                .fontWeight(.medium)
                        }
                        
                        AppSelectionView(
                            selectedApp: $selectedApp,
                            bundleId: $bundleId,
                            appName: $appName
                        )
                    }
                    .padding(20)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.1), lineWidth: 1)
                    )
                    
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(LocalizedStrings.basicInfoSection)
                                .font(.headline)
                                .fontWeight(.medium)
                        }
                        
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(LocalizedStrings.bundleId)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                
                                HStack(spacing: 12) {
                                    TextField(LocalizedStrings.bundleIdPlaceholder, text: $bundleId)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                    
                                    Button(LocalizedStrings.preview) {
                                        loadPreview()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(bundleId.isEmpty || isLoadingPreview)
                                    .frame(minWidth: 120)
                                    .controlSize(.regular)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text(LocalizedStrings.appName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                
                                TextField(LocalizedStrings.appNamePlaceholder, text: $appName)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }
                        }
                    }
                    .padding(20)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.green.opacity(0.1), lineWidth: 1)
                    )
                    
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(LocalizedStrings.extractionStrategySection)
                                .font(.headline)
                                .fontWeight(.medium)
                        }
                        
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(LocalizedStrings.extractionStrategy)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                
                                Picker(LocalizedStrings.strategy, selection: $strategy) {
                                    ForEach(TitleExtractionStrategy.allCases, id: \.self) { strategy in
                                        Text(strategy.displayName).tag(strategy)
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .onChange(of: strategy) { newStrategy in
                                    if customSeparator.isEmpty || customSeparator == " - " {
                                        customSeparator = getDefaultSeparator(for: newStrategy)
                                    }
                                }
                            }
                            
                            if strategy != .fullTitle {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(LocalizedStrings.customSeparator)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                    
                                    TextField(getDefaultSeparatorPlaceholder(for: strategy), text: $customSeparator)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .help(getSeparatorHelpText(for: strategy))
                                }
                            }
                        }
                    }
                    .padding(20)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.orange.opacity(0.1), lineWidth: 1)
                    )
                    
                    if showingPreview {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text(LocalizedStrings.previewResultsSection)
                                    .font(.headline)
                                    .fontWeight(.medium)
                            }
                            
                            PreviewSectionView(
                                windowTitles: windowTitles,
                                selectedWindowTitle: $selectedWindowTitle,
                                strategy: strategy,
                                customSeparator: customSeparator,
                                isLoading: isLoadingPreview,
                                errorMessage: previewErrorMessage,
                                settingsManager: settingsManager
                            )
                        }
                        .padding(20)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.purple.opacity(0.1), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            
            HStack {
                Button(LocalizedStrings.cancel) {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                
                Spacer()
                
                Button(LocalizedStrings.save) {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(bundleId.isEmpty || appName.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.secondary.opacity(0.1), lineWidth: 1),
                alignment: .bottom
            )
        }
        .frame(width: 650, height: showingPreview ? 800 : 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
    
    private func loadPreview() {
        guard !bundleId.isEmpty else { return }
        
        isLoadingPreview = true
        previewErrorMessage = ""
        showingPreview = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            let titles = windowManager.getWindowTitlesForPreview(bundleId)
            
            DispatchQueue.main.async {
                isLoadingPreview = false
                
                if titles.isEmpty {
                    previewErrorMessage = LocalizedStrings.appNotRunning
                    windowTitles = []
                    selectedWindowTitle = ""
                } else {
                    windowTitles = titles
                    selectedWindowTitle = titles.first ?? ""
                    previewErrorMessage = ""
                }
            }
        }
    }
    
    private func getDefaultSeparatorPlaceholder(for strategy: TitleExtractionStrategy) -> String {
        switch strategy {
        case .firstPart, .lastPart:
            return LocalizedStrings.separatorPlaceholderFirstLastPart
        case .beforeFirstSeparator:
            return LocalizedStrings.separatorPlaceholderBeforeFirst
        case .afterLastSeparator:
            return LocalizedStrings.separatorPlaceholderAfterLast

        case .fullTitle:
            return ""
        }
    }
    
    private func getSeparatorHelpText(for strategy: TitleExtractionStrategy) -> String {
        switch strategy {
        case .firstPart:
            return LocalizedStrings.separatorHelpFirstPart
        case .lastPart:
            return LocalizedStrings.separatorHelpLastPart
        case .beforeFirstSeparator:
            return LocalizedStrings.separatorHelpBeforeFirst
        case .afterLastSeparator:
            return LocalizedStrings.separatorHelpAfterLast

        case .fullTitle:
            return ""
        }
    }
    
    private func getDefaultSeparator(for strategy: TitleExtractionStrategy) -> String {
        switch strategy {
        case .firstPart, .lastPart:
            return " - "
        case .beforeFirstSeparator:
            return " — "
        case .afterLastSeparator:
            return " - "
        case .fullTitle:
            return ""
        }
    }
}

// MARK: - About Pane

private struct AboutFeature: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

struct AboutView: View {
    private var features: [AboutFeature] {
        [
            AboutFeature(icon: "rectangle.on.rectangle",
                         title: LocalizedStrings.feature1Title, detail: LocalizedStrings.feature1Detail),
            AboutFeature(icon: "square.grid.3x3.topleft.filled",
                         title: LocalizedStrings.feature2Title, detail: LocalizedStrings.feature2Detail),
            AboutFeature(icon: "macwindow.on.rectangle",
                         title: LocalizedStrings.feature3Title, detail: LocalizedStrings.feature3Detail),
            AboutFeature(icon: "dock.rectangle",
                         title: LocalizedStrings.feature4Title, detail: LocalizedStrings.feature4Detail),
            AboutFeature(icon: "keyboard",
                         title: LocalizedStrings.feature5Title, detail: LocalizedStrings.feature5Detail),
            AboutFeature(icon: "textformat",
                         title: LocalizedStrings.feature6Title, detail: LocalizedStrings.feature6Detail),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Identity
            HStack(spacing: 14) {
                AppMainIconView()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lineup")
                        .font(.title2).fontWeight(.bold)
                    Text(LocalizedStrings.version)
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(LocalizedStrings.appDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }

            // Features
            SettingsSection(title: LocalizedStrings.mainFeatures) {
                ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                    if index > 0 { RowDivider() }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: feature.icon)
                            .font(.system(size: 15))
                            .foregroundColor(.accentColor)
                            .frame(width: 24, height: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(.system(size: 13, weight: .medium))
                            Text(feature.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                }
            }

            // Project link
            SettingsSection(title: LocalizedStrings.developmentInfo) {
                Button {
                    if let url = URL(string: "https://github.com/cleyrop/Lineup") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text(LocalizedStrings.gitHub)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer(minLength: 8)
                        Text("cleyrop/Lineup")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text(LocalizedStrings.copyright)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - App Main Icon View
struct AppMainIconView: View {
    var body: some View {
        if let nsImage = loadAppIcon() {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "rectangle.3.group")
                .font(.largeTitle)
                .foregroundColor(.accentColor)
        }
    }
    
    private func loadAppIcon() -> NSImage? {
        if let appIcon = NSApp.applicationIconImage {
            return appIcon
        }
        
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let nsImage = NSImage(contentsOfFile: iconPath) {
            return nsImage
        }
        
        return nil
    }
}

// MARK: - Switcher Pane
struct SwitcherPaneView: View {
    @StateObject private var settingsManager = SettingsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(title: LocalizedStrings.switcherDisplaySectionTitle) {
                SettingsRow(title: LocalizedStrings.showNumberKeysLabel,
                            subtitle: LocalizedStrings.showNumberKeysDescription) {
                    Toggle("", isOn: Binding(
                        get: { settingsManager.settings.showNumberKeys },
                        set: { settingsManager.updateShowNumberKeys($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                RowDivider()
                SettingsRow(title: LocalizedStrings.followActiveWindowLabel,
                            subtitle: LocalizedStrings.followActiveWindowDescription) {
                    Toggle("", isOn: Binding(
                        get: { settingsManager.settings.switcherFollowActiveWindow },
                        set: { settingsManager.updateSwitcherFollowActiveWindow($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                RowDivider()
                SettingsRow(title: LocalizedStrings.showWindowsFromAllSpacesLabel,
                            subtitle: LocalizedStrings.showWindowsFromAllSpacesDescription) {
                    Toggle("", isOn: Binding(
                        get: { settingsManager.settings.showWindowsFromAllSpaces },
                        set: { settingsManager.updateShowWindowsFromAllSpaces($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                RowDivider()
                SettingsRow(title: LocalizedStrings.followAcrossDesktopsLabel,
                            subtitle: LocalizedStrings.followAcrossDesktopsDescription) {
                    Toggle("", isOn: Binding(
                        get: { settingsManager.settings.followAcrossDesktops },
                        set: { settingsManager.updateFollowAcrossDesktops($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                RowDivider()
                SettingsRow(title: LocalizedStrings.doubleTapToHoldLabel,
                            subtitle: LocalizedStrings.doubleTapToHoldDescription) {
                    Toggle("", isOn: Binding(
                        get: { settingsManager.settings.doubleTapToHold },
                        set: { settingsManager.updateDoubleTapToHold($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                RowDivider()
                SettingsRow(title: LocalizedStrings.windowDisplayStyleLabel,
                            subtitle: LocalizedStrings.windowDisplayStyleDescription) {
                    Picker("", selection: Binding(
                        get: { settingsManager.settings.windowDisplayStyle },
                        set: { settingsManager.updateWindowDisplayStyle($0) }
                    )) {
                        ForEach(WindowDisplayStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            SettingsSection(title: LocalizedStrings.switcherVerticalPositionLabel) {
                SettingsStackedRow(title: LocalizedStrings.switcherVerticalPositionLabel,
                                   subtitle: LocalizedStrings.switcherVerticalPositionDescription) {
                    VerticalPositionControl()
                }
                RowDivider()
                SettingsRow(title: LocalizedStrings.switcherHeaderStyleLabel,
                            subtitle: LocalizedStrings.switcherHeaderStyleDescription) {
                    Picker("", selection: Binding(
                        get: { settingsManager.settings.switcherHeaderStyle },
                        set: { settingsManager.updateSwitcherHeaderStyle($0) }
                    )) {
                        ForEach(SwitcherHeaderStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
        }
    }
}

// MARK: - Appearance Pane
struct AppearancePaneView: View {
    var body: some View {
        SettingsSection(title: LocalizedStrings.colorSchemeLabel) {
            SettingsStackedRow(title: LocalizedStrings.colorSchemeLabel,
                               subtitle: LocalizedStrings.colorSchemeDescription) {
                ColorSchemePickerView()
                ColorSchemePreviewView()
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - Vertical Position Control
struct VerticalPositionControl: View {
    @StateObject private var settingsManager = SettingsManager.shared
    @State private var textFieldValue: String = ""
    
    private var currentPosition: Double {
        settingsManager.settings.switcherVerticalPosition
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Slider and TextField row
            HStack(spacing: 12) {
                // Slider
                Slider(
                    value: Binding(
                        get: { currentPosition },
                        set: { newValue in
                            settingsManager.updateSwitcherVerticalPosition(newValue)
                            textFieldValue = String(format: "%.2f", newValue)
                        }
                    ),
                    in: 0.1...0.8,
                    step: 0.01
                )
                .frame(minWidth: 120)
                
                
                // Reset button
                Button(LocalizedStrings.resetToGoldenRatio) {
                    settingsManager.updateSwitcherVerticalPosition(0.39)
                    textFieldValue = "0.39"
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            
            // Current value display
            Text("Current: \(String(format: "%.1f%%", currentPosition * 100))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear {
            textFieldValue = String(format: "%.2f", currentPosition)
        }
        .onChange(of: currentPosition) { newValue in
            textFieldValue = String(format: "%.2f", newValue)
        }
    }
}

// MARK: - Color Scheme Picker View
struct ColorSchemePickerView: View {
    @StateObject private var settingsManager = SettingsManager.shared
    
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
            ForEach(ColorScheme.allCases, id: \.self) { scheme in
                ColorSchemeCardView(
                    scheme: scheme,
                    isSelected: settingsManager.settings.colorScheme == scheme
                ) {
                    settingsManager.updateColorScheme(scheme)
                }
            }
        }
    }
}

// MARK: - Color Scheme Preview View
/// Live preview of how the chosen scheme tints the (list-only) switcher.
struct ColorSchemePreviewView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStrings.colorSchemePreviewTitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            ListPreviewView()
                .frame(maxWidth: 320)
        }
    }
}

// MARK: - List Preview View
struct ListPreviewView: View {
    @StateObject private var settingsManager = SettingsManager.shared

    var body: some View {
        let colorScheme = settingsManager.settings.colorScheme

        VStack(spacing: 3) {
            // Selected row
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(colorScheme.primaryColor.opacity(0.9))
                    .frame(width: 14, height: 14)
                Text(LocalizedStrings.colorSchemeSampleApp)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(colorScheme.primaryColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(colorScheme.primaryColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Unselected row
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(colorScheme.secondaryColor.opacity(0.7))
                    .frame(width: 14, height: 14)
                Text(LocalizedStrings.colorSchemeSampleWindow)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Color Scheme Card View
struct ColorSchemeCardView: View {
    let scheme: ColorScheme
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 7) {
                // Clean rounded swatch: the scheme gradient with a primary-colour bar.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(scheme.backgroundGradient)
                    .frame(height: 40)
                    .overlay(
                        Capsule()
                            .fill(scheme.primaryColor)
                            .frame(width: 18, height: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                Text(scheme.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Settings Design System
//
// A small, consistent set of building blocks for the preferences UI, modelled on
// macOS System Settings: an uppercase group caption above a single rounded card,
// rows with a title + optional description on the left and a control on the right,
// separated by inset hairlines.

/// A titled group: caption + a rounded card wrapping its rows.
struct SettingsSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased())
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .padding(.top, 2)
            }
        }
    }
}

/// A single settings row: title + optional description, with a trailing control.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// A row that stacks its control beneath the title (for sliders, grids, etc.).
struct SettingsStackedRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Inset hairline used between rows inside a SettingsSection.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 16)
    }
}

// MARK: - Notification Extensions
extension Notification.Name {
    static let hotkeySettingsChanged = Notification.Name("hotkeySettingsChanged")
}

#Preview {
    PreferencesView()
}
