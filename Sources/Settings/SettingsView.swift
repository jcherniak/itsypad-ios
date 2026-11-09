import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "settings.sync.title", defaultValue: "Sync")) {
                    Toggle(String(localized: "settings.sync.icloud", defaultValue: "iCloud sync"), isOn: Binding(
                        get: { settings.icloudSync },
                        set: { settings.setICloudSync($0) }
                    ))
                }

                Section {
                    Picker(String(localized: "settings.launch.behavior", defaultValue: "On launch"), selection: $settings.launchBehavior) {
                        Text(String(localized: "settings.launch.reopen_last", defaultValue: "Reopen last note")).tag(LaunchBehavior.reopenLast)
                        Text(String(localized: "settings.launch.new_note", defaultValue: "Start new note")).tag(LaunchBehavior.newNote)
                    }

                    Toggle(String(localized: "settings.launch.auto_paste", defaultValue: "Paste clipboard on open"), isOn: $settings.autoPasteOnOpen)
                } header: {
                    Text(String(localized: "settings.launch.title", defaultValue: "Launch"))
                } footer: {
                    Text(String(localized: "settings.launch.auto_paste_footer", defaultValue: "Inserts the clipboard into the current note when Itsypad opens. A banner lets you undo it with one tap."))
                }

                Section {
                    Toggle(String(localized: "settings.history.enabled", defaultValue: "Save version history"), isOn: $settings.versionHistoryEnabled)

                    Picker(String(localized: "settings.history.keep_count", defaultValue: "Keep versions"), selection: $settings.versionKeepCount) {
                        Text(String(localized: "settings.history.unlimited", defaultValue: "Unlimited")).tag(0)
                        ForEach([50, 100, 200, 500], id: \.self) { Text("\($0)").tag($0) }
                    }

                    Picker(String(localized: "settings.history.keep_days", defaultValue: "Keep for"), selection: $settings.versionKeepDays) {
                        Text(String(localized: "settings.history.unlimited", defaultValue: "Unlimited")).tag(0)
                        ForEach([7, 30, 90, 365], id: \.self) { days in
                            Text(String(localized: "settings.history.days", defaultValue: "\(days) days")).tag(days)
                        }
                    }

                    Picker(String(localized: "settings.history.trash_auto_empty", defaultValue: "Empty trash after"), selection: $settings.trashAutoEmptyDays) {
                        Text(String(localized: "settings.history.never", defaultValue: "Never")).tag(0)
                        ForEach([7, 30, 90], id: \.self) { days in
                            Text(String(localized: "settings.history.days", defaultValue: "\(days) days")).tag(days)
                        }
                    }
                } header: {
                    Text(String(localized: "settings.history.title", defaultValue: "History"))
                } footer: {
                    Text(String(localized: "settings.history.footer", defaultValue: "Versions are saved automatically while you type and synced with iCloud. The first, latest and named versions are always kept."))
                }

                Section(String(localized: "settings.appearance.title", defaultValue: "Appearance")) {
                    Picker(String(localized: "settings.appearance.mode", defaultValue: "Mode"), selection: $settings.appearanceOverride) {
                        Text(String(localized: "settings.appearance.system", defaultValue: "System")).tag("system")
                        Text(String(localized: "settings.appearance.light", defaultValue: "Light")).tag("light")
                        Text(String(localized: "settings.appearance.dark", defaultValue: "Dark")).tag("dark")
                    }

                    Picker(String(localized: "settings.appearance.syntax_theme", defaultValue: "Syntax theme"), selection: $settings.syntaxTheme) {
                        ForEach(SyntaxThemeRegistry.themes, id: \.id) { theme in
                            Text(theme.displayName).tag(theme.id)
                        }
                    }

                    HStack {
                        Text(String(localized: "settings.appearance.font_size", defaultValue: "Font size"))
                        Spacer()
                        Stepper("\(Int(settings.editorFontSize))", value: $settings.editorFontSize, in: 8...32, step: 1)
                    }
                }

                Section(String(localized: "settings.indentation.title", defaultValue: "Indentation")) {
                    Toggle(String(localized: "settings.indentation.use_spaces", defaultValue: "Indent using spaces"), isOn: $settings.indentUsingSpaces)

                    Stepper("Tab width: \(settings.tabWidth)", value: $settings.tabWidth, in: 1...8)
                }

                Section(String(localized: "settings.lists.title", defaultValue: "Lists")) {
                    Toggle(String(localized: "settings.lists.bullet", defaultValue: "Bullet lists"), isOn: $settings.bulletListsEnabled)
                    Toggle(String(localized: "settings.lists.numbered", defaultValue: "Numbered lists"), isOn: $settings.numberedListsEnabled)
                    Toggle(String(localized: "settings.lists.checklists", defaultValue: "Checklists"), isOn: $settings.checklistsEnabled)
                }

                Section(String(localized: "settings.spacing.title", defaultValue: "Spacing")) {
                    HStack {
                        Text(String(localized: "settings.spacing.line", defaultValue: "Line spacing"))
                        Spacer()
                        Stepper(
                            String(format: "%.1f", settings.lineSpacing),
                            value: $settings.lineSpacing,
                            in: 1.0...2.0,
                            step: 0.1
                        )
                    }

                    HStack {
                        Text(String(localized: "settings.spacing.letter", defaultValue: "Letter spacing"))
                        Spacer()
                        Stepper(
                            String(format: "%.1f", settings.letterSpacing),
                            value: $settings.letterSpacing,
                            in: 0.0...5.0,
                            step: 0.5
                        )
                    }
                }

                Section(String(localized: "settings.editor.title", defaultValue: "Editor")) {
                    Toggle(String(localized: "settings.editor.word_wrap", defaultValue: "Word wrap"), isOn: $settings.wordWrap)
                    Toggle(String(localized: "settings.editor.line_numbers", defaultValue: "Line numbers"), isOn: $settings.showLineNumbers)
                    Toggle(String(localized: "settings.editor.clickable_links", defaultValue: "Clickable links"), isOn: $settings.clickableLinks)
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        Toggle(String(localized: "settings.editor.lock_rotation", defaultValue: "Lock rotation"), isOn: $settings.lockRotation)
                    }
                }

                Section {
                    Link(destination: URL(string: "https://itsypad.app")!) {
                        HStack {
                            Text(String(localized: "settings.about.website", defaultValue: "itsypad.app"))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Link(destination: URL(string: "https://github.com/nickustinov/itsypad-macos/discussions")!) {
                        HStack {
                            Text(String(localized: "settings.about.community", defaultValue: "Community"))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Itsypad \(appVersion) (\(appBuild))")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.done", defaultValue: "Done")) { dismiss() }
                }
            }
        }
    }
}
