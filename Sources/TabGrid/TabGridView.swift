import SwiftUI
import UniformTypeIdentifiers

struct TabGridView: View {
    enum Mode: Hashable {
        case tabs
        case trash
    }

    @EnvironmentObject var tabStore: TabStore
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode
    @State private var renamingTabID: UUID?
    @State private var renameText: String = ""
    @State private var pendingCloseTabID: UUID?
    @State private var showCloseConfirmation = false
    @State private var showSaveAsExporter = false
    @State private var closeAfterSaveAs = false
    @State private var trashActionsTabID: UUID?
    @State private var pendingDeleteTabID: UUID?
    @State private var showEmptyTrashConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    init(mode: Mode = .tabs) {
        _mode = State(initialValue: mode)
    }

    private var themeBackground: Color {
        let theme = EditorTheme.current(for: settings.appearanceOverride)
        return Color(theme.background)
    }

    private var themeForeground: Color {
        let theme = EditorTheme.current(for: settings.appearanceOverride)
        return Color(theme.foreground)
    }

    private var pendingDeleteName: String {
        tabStore.trashedTabs.first { $0.id == pendingDeleteTabID }?.name
            ?? String(localized: "tab.untitled", defaultValue: "Untitled")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(selection: $mode) {
                    Text(String(localized: "tabs.title", defaultValue: "Tabs")).tag(Mode.tabs)
                    Text(String(localized: "trash.title", defaultValue: "Trash")).tag(Mode.trash)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if mode == .tabs {
                    tabsGrid
                } else {
                    trashGrid
                }
            }
            .navigationTitle(mode == .tabs
                ? String(localized: "tabs.title", defaultValue: "Tabs")
                : String(localized: "trash.title", defaultValue: "Trash"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "common.done", defaultValue: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if mode == .tabs {
                        Button {
                            tabStore.addNewTab()
                            dismiss()
                        } label: {
                            Image(systemName: "plus")
                        }
                    } else {
                        Button(role: .destructive) {
                            showEmptyTrashConfirmation = true
                        } label: {
                            Label(String(localized: "trash.empty", defaultValue: "Empty trash"), systemImage: "trash")
                        }
                        .disabled(tabStore.trashedTabs.isEmpty)
                    }
                }
            }
            .alert(String(localized: "tab.rename.title", defaultValue: "Rename tab"), isPresented: .init(
                get: { renamingTabID != nil },
                set: { if !$0 { renamingTabID = nil } }
            )) {
                TextField(String(localized: "tab.rename.placeholder", defaultValue: "Tab name"), text: $renameText)
                Button(String(localized: "alert.save_changes.cancel", defaultValue: "Cancel"), role: .cancel) { renamingTabID = nil }
                Button(String(localized: "tab.context.rename", defaultValue: "Rename")) {
                    if let id = renamingTabID {
                        tabStore.renameTab(id: id, name: renameText)
                    }
                    renamingTabID = nil
                }
            }
            .alert(
                {
                    let name = tabStore.tabs.first { $0.id == pendingCloseTabID }?.name ?? String(localized: "tab.untitled", defaultValue: "Untitled")
                    return String(localized: "alert.save_changes.title", defaultValue: "Do you want to save changes to \"\(name)\"?")
                }(),
                isPresented: $showCloseConfirmation
            ) {
                Button(String(localized: "alert.save_changes.save", defaultValue: "Save")) {
                    if let id = pendingCloseTabID {
                        if let tab = tabStore.tabs.first(where: { $0.id == id }), tab.fileURL != nil {
                            tabStore.saveFile(id: id)
                            tabStore.closeTab(id: id)
                        } else {
                            closeAfterSaveAs = true
                            showSaveAsExporter = true
                        }
                    }
                    if !closeAfterSaveAs {
                        pendingCloseTabID = nil
                    }
                }
                Button(String(localized: "alert.save_changes.dont_save", defaultValue: "Don't save"), role: .destructive) {
                    if let id = pendingCloseTabID {
                        tabStore.closeTab(id: id)
                    }
                    pendingCloseTabID = nil
                }
                Button(String(localized: "alert.save_changes.cancel", defaultValue: "Cancel"), role: .cancel) {
                    pendingCloseTabID = nil
                }
            } message: {
                Text(String(localized: "alert.save_changes.message", defaultValue: "Your changes will be lost if you don't save them."))
            }
            .fileExporter(
                isPresented: $showSaveAsExporter,
                document: TextFileDocument(content: tabStore.tabs.first { $0.id == pendingCloseTabID }?.content ?? ""),
                contentType: .plainText,
                defaultFilename: tabStore.tabs.first { $0.id == pendingCloseTabID }?.name ?? String(localized: "tab.untitled", defaultValue: "Untitled")
            ) { result in
                if case .success(let url) = result, let id = pendingCloseTabID {
                    tabStore.completeSaveAs(id: id, url: url)
                    if closeAfterSaveAs {
                        tabStore.closeTab(id: id)
                    }
                }
                pendingCloseTabID = nil
                closeAfterSaveAs = false
            }
            .onChange(of: showSaveAsExporter) { _, isShown in
                // fileExporter does not invoke onCompletion when the user
                // cancels – clear the pending close state so a later save
                // can't act on a stale tab id
                if !isShown {
                    pendingCloseTabID = nil
                    closeAfterSaveAs = false
                }
            }
            .confirmationDialog(
                tabStore.trashedTabs.first { $0.id == trashActionsTabID }?.name ?? String(localized: "tab.untitled", defaultValue: "Untitled"),
                isPresented: .init(
                    get: { trashActionsTabID != nil },
                    set: { if !$0 { trashActionsTabID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(String(localized: "trash.restore", defaultValue: "Restore")) {
                    if let id = trashActionsTabID {
                        tabStore.restoreFromTrash(id: id)
                    }
                    trashActionsTabID = nil
                }
                Button(String(localized: "trash.delete_now", defaultValue: "Delete now"), role: .destructive) {
                    pendingDeleteTabID = trashActionsTabID
                    trashActionsTabID = nil
                }
                Button(String(localized: "alert.save_changes.cancel", defaultValue: "Cancel"), role: .cancel) {
                    trashActionsTabID = nil
                }
            }
            .alert(
                String(localized: "trash.confirm_delete.title", defaultValue: "Delete \"\(pendingDeleteName)\" permanently?"),
                isPresented: .init(
                    get: { pendingDeleteTabID != nil },
                    set: { if !$0 { pendingDeleteTabID = nil } }
                )
            ) {
                Button(String(localized: "trash.confirm_delete.delete", defaultValue: "Delete"), role: .destructive) {
                    if let id = pendingDeleteTabID {
                        tabStore.deletePermanently(id: id)
                    }
                    pendingDeleteTabID = nil
                }
                Button(String(localized: "alert.save_changes.cancel", defaultValue: "Cancel"), role: .cancel) {
                    pendingDeleteTabID = nil
                }
            } message: {
                Text(String(localized: "trash.confirm_delete.message", defaultValue: "Its version history will be deleted too. This cannot be undone."))
            }
            .alert(
                String(localized: "trash.confirm_empty.title", defaultValue: "Empty trash?"),
                isPresented: $showEmptyTrashConfirmation
            ) {
                Button(String(localized: "trash.empty", defaultValue: "Empty trash"), role: .destructive) {
                    tabStore.emptyTrash()
                }
                Button(String(localized: "alert.save_changes.cancel", defaultValue: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "trash.confirm_empty.message", defaultValue: "All trashed notes and their version history will be deleted. This cannot be undone."))
            }
        }
    }

    private var tabsGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(tabStore.tabs) { tab in
                    TabCardView(
                        tab: tab,
                        isSelected: tab.id == tabStore.selectedTabID,
                        themeBackground: themeBackground,
                        themeForeground: themeForeground,
                        onClose: { requestClose(tab: tab) }
                    )
                    .onTapGesture {
                        tabStore.selectedTabID = tab.id
                        dismiss()
                    }
                    .contextMenu {
                        Button(String(localized: "tab.context.rename", defaultValue: "Rename")) {
                            renameText = tab.name
                            renamingTabID = tab.id
                        }
                        Button(String(localized: "tab.context.delete", defaultValue: "Delete"), role: .destructive) {
                            requestClose(tab: tab)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var trashGrid: some View {
        if tabStore.trashedTabs.isEmpty {
            ContentUnavailableView(
                String(localized: "trash.empty_state", defaultValue: "Trash is empty"),
                systemImage: "trash"
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(tabStore.trashedTabs) { tab in
                        VStack(alignment: .leading, spacing: 4) {
                            TabCardView(
                                tab: tab,
                                isSelected: false,
                                themeBackground: themeBackground,
                                themeForeground: themeForeground
                            )
                            .opacity(0.6)
                            Text(deletedCaption(for: tab))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            trashActionsTabID = tab.id
                        }
                        .contextMenu {
                            Button {
                                tabStore.restoreFromTrash(id: tab.id)
                            } label: {
                                Label(String(localized: "trash.restore", defaultValue: "Restore"), systemImage: "arrow.uturn.backward")
                            }
                            Button(role: .destructive) {
                                pendingDeleteTabID = tab.id
                            } label: {
                                Label(String(localized: "trash.delete_now", defaultValue: "Delete now"), systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func deletedCaption(for tab: TabData) -> String {
        let relative = (tab.deletedAt ?? Date()).formatted(.relative(presentation: .named))
        let device = tab.deletedOn
            ?? String(localized: "history.conflict_device_unknown", defaultValue: "another device")
        return String(localized: "trash.deleted_on", defaultValue: "Deleted \(relative) on \(device)")
    }

    private func requestClose(tab: TabData) {
        if tab.hasUnsavedChanges {
            pendingCloseTabID = tab.id
            showCloseConfirmation = true
        } else {
            tabStore.closeTab(id: tab.id)
        }
    }
}
