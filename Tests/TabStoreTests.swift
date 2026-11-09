import XCTest
@testable import ItsypadCore

final class TabCloudLog {
    var changed: [UUID] = []
    var deleted: [UUID] = []

    var hooks: TabStore.CloudHooks {
        TabStore.CloudHooks(
            recordChanged: { [unowned self] in self.changed.append($0) },
            recordDeleted: { [unowned self] in self.deleted.append($0) }
        )
    }
}

final class TabStoreTests: XCTestCase {
    private var store: TabStore!
    private var tempURL: URL!
    private var versionsURL: URL!
    private var hookLog: VersionHookLog!
    private var cloudLog: TabCloudLog!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        versionsURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        hookLog = VersionHookLog()
        cloudLog = TabCloudLog()
        store = TabStore(sessionURL: tempURL)
        configureVersioning(store)
    }

    private func configureVersioning(_ store: TabStore) {
        let versionStore = VersionStore(baseURL: versionsURL)
        versionStore.cloudHooks = hookLog.hooks
        store.versionStore = versionStore
        store.cloudHooks = cloudLog.hooks
        store.now = { [unowned self] in self.clock }
        store.deviceName = "Test phone"
        store.versionSyncPolicy = { $0.fileURL == nil }
        store.historySettings = { (true, 200, 90) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: versionsURL)
        store = nil
        super.tearDown()
    }

    // MARK: - Init

    func testFirstLaunchCreatesWelcomeTab() {
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs.first?.name, "Welcome to Itsypad for iOS")
        XCTAssertEqual(store.tabs.first?.language, "markdown")
        XCTAssertFalse(store.tabs.first!.content.isEmpty)
        XCTAssertNotNil(store.selectedTabID)
    }

    func testExistingSessionRestoresBlankTab() {
        // Save an empty session to simulate "not first launch"
        let session = SessionData(tabs: [], selectedTabID: nil)
        let data = try! JSONEncoder().encode(session)
        try! data.write(to: tempURL)

        let restored = TabStore(sessionURL: tempURL)
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.tabs.first?.name, "Untitled")
        XCTAssertEqual(restored.tabs.first?.language, "plain")
    }

    // MARK: - Corrupt session backup

    func testCorruptSessionFileIsBackedUpBeforeOverwrite() {
        let garbage = Data("not json at all {{{".utf8)
        try! garbage.write(to: tempURL)

        let restored = TabStore(sessionURL: tempURL)
        let backupURL = tempURL.appendingPathExtension("bak")
        defer { try? FileManager.default.removeItem(at: backupURL) }

        XCTAssertEqual(try? Data(contentsOf: backupURL), garbage)
        // Store still recovers with a fresh tab
        XCTAssertEqual(restored.tabs.count, 1)
    }

    // MARK: - addNewTab

    func testAddNewTab() {
        let initialCount = store.tabs.count
        store.addNewTab()
        XCTAssertEqual(store.tabs.count, initialCount + 1)
        XCTAssertEqual(store.selectedTabID, store.tabs.last?.id)
    }

    func testAddNewTabSelectsIt() {
        store.addNewTab()
        let newTab = store.tabs.last!
        XCTAssertEqual(store.selectedTabID, newTab.id)
    }

    // MARK: - selectNeighborTab

    func testSelectNeighborTabNext() {
        store.addNewTab()
        store.addNewTab()
        store.selectedTabID = store.tabs[0].id

        store.selectNeighborTab(delta: 1)
        XCTAssertEqual(store.selectedTabID, store.tabs[1].id)
    }

    func testSelectNeighborTabPrevious() {
        store.addNewTab()
        store.selectedTabID = store.tabs[1].id

        store.selectNeighborTab(delta: -1)
        XCTAssertEqual(store.selectedTabID, store.tabs[0].id)
    }

    func testSelectNeighborTabStopsAtFirst() {
        store.addNewTab()
        store.selectedTabID = store.tabs[0].id

        store.selectNeighborTab(delta: -1)
        XCTAssertEqual(store.selectedTabID, store.tabs[0].id)
    }

    func testSelectNeighborTabStopsAtLast() {
        store.addNewTab()
        store.selectedTabID = store.tabs.last!.id

        store.selectNeighborTab(delta: 1)
        XCTAssertEqual(store.selectedTabID, store.tabs.last!.id)
    }

    // MARK: - removeCloudTab

    func testRemoveCloudTabReassignsSelectionWhenSelectedTabDeleted() {
        store.addNewTab()
        store.addNewTab()
        let deleted = store.tabs[1]
        store.selectedTabID = deleted.id

        store.removeCloudTab(id: deleted.id)

        XCTAssertFalse(store.tabs.contains { $0.id == deleted.id })
        XCTAssertNotNil(store.selectedTabID)
        XCTAssertTrue(store.tabs.contains { $0.id == store.selectedTabID })
    }

    func testRemoveCloudTabKeepsSelectionWhenOtherTabDeleted() {
        store.addNewTab()
        let selected = store.tabs[0]
        let deleted = store.tabs[1]
        store.selectedTabID = selected.id

        store.removeCloudTab(id: deleted.id)

        XCTAssertEqual(store.selectedTabID, selected.id)
    }

    func testRemoveCloudTabLastTabCreatesNewTab() {
        let only = store.tabs[0]
        store.selectedTabID = only.id

        store.removeCloudTab(id: only.id)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertNotEqual(store.tabs[0].id, only.id)
        XCTAssertEqual(store.selectedTabID, store.tabs[0].id)
    }

    // MARK: - closeTab

    func testCloseTabRemovesIt() {
        store.addNewTab()
        let tabToClose = store.tabs.first!
        store.closeTab(id: tabToClose.id)
        XCTAssertFalse(store.tabs.contains(where: { $0.id == tabToClose.id }))
    }

    func testCloseLastTabCreatesNew() {
        let onlyTab = store.tabs.first!
        store.closeTab(id: onlyTab.id)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertNotEqual(store.tabs.first?.id, onlyTab.id)
    }

    func testCloseSelectedTabSelectsNeighbor() {
        store.addNewTab()
        store.addNewTab()
        let middleTab = store.tabs[1]
        store.selectedTabID = middleTab.id
        store.closeTab(id: middleTab.id)
        XCTAssertNotNil(store.selectedTabID)
        XCTAssertNotEqual(store.selectedTabID, middleTab.id)
    }

    func testCloseNonSelectedTabKeepsSelection() {
        store.addNewTab()
        let firstTab = store.tabs[0]
        let secondTab = store.tabs[1]
        store.selectedTabID = secondTab.id
        store.closeTab(id: firstTab.id)
        XCTAssertEqual(store.selectedTabID, secondTab.id)
    }

    // MARK: - updateContent

    func testUpdateContentAutoNames() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "hello world")
        XCTAssertEqual(store.tabs.first?.name, "hello world")
    }

    func testUpdateContentTruncatesLongName() {
        let tabID = store.tabs.first!.id
        let longLine = String(repeating: "a", count: 50)
        store.updateContent(id: tabID, content: longLine)
        XCTAssertEqual(store.tabs.first?.name.count, 30)
    }

    func testUpdateContentSetsDirty() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "changed")
        XCTAssertTrue(store.tabs.first!.isDirty)
    }

    func testUpdateContentEmptyLineUsesUntitled() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "   \nsomething")
        XCTAssertEqual(store.tabs.first?.name, "Untitled")
    }

    func testUpdateContentWithLockedLanguageDoesNotChangeLanguage() {
        let tabID = store.tabs.first!.id
        store.updateLanguage(id: tabID, language: "python")
        XCTAssertTrue(store.tabs.first!.languageLocked)
        store.updateContent(id: tabID, content: "import SwiftUI\nstruct Foo: View {}")
        XCTAssertEqual(store.tabs.first?.language, "python")
    }

    func testUpdateContentWithFileURLDoesNotAutoName() {
        let tabID = store.tabs.first!.id
        store.tabs[0].fileURL = URL(fileURLWithPath: "/tmp/test.swift")
        store.tabs[0].name = "test.swift"
        store.updateContent(id: tabID, content: "new content")
        XCTAssertEqual(store.tabs.first?.name, "test.swift")
    }

    func testUpdateContentSameContentNoOp() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "hello")
        store.tabs[0].isDirty = false
        store.updateContent(id: tabID, content: "hello")
        XCTAssertFalse(store.tabs.first!.isDirty)
    }

    // MARK: - updateLanguage

    func testUpdateLanguageLocksLanguage() {
        let tabID = store.tabs.first!.id
        store.updateLanguage(id: tabID, language: "rust")
        XCTAssertEqual(store.tabs.first?.language, "rust")
        XCTAssertTrue(store.tabs.first!.languageLocked)
    }

    // MARK: - renameTab

    func testRenameTab() {
        let tabID = store.tabs.first!.id
        store.renameTab(id: tabID, name: "My notes")
        XCTAssertEqual(store.tabs.first?.name, "My notes")
    }

    // MARK: - moveTab

    func testMoveTabForward() {
        store.addNewTab()
        store.addNewTab()
        let first = store.tabs[0]
        store.moveTab(from: 0, to: 2)
        XCTAssertEqual(store.tabs[1].id, first.id)
    }

    func testMoveTabBackward() {
        store.addNewTab()
        store.addNewTab()
        let last = store.tabs[2]
        store.moveTab(from: 2, to: 0)
        XCTAssertEqual(store.tabs[0].id, last.id)
    }

    func testMoveTabSameIndexNoOp() {
        store.addNewTab()
        let tabs = store.tabs
        store.moveTab(from: 0, to: 0)
        XCTAssertEqual(store.tabs.map(\.id), tabs.map(\.id))
    }

    func testMoveTabOutOfBoundsNoOp() {
        let tabs = store.tabs
        store.moveTab(from: 5, to: 0)
        XCTAssertEqual(store.tabs.map(\.id), tabs.map(\.id))
    }

    // MARK: - File operations

    func testOpenFileCreatesTab() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("swift")
        try "import Foundation".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try store.openFile(url: fileURL)

        let tab = store.tabs.last!
        XCTAssertEqual(tab.content, "import Foundation")
        XCTAssertEqual(tab.fileURL, fileURL)
        XCTAssertEqual(tab.language, "swift")
        XCTAssertTrue(tab.languageLocked)
        XCTAssertEqual(tab.name, fileURL.lastPathComponent)
        XCTAssertEqual(store.selectedTabID, tab.id)
    }

    func testOpenFileAlreadyOpenSelectsExisting() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("py")
        try "print('hi')".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try store.openFile(url: fileURL)
        let firstTabID = store.tabs.last!.id
        let tabCount = store.tabs.count

        store.addNewTab()
        try store.openFile(url: fileURL)

        XCTAssertEqual(store.selectedTabID, firstTabID)
        XCTAssertEqual(store.tabs.count, tabCount + 1) // +1 for addNewTab, not for second open
    }

    func testSaveFileWritesToDisk() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let tabID = store.tabs.first!.id
        store.tabs[0].fileURL = fileURL
        store.tabs[0].content = "updated content"
        store.tabs[0].isDirty = true

        store.saveFile(id: tabID)

        let saved = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(saved, "updated content")
        XCTAssertFalse(store.tabs.first!.isDirty)
    }

    func testSaveFileWithoutURLNoOp() {
        let tabID = store.tabs.first!.id
        store.tabs[0].isDirty = true
        store.saveFile(id: tabID)
        XCTAssertTrue(store.tabs.first!.isDirty)
    }

    func testCompleteSaveAsUpdatesTab() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("py")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "print('hello')")

        store.completeSaveAs(id: tabID, url: fileURL)

        let tab = store.tabs.first!
        XCTAssertEqual(tab.fileURL, fileURL)
        XCTAssertEqual(tab.name, fileURL.lastPathComponent)
        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(tab.language, "python")
        XCTAssertTrue(tab.languageLocked)

        let saved = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(saved, "print('hello')")
    }

    func testSelectedTabNeedsSaveAs() {
        XCTAssertTrue(store.selectedTabNeedsSaveAs)
        store.tabs[0].fileURL = URL(fileURLWithPath: "/tmp/test.swift")
        XCTAssertFalse(store.selectedTabNeedsSaveAs)
    }

    // MARK: - Session persistence

    func testSessionPersistenceRoundtrip() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "persisted content")
        store.saveSession()

        let restored = TabStore(sessionURL: tempURL)
        XCTAssertEqual(restored.tabs.first?.content, "persisted content")
        XCTAssertEqual(restored.selectedTabID, tabID)
    }

    // MARK: - TabData Codable

    func testTabDataCodableRoundtrip() throws {
        let tab = TabData(
            name: "Test",
            content: "hello",
            language: "swift",
            fileURL: URL(fileURLWithPath: "/tmp/test.swift"),
            languageLocked: true,
            isDirty: true,
            cursorPosition: 42
        )
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(TabData.self, from: data)
        XCTAssertEqual(tab, decoded)
    }

    func testTabDataDefaultValues() {
        let tab = TabData()
        XCTAssertEqual(tab.name, "Untitled")
        XCTAssertEqual(tab.content, "")
        XCTAssertEqual(tab.language, "plain")
        XCTAssertNil(tab.fileURL)
        XCTAssertFalse(tab.languageLocked)
        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(tab.cursorPosition, 0)
    }

    // MARK: - Cloud sync (applyCloudTab / removeCloudTab)

    func testApplyCloudTabAddsNewTab() {
        let initialCount = store.tabs.count
        let record = CloudTabRecord(
            id: UUID(),
            name: "Cloud note",
            content: "from cloud",
            language: "plain",
            languageLocked: false,
            lastModified: Date()
        )
        store.applyCloudTab(record)

        XCTAssertEqual(store.tabs.count, initialCount + 1)
        XCTAssertTrue(store.tabs.contains(where: { $0.id == record.id }))
        XCTAssertEqual(store.tabs.last?.content, "from cloud")
    }

    func testApplyCloudTabFastForwardsWhenRemoteDescendsFromLocalText() {
        let existingID = store.tabs.first!.id
        let localText = store.tabs.first!.content
        let record = CloudTabRecord(
            id: existingID,
            name: "Updated",
            content: "updated content",
            language: "swift",
            languageLocked: true,
            lastModified: Date().addingTimeInterval(100),
            headVersionID: TabVersion.makeID(tabID: existingID, text: localText)
        )
        store.applyCloudTab(record)

        XCTAssertEqual(store.tabs.first?.content, "updated content")
        XCTAssertEqual(store.tabs.first?.name, "Updated")
        XCTAssertEqual(store.tabs.first?.language, "swift")
        XCTAssertFalse(store.tabs.first!.hasConflict)
    }

    func testApplyCloudTabWithSameContentAppliesNewerMetadataOnly() {
        let existingID = store.tabs.first!.id
        store.updateContent(id: existingID, content: "shared text")
        store.renameTab(id: existingID, name: "Local name")

        let stale = CloudTabRecord(
            id: existingID, name: "Stale", content: "shared text", language: "swift", languageLocked: true,
            lastModified: .distantPast
        )
        store.applyCloudTab(stale)
        XCTAssertEqual(store.tabs.first?.name, "Local name")
        XCTAssertEqual(store.tabs.first?.language, "markdown") // welcome tab

        let newer = CloudTabRecord(
            id: existingID, name: "Remote name", content: "shared text", language: "swift", languageLocked: true,
            lastModified: Date().addingTimeInterval(100)
        )
        store.applyCloudTab(newer)
        XCTAssertEqual(store.tabs.first?.name, "Remote name")
        XCTAssertEqual(store.tabs.first?.language, "swift")
        XCTAssertTrue(versions.isEmpty)
    }

    func testRemoveCloudTabRemovesExisting() {
        store.addNewTab()
        let tabToRemove = store.tabs.first!
        XCTAssertEqual(store.tabs.count, 2)

        store.removeCloudTab(id: tabToRemove.id)

        XCTAssertFalse(store.tabs.contains(where: { $0.id == tabToRemove.id }))
    }

    func testRemoveCloudTabCreatesNewIfEmpty() {
        let onlyTab = store.tabs.first!
        store.removeCloudTab(id: onlyTab.id)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertNotEqual(store.tabs.first?.id, onlyTab.id)
    }

    func testRemoveCloudTabNoOpForUnknownID() {
        let initialCount = store.tabs.count
        store.removeCloudTab(id: UUID())
        XCTAssertEqual(store.tabs.count, initialCount)
    }

    // MARK: - Cross-platform Codable compatibility

    func testDecodesTabDataWithFileURL() throws {
        let json = """
        {
            "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
            "name": "test.swift",
            "content": "import SwiftUI",
            "language": "swift",
            "fileURL": "file:///tmp/test.swift",
            "languageLocked": true,
            "isDirty": true,
            "cursorPosition": 5,
            "lastModified": 0
        }
        """
        let data = json.data(using: .utf8)!
        let tab = try JSONDecoder().decode(TabData.self, from: data)
        XCTAssertEqual(tab.name, "test.swift")
        XCTAssertEqual(tab.content, "import SwiftUI")
        XCTAssertEqual(tab.language, "swift")
        XCTAssertEqual(tab.fileURL, URL(string: "file:///tmp/test.swift"))
        XCTAssertTrue(tab.languageLocked)
        XCTAssertTrue(tab.isDirty)
        XCTAssertEqual(tab.cursorPosition, 5)
    }

    func testDecodesTabDataWithoutOptionalFields() throws {
        let json = """
        {
            "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
            "name": "Untitled",
            "content": "",
            "language": "plain",
            "languageLocked": false,
            "cursorPosition": 0
        }
        """
        let data = json.data(using: .utf8)!
        let tab = try JSONDecoder().decode(TabData.self, from: data)
        XCTAssertNil(tab.fileURL)
        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(tab.lastModified, .distantPast)
    }

    // MARK: - hasUnsavedChanges

    func testHasUnsavedChangesFileBackedDirty() {
        var tab = TabData(content: "hello", fileURL: URL(fileURLWithPath: "/tmp/test.swift"), isDirty: true)
        XCTAssertTrue(tab.hasUnsavedChanges)
        tab.isDirty = false
        XCTAssertFalse(tab.hasUnsavedChanges)
    }

    func testHasUnsavedChangesScratchWithContent() {
        let tab = TabData(content: "some text")
        XCTAssertTrue(tab.hasUnsavedChanges)
    }

    func testHasUnsavedChangesScratchEmpty() {
        let tab = TabData(content: "")
        XCTAssertFalse(tab.hasUnsavedChanges)
    }

    func testHasUnsavedChangesScratchWhitespaceOnly() {
        let tab = TabData(content: "   \n\t  ")
        XCTAssertFalse(tab.hasUnsavedChanges)
    }

    // MARK: - Launch behaviour

    private func writeSession(_ tabs: [TabData], selected: UUID?) {
        let data = try! JSONEncoder().encode(SessionData(tabs: tabs, selectedTabID: selected))
        try! data.write(to: tempURL)
    }

    func testNewNoteLaunchAddsTabWhenSelectedTabHasContent() {
        let existing = TabData(name: "Notes", content: "some text")
        writeSession([existing], selected: existing.id)

        let restored = TabStore(sessionURL: tempURL, launchBehavior: .newNote)
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.tabs.first?.id, existing.id)
        XCTAssertNotEqual(restored.selectedTabID, existing.id)
        XCTAssertEqual(restored.selectedTab?.content, "")
    }

    func testNewNoteLaunchReusesBlankSelectedTab() {
        let blank = TabData(content: "  \n ")
        writeSession([blank], selected: blank.id)

        let restored = TabStore(sessionURL: tempURL, launchBehavior: .newNote)
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.selectedTabID, blank.id)
    }

    func testNewNoteLaunchAddsTabWhenSelectedBlankTabHasFile() {
        let file = TabData(name: "a.txt", content: "", fileURL: URL(fileURLWithPath: "/tmp/a.txt"))
        writeSession([file], selected: file.id)

        let restored = TabStore(sessionURL: tempURL, launchBehavior: .newNote)
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertNotEqual(restored.selectedTabID, file.id)
    }

    func testNewNoteLaunchDoesNothingOnFirstLaunch() {
        let fresh = TabStore(
            sessionURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("json"),
            launchBehavior: .newNote
        )
        XCTAssertEqual(fresh.tabs.count, 1)
        XCTAssertEqual(fresh.tabs.first?.name, "Welcome to Itsypad for iOS")
    }

    func testReopenLastLaunchKeepsRestoredSelection() {
        let existing = TabData(name: "Notes", content: "some text")
        writeSession([existing], selected: existing.id)

        let restored = TabStore(sessionURL: tempURL, launchBehavior: .reopenLast)
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.selectedTabID, existing.id)
    }

    // MARK: - Version history

    private var versions: [TabVersion] {
        store.versionStore.versions(for: store.tabs.first!.id)
    }

    func testRapidEditsProduceOneVersionAfterIdle() {
        let tabID = store.tabs.first!.id
        for text in ["a", "ab", "abc", "abcd", "abcde"] {
            store.updateContent(id: tabID, content: text)
        }
        XCTAssertTrue(versions.isEmpty)

        store.fireIdleTimer(id: tabID)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?.text, "abcde")
        XCTAssertEqual(versions.first?.source, .edit)
        XCTAssertEqual(versions.first?.device, "Test phone")
        XCTAssertEqual(versions.first?.createdAt, clock)
        XCTAssertNil(versions.first?.parentID)
        XCTAssertEqual(hookLog.changed, [versions.first!.id])

        // Idle again without edits: nothing new
        store.fireIdleTimer(id: tabID)
        XCTAssertEqual(versions.count, 1)
    }

    func testIdleSnapshotChainsParent() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "first")
        store.fireIdleTimer(id: tabID)
        clock.addTimeInterval(30)
        store.updateContent(id: tabID, content: "first second")
        store.fireIdleTimer(id: tabID)

        XCTAssertEqual(versions.map(\.text), ["first second", "first"])
        XCTAssertEqual(versions.first?.parentID, versions.last?.id)
    }

    func testLargeDeltaSnapshotsImmediately() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "short")
        store.fireIdleTimer(id: tabID)
        XCTAssertEqual(versions.count, 1)

        clock.addTimeInterval(1)
        let pasted = "short\n" + String(repeating: "x", count: 250)
        store.updateContent(id: tabID, content: pasted)
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions.first?.text, pasted)

        // Relative rule: ≥ 10 % (and ≥ 20 chars) of the latest version
        clock.addTimeInterval(1)
        let grown = pasted + String(repeating: "y", count: 40)
        store.updateContent(id: tabID, content: grown)
        XCTAssertEqual(versions.count, 3)

        // A single keystroke never snapshots immediately
        clock.addTimeInterval(1)
        store.updateContent(id: tabID, content: grown + "z")
        XCTAssertEqual(versions.count, 3)
    }

    func testTabSwitchSnapshotsPreviousTab() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "draft before switching")
        XCTAssertTrue(versions.isEmpty)

        store.addNewTab()
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?.text, "draft before switching")

        // Switching back and forth without edits adds nothing
        store.selectedTabID = tabID
        store.selectNeighborTab(delta: 1)
        XCTAssertEqual(versions.count, 1)
    }

    func testFlushPendingVersionsSnapshotsEveryChangedTab() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "unsaved")
        store.flushPendingVersions()
        XCTAssertEqual(versions.map(\.text), ["unsaved"])
    }

    func testHoldThenDiscardWritesNothing() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "base")
        store.fireIdleTimer(id: tabID)

        store.recordEdit(id: tabID, content: "base + pasted", source: .paste, hold: true)
        store.setContentExternally(id: tabID, content: "base + pasted", cursor: 13)
        XCTAssertEqual(versions.count, 1)

        store.discardHeldSnapshot(id: tabID)
        store.fireIdleTimer(id: tabID)
        store.fireHoldTimer(id: tabID)
        store.flushPendingVersions()
        XCTAssertEqual(versions.map(\.text), ["base"])
        XCTAssertFalse(versions.contains { $0.source == .paste })
    }

    func testHoldThenCommitWritesOnePasteVersion() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "base")
        store.fireIdleTimer(id: tabID)
        let baseID = versions.first!.id

        clock.addTimeInterval(1)
        store.recordEdit(id: tabID, content: "base + pasted", source: .paste, hold: true)
        XCTAssertEqual(versions.count, 1)

        store.commitHeldSnapshot(id: tabID)
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions.first?.source, .paste)
        XCTAssertEqual(versions.first?.text, "base + pasted")
        XCTAssertEqual(versions.first?.parentID, baseID)

        store.commitHeldSnapshot(id: tabID)
        store.fireHoldTimer(id: tabID)
        XCTAssertEqual(versions.count, 2)
    }

    func testHoldIsCommittedByNextRealEdit() {
        let tabID = store.tabs.first!.id
        store.recordEdit(id: tabID, content: "pasted", source: .paste, hold: true)
        XCTAssertTrue(versions.isEmpty)

        store.updateContent(id: tabID, content: "pasted plus typing")
        XCTAssertEqual(versions.map(\.source), [.paste])
        XCTAssertEqual(versions.first?.text, "pasted")
    }

    func testHoldTimerAutoCommits() {
        let tabID = store.tabs.first!.id
        store.recordEdit(id: tabID, content: "pasted", source: .paste, hold: true)
        store.fireHoldTimer(id: tabID)
        XCTAssertEqual(versions.map(\.source), [.paste])
    }

    private func remote(
        _ content: String,
        head: String?,
        name: String = "Remote",
        language: String = "plain",
        locked: Bool = false
    ) -> CloudTabRecord {
        CloudTabRecord(
            id: store.tabs.first!.id,
            name: name,
            content: content,
            language: language,
            languageLocked: locked,
            lastModified: Date().addingTimeInterval(100),
            headVersionID: head
        )
    }

    /// Snapshots the given text as the tab's latest version and returns its id.
    private func snapshot(_ text: String) -> String {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: text)
        store.fireIdleTimer(id: tabID)
        clock.addTimeInterval(10)
        return store.versionStore.latest(for: tabID)!.id
    }

    func testSnapshotSetsHeadVersionID() {
        let tabID = store.tabs.first!.id
        XCTAssertNil(store.tabs.first?.headVersionID)
        let id = snapshot("first")
        XCTAssertEqual(store.tabs.first?.headVersionID, id)
        XCTAssertEqual(id, TabVersion.makeID(tabID: tabID, text: "first"))

        store.recordEdit(id: tabID, content: "first pasted", source: .paste, hold: true)
        XCTAssertEqual(store.tabs.first?.headVersionID, id)
        store.commitHeldSnapshot(id: tabID)
        XCTAssertEqual(store.tabs.first?.headVersionID, TabVersion.makeID(tabID: tabID, text: "first pasted"))
    }

    func testApplyCloudTabFastForwardSnapshotsLocalAndStoresRemoteVersion() {
        let tabID = store.tabs.first!.id
        let baseID = snapshot("base")
        store.updateContent(id: tabID, content: "base typed")
        let localID = TabVersion.makeID(tabID: tabID, text: "base typed")

        store.applyCloudTab(remote("base typed and more", head: localID, name: "Remote", language: "swift", locked: true))

        XCTAssertEqual(store.tabs.first?.content, "base typed and more")
        XCTAssertEqual(store.tabs.first?.name, "Remote")
        XCTAssertEqual(store.tabs.first?.language, "swift")
        XCTAssertFalse(store.tabs.first!.hasConflict)
        XCTAssertEqual(versions.map(\.text), ["base typed and more", "base typed", "base"])
        XCTAssertEqual(versions[0].device, "iCloud")
        XCTAssertEqual(versions[0].source, .edit)
        XCTAssertEqual(versions[0].parentID, localID)
        XCTAssertEqual(versions[1].parentID, baseID)
        XCTAssertEqual(store.tabs.first?.headVersionID, versions[0].id)

        // The pending idle timer must not resurrect the overwritten text
        store.fireIdleTimer(id: tabID)
        store.flushPendingVersions()
        XCTAssertEqual(versions.count, 3)
    }

    func testApplyCloudTabMergesNonOverlappingEdits() {
        let tabID = store.tabs.first!.id
        let baseID = snapshot("a\nb\nc\nd")
        store.updateContent(id: tabID, content: "A\nb\nc\nd")

        store.applyCloudTab(remote("a\nb\nc\nD", head: baseID, name: "Remote"))

        XCTAssertEqual(store.tabs.first?.content, "A\nb\nc\nD")
        XCTAssertEqual(store.tabs.first?.name, "Remote")
        XCTAssertFalse(store.tabs.first!.hasConflict)
        XCTAssertEqual(versions.map(\.text), ["A\nb\nc\nD", "A\nb\nc\nd", "a\nb\nc\nd"])
        XCTAssertEqual(versions[0].source, .edit)
        XCTAssertEqual(versions[0].device, "Test phone")
        XCTAssertEqual(versions[0].parentID, versions[1].id)
        XCTAssertEqual(versions[1].source, .conflict)
        XCTAssertEqual(store.tabs.first?.headVersionID, versions[0].id)
    }

    func testApplyCloudTabFindsBaseThroughRemoteParentChain() {
        let tabID = store.tabs.first!.id
        let baseID = snapshot("a\nb\nc\nd")
        // The remote device snapshotted its edit and that version synced first
        let remoteVersion = TabVersion(
            tabID: tabID, parentID: baseID, createdAt: clock, device: "Remote Mac", text: "a\nb\nc\nD", source: .edit
        )
        store.versionStore.applyCloud(remoteVersion)
        store.updateContent(id: tabID, content: "A\nb\nc\nd")

        store.applyCloudTab(remote("a\nb\nc\nD\ne", head: remoteVersion.id))

        XCTAssertEqual(store.tabs.first?.content, "A\nb\nc\nD\ne")
        XCTAssertFalse(store.tabs.first!.hasConflict)
    }

    func testApplyCloudTabKeepsLocalOnOverlappingEdits() {
        let tabID = store.tabs.first!.id
        let baseID = snapshot("a\nb\nc\nd")
        store.updateContent(id: tabID, content: "a\nX\nc\nd")
        store.renameTab(id: tabID, name: "Local name")

        store.applyCloudTab(remote("a\nY\nc\nd", head: baseID, name: "Remote name", language: "swift"))

        XCTAssertEqual(store.tabs.first?.content, "a\nX\nc\nd")
        XCTAssertEqual(store.tabs.first?.name, "Local name")
        XCTAssertEqual(store.tabs.first?.language, "markdown") // welcome tab
        XCTAssertTrue(store.tabs.first!.hasConflict)
        XCTAssertEqual(versions.map(\.text), ["a\nY\nc\nd", "a\nX\nc\nd", "a\nb\nc\nd"])
        XCTAssertEqual(versions[0].source, .conflict)
        XCTAssertEqual(versions[0].device, "iCloud")
        XCTAssertEqual(versions[0].label?.hasPrefix("Conflict – another device "), true)
        XCTAssertEqual(versions[0].parentID, baseID)
        XCTAssertEqual(versions[1].source, .conflict)
        XCTAssertNil(versions[1].label)
        // Head = the remote copy, so the other device fast-forwards to our text
        XCTAssertEqual(store.tabs.first?.headVersionID, versions[0].id)
    }

    func testApplyCloudTabFreshBlankTabAdoptsRemoteText() {
        store.addNewTab()
        let tabID = store.tabs.last!.id
        XCTAssertEqual(store.tabs.last?.content, "")
        let remoteHead = TabVersion.makeID(tabID: tabID, text: "remote text")
        let record = CloudTabRecord(
            id: tabID, name: "Remote", content: "remote text", language: "plain", languageLocked: false,
            lastModified: Date().addingTimeInterval(100), headVersionID: remoteHead
        )

        store.applyCloudTab(record)

        XCTAssertEqual(store.tabs.last?.content, "remote text")
        XCTAssertEqual(store.tabs.last?.name, "Remote")
        XCTAssertFalse(store.tabs.last!.hasConflict)
        let list = store.versionStore.versions(for: tabID)
        XCTAssertEqual(list.map(\.text), ["remote text"])
        XCTAssertNil(list.first?.parentID)
        XCTAssertEqual(list.first?.device, "iCloud")
        XCTAssertEqual(store.tabs.last?.headVersionID, remoteHead)
    }

    func testApplyCloudTabWithoutBaseNeverOverwritesUnsnapshottedLocalText() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "local text")
        XCTAssertTrue(versions.isEmpty)

        store.applyCloudTab(remote("remote text", head: nil))

        XCTAssertEqual(store.tabs.first?.content, "local text")
        XCTAssertTrue(store.tabs.first!.hasConflict)
        XCTAssertEqual(Set(versions.map(\.text)), ["local text", "remote text"])
        XCTAssertEqual(versions.first { $0.text == "remote text" }?.label?.hasPrefix("Conflict –"), true)
        XCTAssertNil(versions.first { $0.text == "local text" }?.label)

        // An older lastModified no longer short-circuits anything
        var old = remote("older remote text", head: nil)
        old.lastModified = .distantPast
        store.applyCloudTab(old)
        XCTAssertEqual(store.tabs.first?.content, "local text")
        XCTAssertEqual(versions.count, 3)
    }

    func testConflictLabelUsesKnownRemoteDevice() {
        let tabID = store.tabs.first!.id
        snapshot("a\nb")
        store.updateContent(id: tabID, content: "a\nX")
        let synced = TabVersion(tabID: tabID, parentID: nil, createdAt: clock, device: "Remote Mac", text: "a\nY", source: .edit)
        store.versionStore.applyCloud(synced)

        store.applyCloudTab(remote("a\nY", head: nil))

        XCTAssertEqual(store.tabs.first?.content, "a\nX")
        let copy = versions.first { $0.id == synced.id }
        XCTAssertEqual(copy?.label?.hasPrefix("Conflict – Remote Mac "), true)
        XCTAssertEqual(copy?.device, "Remote Mac")
    }

    func testResolveConflictAndRestoreClearTheFlag() {
        let tabID = store.tabs.first!.id
        let baseID = snapshot("a\nb")
        store.updateContent(id: tabID, content: "a\nX")
        store.applyCloudTab(remote("a\nY", head: baseID))
        XCTAssertTrue(store.tabs.first!.hasConflict)

        store.resolveConflict(id: tabID)
        XCTAssertFalse(store.tabs.first!.hasConflict)

        store.applyCloudTab(remote("a\nZ", head: baseID))
        XCTAssertTrue(store.tabs.first!.hasConflict)
        let remoteCopy = versions.first { $0.text == "a\nZ" }!
        store.restoreVersion(id: tabID, version: remoteCopy)
        XCTAssertFalse(store.tabs.first!.hasConflict)
        XCTAssertEqual(store.tabs.first?.content, "a\nZ")
        XCTAssertEqual(store.tabs.first?.headVersionID, remoteCopy.id)
    }

    func testOldSessionWithoutConflictFieldsStillDecodes() throws {
        let json = """
        {
            "tabs": [{
                "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
                "name": "Untitled",
                "content": "old",
                "language": "plain",
                "languageLocked": false,
                "cursorPosition": 0
            }],
            "selectedTabID": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
        }
        """
        let session = try JSONDecoder().decode(SessionData.self, from: Data(json.utf8))
        XCTAssertNil(session.trashedTabs)
        let tab = session.tabs[0]
        XCTAssertNil(tab.headVersionID)
        XCTAssertNil(tab.deletedAt)
        XCTAssertNil(tab.deletedOn)
        XCTAssertFalse(tab.hasConflict)

        try Data(json.utf8).write(to: tempURL)
        let restored = TabStore(sessionURL: tempURL)
        XCTAssertEqual(restored.tabs.first?.content, "old")
        XCTAssertTrue(restored.trashedTabs.isEmpty)
    }

    func testSessionRoundTripKeepsHeadAndConflict() {
        let tabID = store.tabs.first!.id
        let baseID = snapshot("a\nb")
        store.updateContent(id: tabID, content: "a\nX")
        store.applyCloudTab(remote("a\nY", head: baseID))
        store.trashedTabs = [TabData(name: "Binned", content: "bin", deletedAt: clock, deletedOn: "Test phone")]
        store.saveSession()

        let restored = TabStore(sessionURL: tempURL)
        XCTAssertEqual(restored.tabs.first?.headVersionID, store.tabs.first?.headVersionID)
        XCTAssertTrue(restored.tabs.first!.hasConflict)
        XCTAssertEqual(restored.trashedTabs.map(\.name), ["Binned"])
        XCTAssertEqual(restored.trashedTabs.first?.deletedAt, clock)
        XCTAssertEqual(restored.trashedTabs.first?.deletedOn, "Test phone")
    }

    func testRestoreVersionAppendsRestoreAndSetsPendingCursor() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "version one")
        store.fireIdleTimer(id: tabID)
        let target = versions.first!
        clock.addTimeInterval(60)
        store.updateContent(id: tabID, content: "version two – unsaved")

        store.restoreVersion(id: tabID, version: target)

        XCTAssertEqual(store.tabs.first?.content, "version one")
        XCTAssertEqual(versions.map(\.text), ["version two – unsaved", "version one"])
        XCTAssertEqual(versions.first?.source, .restore)
        XCTAssertEqual(versions.first?.parentID, target.id)
        XCTAssertEqual(store.takePendingExternalCursor(for: tabID), "version one".utf16.count)
        XCTAssertNil(store.takePendingExternalCursor(for: tabID))

        // The restored text already exists as a version – no new snapshot
        store.fireIdleTimer(id: tabID)
        store.flushPendingVersions()
        XCTAssertEqual(versions.count, 2)
    }

    func testSetContentExternallyClampsCursorAndDoesNotSnapshot() {
        let tabID = store.tabs.first!.id
        store.setContentExternally(id: tabID, content: "abc", cursor: 99)
        XCTAssertEqual(store.tabs.first?.content, "abc")
        XCTAssertEqual(store.tabs.first?.name, "abc")
        XCTAssertEqual(store.takePendingExternalCursor(for: tabID), 3)
        store.fireIdleTimer(id: tabID)
        XCTAssertTrue(versions.isEmpty)
    }

    // MARK: - Trash

    func testCloseScratchTabMovesItToTrashAndKeepsVersions() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "one")
        store.fireIdleTimer(id: tabID)
        clock.addTimeInterval(1)
        store.updateContent(id: tabID, content: "one two")
        store.fireIdleTimer(id: tabID)
        XCTAssertEqual(store.versionStore.versions(for: tabID).count, 2)
        cloudLog.changed.removeAll()

        store.closeTab(id: tabID)
        XCTAssertFalse(store.tabs.contains { $0.id == tabID })
        XCTAssertEqual(store.trashedTabs.map(\.id), [tabID])
        XCTAssertEqual(store.trashedTabs.first?.content, "one two")
        XCTAssertEqual(store.trashedTabs.first?.deletedAt, clock)
        XCTAssertEqual(store.trashedTabs.first?.deletedOn, "Test phone")
        XCTAssertEqual(store.versionStore.versions(for: tabID).count, 2)
        XCTAssertTrue(hookLog.deleted.isEmpty)
        XCTAssertEqual(cloudLog.changed.first, tabID)
        XCTAssertTrue(cloudLog.deleted.isEmpty)
        XCTAssertEqual(store.tabs.count, 1)
    }

    func testCloseScratchTabSnapshotsUnsavedTextFirst() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "typed")

        store.closeTab(id: tabID)
        XCTAssertEqual(store.versionStore.versions(for: tabID).map(\.text), ["typed"])
        XCTAssertEqual(store.trashedTabs.first?.headVersionID, TabVersion.makeID(tabID: tabID, text: "typed"))
    }

    func testCloseFileBackedTabIsNotTrashedAndDeletesVersionsLocallyOnly() {
        let tabID = store.tabs.first!.id
        store.tabs[0].fileURL = URL(fileURLWithPath: "/tmp/notes.txt")
        store.updateContent(id: tabID, content: "file text")
        store.fireIdleTimer(id: tabID)
        XCTAssertEqual(store.versionStore.versions(for: tabID).count, 1)
        XCTAssertTrue(hookLog.changed.isEmpty)
        cloudLog.changed.removeAll()

        store.closeTab(id: tabID)
        XCTAssertTrue(store.trashedTabs.isEmpty)
        XCTAssertTrue(store.versionStore.versions(for: tabID).isEmpty)
        XCTAssertTrue(hookLog.deleted.isEmpty)
        XCTAssertFalse(cloudLog.changed.contains(tabID))
        XCTAssertTrue(cloudLog.deleted.isEmpty)
    }

    func testRestoreFromTrashClearsTombstoneAndSelects() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "keep me")
        store.closeTab(id: tabID)
        cloudLog.changed.removeAll()

        store.restoreFromTrash(id: tabID)
        XCTAssertTrue(store.trashedTabs.isEmpty)
        let tab = store.tabs.first { $0.id == tabID }
        XCTAssertEqual(tab?.content, "keep me")
        XCTAssertNil(tab?.deletedAt)
        XCTAssertNil(tab?.deletedOn)
        XCTAssertEqual(store.selectedTabID, tabID)
        XCTAssertEqual(cloudLog.changed, [tabID])
        XCTAssertEqual(store.versionStore.versions(for: tabID).map(\.text), ["keep me"])
    }

    func testDeletePermanentlyRemovesVersionsAndQueuesCloudDeletes() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "one")
        store.fireIdleTimer(id: tabID)
        clock.addTimeInterval(1)
        store.updateContent(id: tabID, content: "one two")
        store.fireIdleTimer(id: tabID)
        let ids = Set(store.versionStore.versions(for: tabID).map(\.id))
        XCTAssertEqual(ids.count, 2)
        store.closeTab(id: tabID)

        store.deletePermanently(id: tabID)
        XCTAssertTrue(store.trashedTabs.isEmpty)
        XCTAssertTrue(store.versionStore.versions(for: tabID).isEmpty)
        XCTAssertEqual(Set(hookLog.deleted), ids)
        XCTAssertEqual(cloudLog.deleted, [tabID])
    }

    func testDeletePermanentlyOnLiveTabReselectsNeighbor() {
        let first = store.tabs.first!.id
        store.addNewTab()
        let second = store.tabs[1].id
        store.selectedTabID = first

        store.deletePermanently(id: first)
        XCTAssertEqual(store.tabs.map(\.id), [second])
        XCTAssertEqual(store.selectedTabID, second)
        XCTAssertEqual(cloudLog.deleted, [first])
    }

    func testEmptyTrashDeletesEveryTrashedTab() {
        let a = store.tabs.first!.id
        store.updateContent(id: a, content: "a")
        store.fireIdleTimer(id: a)
        store.closeTab(id: a)
        let b = store.tabs.first!.id
        store.updateContent(id: b, content: "b")
        store.fireIdleTimer(id: b)
        store.closeTab(id: b)
        XCTAssertEqual(store.trashedTabs.count, 2)

        store.emptyTrash()
        XCTAssertTrue(store.trashedTabs.isEmpty)
        XCTAssertTrue(store.versionStore.versions(for: a).isEmpty)
        XCTAssertTrue(store.versionStore.versions(for: b).isEmpty)
        XCTAssertEqual(Set(cloudLog.deleted), [a, b])
        XCTAssertEqual(hookLog.deleted.count, 2)
    }

    func testAutoEmptyTrashRespectsDaysAndZeroIsNever() {
        let old = store.tabs.first!.id
        store.closeTab(id: old)
        clock.addTimeInterval(40 * 86_400)
        let recent = store.tabs.first!.id
        store.closeTab(id: recent)
        clock.addTimeInterval(86_400)

        store.autoEmptyTrash(days: 0)
        XCTAssertEqual(store.trashedTabs.count, 2)

        store.autoEmptyTrash(days: 30)
        XCTAssertEqual(store.trashedTabs.map(\.id), [recent])
        XCTAssertEqual(cloudLog.deleted, [old])
    }

    func testApplyCloudTombstoneTrashesLiveTabAndSnapshotsEdits() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "local edit")
        var record = remote("remote text", head: nil)
        record.deletedAt = clock.addingTimeInterval(-5)
        record.deletedOn = "Mac"

        store.applyCloudTab(record)
        XCTAssertFalse(store.tabs.contains { $0.id == tabID })
        XCTAssertEqual(store.trashedTabs.map(\.id), [tabID])
        XCTAssertEqual(store.trashedTabs.first?.content, "local edit")
        XCTAssertEqual(store.trashedTabs.first?.deletedAt, record.deletedAt)
        XCTAssertEqual(store.trashedTabs.first?.deletedOn, "Mac")
        XCTAssertTrue(store.versionStore.versions(for: tabID).contains { $0.text == "local edit" })
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertNotEqual(store.selectedTabID, tabID)
    }

    func testApplyCloudTombstoneForUnknownTabAddsItToTrash() {
        let record = CloudTabRecord(
            id: UUID(),
            name: "Gone",
            content: "bye",
            language: "plain",
            languageLocked: false,
            lastModified: clock,
            headVersionID: nil,
            deletedAt: clock,
            deletedOn: "Mac"
        )
        store.applyCloudTab(record)
        XCTAssertEqual(store.trashedTabs.map(\.name), ["Gone"])
        XCTAssertEqual(store.trashedTabs.first?.deletedOn, "Mac")
        XCTAssertEqual(store.tabs.count, 1)
    }

    func testApplyCloudLiveRecordRestoresTrashedTab() {
        let tabID = store.tabs.first!.id
        let head = snapshot("shared")
        store.closeTab(id: tabID)
        XCTAssertEqual(store.trashedTabs.count, 1)

        let record = CloudTabRecord(
            id: tabID,
            name: "Back",
            content: "shared",
            language: "plain",
            languageLocked: false,
            lastModified: Date().addingTimeInterval(100),
            headVersionID: head
        )
        store.applyCloudTab(record)
        XCTAssertTrue(store.trashedTabs.isEmpty)
        let tab = store.tabs.first { $0.id == tabID }
        XCTAssertNil(tab?.deletedAt)
        XCTAssertNil(tab?.deletedOn)
        XCTAssertEqual(tab?.name, "Back")
        XCTAssertEqual(tab?.content, "shared")
    }

    func testRemoveCloudTabHardDeletesTrashedTabAndItsVersions() {
        let tabID = store.tabs.first!.id
        snapshot("doomed")
        store.closeTab(id: tabID)
        hookLog.deleted.removeAll()

        store.removeCloudTab(id: tabID)
        XCTAssertTrue(store.trashedTabs.isEmpty)
        XCTAssertTrue(store.versionStore.versions(for: tabID).isEmpty)
        XCTAssertTrue(hookLog.deleted.isEmpty)
        XCTAssertTrue(cloudLog.deleted.isEmpty)
    }

    func testRemoveCloudTabHardDeletesLiveTabVersions() {
        let tabID = store.tabs.first!.id
        snapshot("live")

        store.removeCloudTab(id: tabID)
        XCTAssertFalse(store.tabs.contains { $0.id == tabID })
        XCTAssertTrue(store.versionStore.versions(for: tabID).isEmpty)
        XCTAssertEqual(store.tabs.count, 1)
    }

    func testSessionRoundTripAfterTrashing() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "binned")
        store.closeTab(id: tabID)
        store.saveSession()

        let restored = TabStore(sessionURL: tempURL)
        XCTAssertEqual(restored.trashedTabs.map(\.id), [tabID])
        XCTAssertEqual(restored.trashedTabs.first?.content, "binned")
        XCTAssertEqual(restored.trashedTabs.first?.deletedAt, clock)
        XCTAssertEqual(restored.trashedTabs.first?.deletedOn, "Test phone")
        XCTAssertFalse(restored.tabs.contains { $0.id == tabID })
    }

    func testDeleteVersionRepointsChildAndHead() {
        let tabID = store.tabs.first!.id
        let a = snapshot("a")
        let b = snapshot("a\nb")
        let c = snapshot("a\nb\nc")
        XCTAssertEqual(store.tabs.first?.headVersionID, c)
        hookLog.deleted.removeAll()
        cloudLog.changed.removeAll()

        store.deleteVersion(id: b, tabID: tabID)
        let remaining = store.versionStore.versions(for: tabID)
        XCTAssertEqual(remaining.map(\.id), [c, a])
        XCTAssertEqual(remaining.first?.parentID, a)
        XCTAssertEqual(hookLog.deleted, [b])
        XCTAssertEqual(store.tabs.first?.headVersionID, c)
        XCTAssertTrue(cloudLog.changed.isEmpty)

        store.deleteVersion(id: c, tabID: tabID)
        XCTAssertEqual(store.tabs.first?.headVersionID, a)
        XCTAssertEqual(cloudLog.changed, [tabID])
    }

    func testSetVersionLabelGoesThroughStore() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "named")
        store.fireIdleTimer(id: tabID)
        let id = versions.first!.id
        hookLog.changed.removeAll()

        store.setVersionLabel("Milestone", versionID: id, tabID: tabID)
        XCTAssertEqual(versions.first?.label, "Milestone")
        XCTAssertEqual(hookLog.changed, [id])
    }

    func testRecordEditIsNoOpWhenHistoryDisabled() {
        let tabID = store.tabs.first!.id
        store.historySettings = { (false, 200, 90) }
        store.updateContent(id: tabID, content: String(repeating: "x", count: 500))
        store.fireIdleTimer(id: tabID)
        store.flushPendingVersions()
        XCTAssertTrue(versions.isEmpty)

        store.historySettings = { (true, 200, 90) }
        store.updateContent(id: tabID, content: String(repeating: "y", count: 500))
        store.fireIdleTimer(id: tabID)
        XCTAssertEqual(versions.count, 1)
    }

    func testHistoryKeepCountIsAppliedOnAppend() {
        let tabID = store.tabs.first!.id
        store.historySettings = { (true, 3, 0) }
        for i in 0..<6 {
            clock = clock.addingTimeInterval(1)
            store.updateContent(id: tabID, content: "text \(i)")
            store.fireIdleTimer(id: tabID)
        }
        XCTAssertEqual(versions.count, 3)
        XCTAssertEqual(versions.first?.text, "text 5")
    }
}
