import Foundation

struct TabData: Identifiable, Equatable {
    let id: UUID
    var name: String
    var content: String
    var language: String
    var fileURL: URL?
    /// Security-scoped bookmark for fileURL – required to regain write access
    /// to files imported from outside the sandbox after the picker's grant ends.
    var fileBookmark: Data?
    var languageLocked: Bool
    var isDirty: Bool
    var cursorPosition: Int

    var hasUnsavedChanges: Bool {
        if fileURL != nil { return isDirty }
        return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var lastModified: Date

    init(
        id: UUID = UUID(),
        name: String = "Untitled",
        content: String = "",
        language: String = "plain",
        fileURL: URL? = nil,
        fileBookmark: Data? = nil,
        languageLocked: Bool = false,
        isDirty: Bool = false,
        cursorPosition: Int = 0,
        lastModified: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.language = language
        self.fileURL = fileURL
        self.fileBookmark = fileBookmark
        self.languageLocked = languageLocked
        self.isDirty = isDirty
        self.cursorPosition = cursorPosition
        self.lastModified = lastModified
    }
}

extension TabData: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        content = try c.decode(String.self, forKey: .content)
        language = try c.decode(String.self, forKey: .language)
        fileURL = try c.decodeIfPresent(URL.self, forKey: .fileURL)
        fileBookmark = try c.decodeIfPresent(Data.self, forKey: .fileBookmark)
        languageLocked = try c.decode(Bool.self, forKey: .languageLocked)
        isDirty = try c.decodeIfPresent(Bool.self, forKey: .isDirty) ?? false
        cursorPosition = try c.decode(Int.self, forKey: .cursorPosition)
        lastModified = try c.decodeIfPresent(Date.self, forKey: .lastModified) ?? .distantPast
    }
}

class TabStore: ObservableObject {
    static let shared = TabStore()

    @Published var tabs: [TabData] = []
    @Published var selectedTabID: UUID? {
        didSet {
            if isInitialized, let previous = oldValue, previous != selectedTabID {
                snapshotIfChanged(id: previous, source: .edit)
            }
        }
    }
    @Published var lastICloudSync: Date?
    @Published var fileSaveError: String?

    private var saveDebounceWork: DispatchWorkItem?
    private var languageDetectWork: [UUID: DispatchWorkItem] = [:]
    private let sessionURL: URL

    // Version history – injectable so tests neither sleep nor touch the real store
    var versionStore: VersionStore = .shared
    var now: () -> Date = { Date() }
    var idleInterval: TimeInterval = 3
    var holdInterval: TimeInterval = 10
    var deviceName: String = TabVersion.currentDeviceName
    var historySettings: () -> (enabled: Bool, keepCount: Int, keepDays: Int) = {
        let s = SettingsStore.shared
        return (s.versionHistoryEnabled, s.versionKeepCount, s.versionKeepDays)
    }
    var versionSyncPolicy: (TabData) -> Bool = { $0.fileURL == nil && SettingsStore.shared.icloudSync }

    private struct VersionTracking {
        var latestText: String?
        var idleWork: DispatchWorkItem?
        var heldSnapshot: TabVersion?
        var holdWork: DispatchWorkItem?
    }
    private var versionTracking: [UUID: VersionTracking] = [:]
    private var pendingExternalCursor: [UUID: Int] = [:]
    private var isInitialized = false

    var selectedTab: TabData? {
        tabs.first { $0.id == selectedTabID }
    }

    init(sessionURL: URL? = nil, launchBehavior: LaunchBehavior? = nil) {
        if let sessionURL {
            self.sessionURL = sessionURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let itsypadDir = appSupport.appendingPathComponent("Itsypad")
            try? FileManager.default.createDirectory(at: itsypadDir, withIntermediateDirectories: true)
            self.sessionURL = itsypadDir.appendingPathComponent("session.json")
        }

        restoreSession()

        if tabs.isEmpty {
            let isFirstLaunch = !FileManager.default.fileExists(atPath: self.sessionURL.path)
            if isFirstLaunch {
                addWelcomeTab()
            } else {
                addNewTab()
            }
        } else if (launchBehavior ?? SettingsStore.shared.launchBehavior) == .newNote {
            let isBlankScratch = selectedTab.map {
                $0.fileURL == nil && $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? false
            if !isBlankScratch {
                addNewTab()
            }
        }
        isInitialized = true
    }

    // MARK: - Tab operations

    func addNewTab() {
        let tab = TabData()
        tabs.append(tab)
        selectedTabID = tab.id
        scheduleSave()
        CloudSyncEngine.shared.recordChanged(tab.id)
    }

    static var welcomeContent: String {
        String(localized: "welcome.content", defaultValue: """
        # Welcome to Itsypad for iOS

        A tiny, fast scratchpad that lives in your pocket.

        Here's what you can do:

        - [x] Download Itsypad
        - [ ] Write notes, ideas, code snippets
        - [ ] Use automatic checklists, bullet and numbered lists
        - [ ] Try Itsypad for macOS
        - [ ] Browse clipboard history from Mac
        - [ ] Sync tabs across devices with iCloud
        - [ ] Switch between themes in settings

        Happy writing! Close this tab whenever you're ready to start.
        """)
    }

    func addWelcomeTab() {
        let tab = TabData(
            name: String(localized: "welcome.tab_name", defaultValue: "Welcome to Itsypad for iOS"),
            content: Self.welcomeContent,
            language: "markdown"
        )
        tabs.append(tab)
        selectedTabID = tab.id
        scheduleSave()
    }

    func selectNeighborTab(delta: Int) {
        guard let id = selectedTabID,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = index + delta
        guard tabs.indices.contains(newIndex) else { return }
        selectedTabID = tabs[newIndex].id
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let isScratch = tabs[index].fileURL == nil
        let syncVersions = versionSyncPolicy(tabs[index])
        tabs.remove(at: index)

        if isScratch && SettingsStore.shared.icloudSync {
            CloudSyncEngine.shared.recordDeleted(id)
        }
        cancelVersionTimers(id: id)
        versionTracking.removeValue(forKey: id)
        pendingExternalCursor.removeValue(forKey: id)
        versionStore.deleteAll(tabID: id, syncable: syncVersions)

        if selectedTabID == id {
            if tabs.isEmpty {
                addNewTab()
            } else {
                let newIndex = min(index, tabs.count - 1)
                selectedTabID = tabs[newIndex].id
            }
        }
        scheduleSave()
    }

    func updateContent(id: UUID, content: String) {
        guard applyContent(id: id, content: content) else { return }
        recordEdit(id: id, content: content)
    }

    /// Content set by something other than typing (version restore, auto-paste
    /// without a live text view). Does not snapshot: the caller has already
    /// recorded whatever version it needs. The cursor is picked up once by
    /// EditorView via takePendingExternalCursor; pass nil when a live text
    /// view already holds the new text and caret.
    func setContentExternally(id: UUID, content: String, cursor: Int?) {
        cancelIdleTimer(id: id)
        if let cursor {
            pendingExternalCursor[id] = min(max(cursor, 0), content.utf16.count)
        }
        applyContent(id: id, content: content)
    }

    func takePendingExternalCursor(for id: UUID) -> Int? {
        pendingExternalCursor.removeValue(forKey: id)
    }

    @discardableResult
    private func applyContent(id: UUID, content: String) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        guard tabs[index].content != content else { return false }

        var tab = tabs[index]
        tab.content = content
        tab.isDirty = true
        tab.lastModified = Date()

        // Auto-name from first line when no file
        if tab.fileURL == nil {
            let firstLine = content.prefix(while: { $0 != "\n" && $0 != "\r" })
            let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let newName = trimmed.isEmpty
                ? String(localized: "tab.untitled", defaultValue: "Untitled")
                : String(trimmed.prefix(30))
            tab.name = newName
        }

        tabs[index] = tab

        if !tab.languageLocked {
            scheduleLanguageDetection(id: tab.id, content: content, name: tab.name, fileURL: tab.fileURL)
        }

        if tab.fileURL == nil {
            CloudSyncEngine.shared.recordChanged(id)
        }

        scheduleSave()
        return true
    }

    // MARK: - Version history

    /// Single entry point for snapshot decisions. Never writes per keystroke:
    /// a version is appended after `idleInterval` without edits, or at once
    /// when the UTF-16 length moved by ≥ 10 % (and ≥ 20 chars) or ≥ 200 chars
    /// against the latest version. `hold` parks the snapshot in memory until
    /// commitHeldSnapshot/discardHeldSnapshot, the next real edit, or
    /// `holdInterval` elapses.
    func recordEdit(id: UUID, content: String, source: TabVersion.Source = .edit, hold: Bool = false) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        guard historySettings().enabled else { return }
        if !hold {
            commitHeldSnapshot(id: id)
        }
        let latest = latestText(for: id)
        guard content != latest else {
            cancelIdleTimer(id: id)
            return
        }

        if hold {
            cancelIdleTimer(id: id)
            var tracking = versionTracking[id, default: VersionTracking()]
            tracking.holdWork?.cancel()
            tracking.heldSnapshot = makeVersion(id: id, text: content, source: source)
            let work = DispatchWorkItem { [weak self] in self?.commitHeldSnapshot(id: id) }
            tracking.holdWork = work
            versionTracking[id] = tracking
            DispatchQueue.main.asyncAfter(deadline: .now() + holdInterval, execute: work)
            return
        }

        let latestLength = latest.utf16.count
        let delta = abs(content.utf16.count - latestLength)
        let bigRelativeChange = latestLength > 0 && delta >= 20 && delta * 10 >= latestLength
        if delta >= 200 || bigRelativeChange {
            cancelIdleTimer(id: id)
            writeVersion(id: id, text: content, source: source)
            return
        }

        cancelIdleTimer(id: id)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.versionTracking[id]?.idleWork = nil
            self.snapshotIfChanged(id: id, source: source)
        }
        versionTracking[id, default: VersionTracking()].idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleInterval, execute: work)
    }

    func commitHeldSnapshot(id: UUID) {
        guard var tracking = versionTracking[id], let held = tracking.heldSnapshot else { return }
        tracking.holdWork?.cancel()
        tracking.holdWork = nil
        tracking.heldSnapshot = nil
        tracking.latestText = held.text
        versionTracking[id] = tracking
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if versionStore.append(held, syncable: versionSyncPolicy(tab)) {
            pruneVersions(id: id, syncable: versionSyncPolicy(tab))
        }
    }

    func discardHeldSnapshot(id: UUID) {
        guard var tracking = versionTracking[id] else { return }
        tracking.holdWork?.cancel()
        tracking.holdWork = nil
        tracking.heldSnapshot = nil
        tracking.idleWork?.cancel()
        tracking.idleWork = nil
        tracking.latestText = tabs.first { $0.id == id }?.content
        versionTracking[id] = tracking
    }

    /// Snapshots every tab whose text differs from its latest version and
    /// commits held snapshots – the undo window closes with the app.
    func flushPendingVersions() {
        for tab in tabs {
            commitHeldSnapshot(id: tab.id)
            snapshotIfChanged(id: tab.id, source: .edit)
        }
    }

    /// Current text becomes a `.restore` version first – history is never
    /// rewritten – then the chosen text goes live without a second snapshot.
    func restoreVersion(id: UUID, version: TabVersion) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        commitHeldSnapshot(id: id)
        writeVersion(id: id, text: tab.content, source: .restore)
        setContentExternally(id: id, content: version.text, cursor: version.text.utf16.count)
    }

    func setVersionLabel(_ label: String?, versionID: String, tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        versionStore.setLabel(label, versionID: versionID, tabID: tabID, syncable: versionSyncPolicy(tab))
    }

    /// Runs the pending idle snapshot for a tab now (tests only – avoids sleeping).
    func fireIdleTimer(id: UUID) {
        guard let work = versionTracking[id]?.idleWork else { return }
        work.cancel()
        versionTracking[id]?.idleWork = nil
        snapshotIfChanged(id: id, source: .edit)
    }

    /// Runs the pending hold auto-commit for a tab now (tests only).
    func fireHoldTimer(id: UUID) {
        guard versionTracking[id]?.holdWork != nil else { return }
        commitHeldSnapshot(id: id)
    }

    /// A tab without versions counts as "" so a blank tab never gets an empty
    /// first version just from being switched away from.
    private func latestText(for id: UUID) -> String {
        if let tracking = versionTracking[id], let text = tracking.latestText {
            return text
        }
        let text = versionStore.latest(for: id)?.text ?? ""
        versionTracking[id, default: VersionTracking()].latestText = text
        return text
    }

    private func snapshotIfChanged(id: UUID, source: TabVersion.Source) {
        cancelIdleTimer(id: id)
        guard historySettings().enabled else { return }
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        guard tab.content != latestText(for: id) else { return }
        writeVersion(id: id, text: tab.content, source: source)
    }

    private func makeVersion(id: UUID, text: String, source: TabVersion.Source) -> TabVersion {
        TabVersion(
            tabID: id,
            parentID: versionStore.latest(for: id)?.id,
            createdAt: now(),
            device: deviceName,
            text: text,
            source: source
        )
    }

    private func writeVersion(id: UUID, text: String, source: TabVersion.Source) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let version = makeVersion(id: id, text: text, source: source)
        versionTracking[id, default: VersionTracking()].latestText = text
        let syncable = versionSyncPolicy(tab)
        if versionStore.append(version, syncable: syncable) {
            pruneVersions(id: id, syncable: syncable)
        }
    }

    private func pruneVersions(id: UUID, syncable: Bool) {
        let config = historySettings()
        versionStore.prune(tabID: id, now: now(), keepCount: config.keepCount, keepDays: config.keepDays, syncable: syncable)
    }

    private func cancelIdleTimer(id: UUID) {
        versionTracking[id]?.idleWork?.cancel()
        versionTracking[id]?.idleWork = nil
    }

    private func cancelVersionTimers(id: UUID) {
        cancelIdleTimer(id: id)
        versionTracking[id]?.holdWork?.cancel()
        versionTracking[id]?.holdWork = nil
    }

    private func scheduleLanguageDetection(id: UUID, content: String, name: String?, fileURL: URL?) {
        languageDetectWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.languageDetectWork.removeValue(forKey: id)
            guard let index = self.tabs.firstIndex(where: { $0.id == id }),
                  !self.tabs[index].languageLocked else { return }
            let result = LanguageDetector.shared.detect(text: content, name: name, fileURL: fileURL)
            let newLang: String?
            if result.confidence > 0 {
                newLang = result.lang
            } else if self.tabs[index].language != "plain" && result.lang == "plain" {
                newLang = "plain"
            } else {
                newLang = nil
            }
            // Persist and sync the detected language – otherwise it is lost
            // on relaunch and never reaches other devices until the next edit
            if let newLang, self.tabs[index].language != newLang {
                self.tabs[index].language = newLang
                self.scheduleSave()
                if self.tabs[index].fileURL == nil {
                    CloudSyncEngine.shared.recordChanged(id)
                }
            }
        }
        languageDetectWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func updateLanguage(id: UUID, language: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].language = language
        tabs[index].languageLocked = true
        tabs[index].lastModified = Date()
        if tabs[index].fileURL == nil {
            CloudSyncEngine.shared.recordChanged(id)
        }
        scheduleSave()
    }

    /// Kept outside the @Published tabs array – the caret moves on every
    /// keystroke and mutating tabs would re-render all tab UI each time.
    /// Merged into the persisted session by saveSession.
    private var cursorPositions: [UUID: Int] = [:]

    func updateCursorPosition(id: UUID, position: Int) {
        cursorPositions[id] = position
    }

    func cursorPosition(for id: UUID) -> Int {
        cursorPositions[id] ?? tabs.first { $0.id == id }?.cursorPosition ?? 0
    }

    func renameTab(id: UUID, name: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].name = name
        tabs[index].lastModified = Date()
        scheduleSave()
    }

    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              tabs.indices.contains(sourceIndex),
              destinationIndex >= 0, destinationIndex <= tabs.count else { return }
        let tab = tabs.remove(at: sourceIndex)
        let insertAt = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        tabs.insert(tab, at: insertAt)
        scheduleSave()
    }

    // MARK: - File operations

    enum OpenFileError: LocalizedError {
        case notTextFile(String)

        var errorDescription: String? {
            switch self {
            case .notTextFile(let name):
                return "\"\(name)\" doesn't appear to be a text file and can't be opened in Itsypad."
            }
        }
    }

    func openFile(url: URL) throws {
        // Check if already open
        if let existing = tabs.firstIndex(where: { $0.fileURL == url }) {
            selectedTabID = tabs[existing].id
            return
        }

        let data = try Data(contentsOf: url)
        let name = url.lastPathComponent

        guard let content = String(data: data, encoding: .utf8) else {
            throw OpenFileError.notTextFile(name)
        }

        let lang = LanguageDetector.shared.detectFromExtension(name: name)
            ?? LanguageDetector.shared.detect(text: content, name: name, fileURL: url).lang

        let tab = TabData(
            name: name,
            content: content,
            language: lang,
            fileURL: url,
            // Capture while the picker's access grant is still active –
            // it's the only way to write to this file in later sessions
            fileBookmark: try? url.bookmarkData(),
            languageLocked: true
        )
        tabs.append(tab)
        selectedTabID = tab.id
        scheduleSave()
    }

    /// Resolves the tab's bookmark into a URL we are allowed to write to.
    /// Returns the URL and whether stopAccessingSecurityScopedResource is owed.
    private func writableFileURL(for index: Int) -> (url: URL, scoped: Bool)? {
        guard let fileURL = tabs[index].fileURL else { return nil }

        if let bookmark = tabs[index].fileBookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) {
                let scoped = resolved.startAccessingSecurityScopedResource()
                if stale {
                    tabs[index].fileBookmark = try? resolved.bookmarkData()
                }
                return (resolved, scoped)
            }
        }
        return (fileURL, fileURL.startAccessingSecurityScopedResource())
    }

    func saveFile(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        guard let target = writableFileURL(for: index) else {
            // No file URL – caller should trigger save-as picker
            return
        }
        defer {
            if target.scoped { target.url.stopAccessingSecurityScopedResource() }
        }

        do {
            try tabs[index].content.write(to: target.url, atomically: true, encoding: .utf8)
            tabs[index].isDirty = false
            scheduleSave()
        } catch {
            NSLog("Failed to save file: \(error)")
            fileSaveError = error.localizedDescription
        }
    }

    /// Called after the user picks a destination in the file exporter.
    func completeSaveAs(id: UUID, url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        do {
            try tabs[index].content.write(to: url, atomically: true, encoding: .utf8)
            tabs[index].fileURL = url
            tabs[index].fileBookmark = try? url.bookmarkData()
            tabs[index].name = url.lastPathComponent
            tabs[index].isDirty = false

            if let lang = LanguageDetector.shared.detectFromExtension(name: url.lastPathComponent) {
                tabs[index].language = lang
                tabs[index].languageLocked = true
            }

            scheduleSave()
        } catch {
            NSLog("Failed to save file: \(error)")
            fileSaveError = error.localizedDescription
        }
    }

    /// Whether the current tab has no fileURL (needs save-as picker instead of direct save).
    var selectedTabNeedsSaveAs: Bool {
        guard let tab = selectedTab else { return true }
        return tab.fileURL == nil
    }

    // MARK: - Cloud sync

    func applyCloudTab(_ data: CloudTabRecord) {
        var changed = false

        if let localIndex = tabs.firstIndex(where: { $0.id == data.id }) {
            // Only accept cloud version if it's newer than local
            guard data.lastModified > tabs[localIndex].lastModified else { return }
            if tabs[localIndex].content != data.content
                || tabs[localIndex].name != data.name
                || tabs[localIndex].language != data.language {
                // Snapshot before overwrite: the local text must survive as a
                // version before remote content replaces it
                if tabs[localIndex].content != data.content {
                    commitHeldSnapshot(id: data.id)
                    cancelIdleTimer(id: data.id)
                    writeVersion(id: data.id, text: tabs[localIndex].content, source: .conflict)
                }
                tabs[localIndex].content = data.content
                tabs[localIndex].name = data.name
                tabs[localIndex].language = data.language
                tabs[localIndex].languageLocked = data.languageLocked
                tabs[localIndex].lastModified = data.lastModified
                changed = true
            }
        } else {
            let tab = TabData(
                id: data.id,
                name: data.name,
                content: data.content,
                language: data.language,
                languageLocked: data.languageLocked,
                isDirty: !data.content.isEmpty,
                lastModified: data.lastModified
            )
            tabs.append(tab)
            changed = true
        }

        lastICloudSync = Date()
        if changed {
            scheduleSave()
        }
    }

    func removeCloudTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)

        if selectedTabID == id {
            if tabs.isEmpty {
                addNewTab()
            } else {
                let newIndex = min(index, tabs.count - 1)
                selectedTabID = tabs[newIndex].id
            }
        } else if tabs.isEmpty {
            addNewTab()
        }

        lastICloudSync = Date()
        scheduleSave()
    }

    // MARK: - Session persistence

    func scheduleSave() {
        saveDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveSession()
        }
        saveDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func saveSession() {
        do {
            var snapshot = tabs
            for index in snapshot.indices {
                if let position = cursorPositions[snapshot[index].id] {
                    snapshot[index].cursorPosition = position
                }
            }
            let session = SessionData(tabs: snapshot, selectedTabID: selectedTabID)
            let data = try JSONEncoder().encode(session)
            try data.write(to: sessionURL, options: .atomic)
        } catch {
            NSLog("Failed to save session: \(error)")
        }
    }

    private func restoreSession() {
        guard let data = try? Data(contentsOf: sessionURL) else { return }

        guard let session = try? JSONDecoder().decode(SessionData.self, from: data) else {
            // The file exists but can't be decoded. Keep a copy before the
            // next debounced save overwrites it with an empty session –
            // without this, one bad read permanently destroys every tab.
            let backupURL = sessionURL.appendingPathExtension("bak")
            try? data.write(to: backupURL, options: .atomic)
            NSLog("[TabStore] restoreSession: decode failed, backed up to \(backupURL.lastPathComponent)")
            return
        }

        tabs = session.tabs
        selectedTabID = session.selectedTabID ?? tabs.first?.id

        for index in tabs.indices where !tabs[index].languageLocked {
            let tab = tabs[index]
            let result = LanguageDetector.shared.detect(
                text: tab.content,
                name: tab.name,
                fileURL: tab.fileURL
            )
            if result.confidence > 0 {
                tabs[index].language = result.lang
            } else if result.lang == "plain" && tab.language != "plain" {
                tabs[index].language = "plain"
            }
        }
    }
}

struct SessionData: Codable {
    let tabs: [TabData]
    let selectedTabID: UUID?
}
