import SwiftUI

struct VersionHistoryView: View {
    let tabID: UUID
    @EnvironmentObject var tabStore: TabStore
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var versionStore: VersionStore
    @Environment(\.dismiss) private var dismiss

    init(tabID: UUID, versionStore: VersionStore = .shared) {
        self.tabID = tabID
        _versionStore = ObservedObject(wrappedValue: versionStore)
    }

    private var versions: [TabVersion] {
        versionStore.versions(for: tabID)
    }

    private var hasConflict: Bool {
        tabStore.tabs.first { $0.id == tabID }?.hasConflict ?? false
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let versions: [TabVersion]
        var id: Date { day }
    }

    private var days: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: versions) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { DayGroup(day: $0, versions: grouped[$0]!) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if versions.isEmpty {
                    ContentUnavailableView(
                        String(localized: "history.empty", defaultValue: "No versions yet – versions are saved automatically while you type."),
                        systemImage: "clock.arrow.circlepath"
                    )
                } else {
                    List {
                        ForEach(days) { group in
                            Section(group.day.formatted(date: .long, time: .omitted)) {
                                ForEach(group.versions) { version in
                                    NavigationLink {
                                        VersionDetailView(
                                            tabID: tabID,
                                            version: version,
                                            versionStore: versionStore,
                                            closeSheet: { dismiss() }
                                        )
                                    } label: {
                                        VersionRow(version: version, previous: olderVersion(before: version))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "history.title", defaultValue: "Version history"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if hasConflict {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            tabStore.resolveConflict(id: tabID)
                        } label: {
                            Label(String(localized: "history.resolve", defaultValue: "Resolve"), systemImage: "checkmark.circle")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done", defaultValue: "Done")) { dismiss() }
                }
            }
        }
    }

    private func olderVersion(before version: TabVersion) -> TabVersion? {
        let all = versions
        guard let i = all.firstIndex(where: { $0.id == version.id }), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
}

private struct VersionRow: View {
    let version: TabVersion
    let previous: TabVersion?

    private var preview: String {
        version.text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    private var delta: (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in LineDiff.diff(old: previous?.text ?? "", new: version.text) {
            switch line.kind {
            case .added: added += line.text.utf16.count
            case .removed: removed += line.text.utf16.count
            case .same: break
            }
        }
        return (added, removed)
    }

    var body: some View {
        let counts = delta
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: version.source.symbolName)
                .foregroundStyle(version.source == .conflict ? Color.orange : Color.accentColor)
                .frame(width: 20)
                .accessibilityLabel(version.source.accessibilityLabel)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(version.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.subheadline.weight(.medium))
                    Text(version.device)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(String(localized: "history.row.delta", defaultValue: "+\(counts.added) −\(counts.removed)"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let label = version.label, !label.isEmpty {
                    Text(label)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct VersionDetailView: View {
    let tabID: UUID
    let version: TabVersion
    @ObservedObject var versionStore: VersionStore
    let closeSheet: () -> Void
    @EnvironmentObject var tabStore: TabStore
    @EnvironmentObject var settings: SettingsStore
    @State private var showNameAlert = false
    @State private var nameDraft = ""

    private var currentText: String {
        tabStore.tabs.first { $0.id == tabID }?.content ?? ""
    }

    private var currentLabel: String? {
        versionStore.versions(for: tabID).first { $0.id == version.id }?.label
    }

    var body: some View {
        let lines = LineDiff.diff(old: currentText, new: version.text)
        let font = Font.system(size: settings.editorFontSize, design: .monospaced)
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(font)
                        .strikethrough(line.kind == .removed)
                        .foregroundStyle(line.kind == .removed ? Color.secondary : Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(for: line.kind))
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle(currentLabel ?? version.createdAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    nameDraft = currentLabel ?? ""
                    showNameAlert = true
                } label: {
                    Label(String(localized: "history.name_version", defaultValue: "Name this version"), systemImage: "bookmark")
                }
                Button {
                    tabStore.restoreVersion(id: tabID, version: version)
                    closeSheet()
                } label: {
                    Label(String(localized: "history.restore", defaultValue: "Restore"), systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .alert(String(localized: "history.name_version", defaultValue: "Name this version"), isPresented: $showNameAlert) {
            TextField(String(localized: "history.name_version.placeholder", defaultValue: "Name"), text: $nameDraft)
            Button(String(localized: "history.name_version.save", defaultValue: "Save")) {
                tabStore.setVersionLabel(nameDraft, versionID: version.id, tabID: tabID)
            }
            Button(String(localized: "history.name_version.cancel", defaultValue: "Cancel"), role: .cancel) {}
        }
    }

    private func background(for kind: LineDiff.Line.Kind) -> Color {
        switch kind {
        case .same: return .clear
        case .added: return Color.green.opacity(0.2)
        case .removed: return Color.red.opacity(0.18)
        }
    }
}

extension TabVersion.Source {
    var symbolName: String {
        switch self {
        case .edit: return "pencil"
        case .paste: return "doc.on.clipboard"
        case .conflict: return "exclamationmark.triangle"
        case .restore: return "clock.arrow.circlepath"
        case .manual: return "bookmark"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .edit: return String(localized: "history.source.edit", defaultValue: "Edited")
        case .paste: return String(localized: "history.source.paste", defaultValue: "Pasted")
        case .conflict: return String(localized: "history.source.conflict", defaultValue: "Conflict copy")
        case .restore: return String(localized: "history.source.restore", defaultValue: "Restored")
        case .manual: return String(localized: "history.source.manual", defaultValue: "Named")
        }
    }
}
