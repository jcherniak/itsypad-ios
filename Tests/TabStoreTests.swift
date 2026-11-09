import XCTest
@testable import ItsypadCore

final class TabStoreTests: XCTestCase {
    private var store: TabStore!
    private var tempURL: URL!
    private var versionsURL: URL!
    private var hookLog: VersionHookLog!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        versionsURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        hookLog = VersionHookLog()
        store = TabStore(sessionURL: tempURL)
        configureVersioning(store)
    }

    private func configureVersioning(_ store: TabStore) {
        let versionStore = VersionStore(baseURL: versionsURL)
        versionStore.cloudHooks = hookLog.hooks
        store.versionStore = versionStore
        store.now = { [unowned self] in self.clock }
        store.deviceName = "Test phone"
        store.versionSyncPolicy = { $0.fileURL == nil }
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

    func testApplyCloudTabUpdatesExistingNewerTab() {
        let existingID = store.tabs.first!.id
        let record = CloudTabRecord(
            id: existingID,
            name: "Updated",
            content: "updated content",
            language: "swift",
            languageLocked: true,
            lastModified: Date().addingTimeInterval(100)
        )
        store.applyCloudTab(record)

        XCTAssertEqual(store.tabs.first?.content, "updated content")
        XCTAssertEqual(store.tabs.first?.name, "Updated")
        XCTAssertEqual(store.tabs.first?.language, "swift")
    }

    func testApplyCloudTabIgnoresOlderVersion() {
        let existingID = store.tabs.first!.id
        store.updateContent(id: existingID, content: "local content")

        let record = CloudTabRecord(
            id: existingID,
            name: "Old cloud",
            content: "old cloud content",
            language: "plain",
            languageLocked: false,
            lastModified: Date.distantPast
        )
        store.applyCloudTab(record)

        XCTAssertEqual(store.tabs.first?.content, "local content")
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

    func testApplyCloudTabSnapshotsLocalTextAsConflictBeforeOverwrite() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "local text")

        let record = CloudTabRecord(
            id: tabID,
            name: "Remote",
            content: "remote text",
            language: "plain",
            languageLocked: false,
            lastModified: Date().addingTimeInterval(100)
        )
        store.applyCloudTab(record)

        XCTAssertEqual(store.tabs.first?.content, "remote text")
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?.source, .conflict)
        XCTAssertEqual(versions.first?.text, "local text")
        XCTAssertNil(versions.first?.label)

        // The pending idle timer must not resurrect the overwritten text
        store.fireIdleTimer(id: tabID)
        XCTAssertEqual(versions.count, 1)
    }

    func testApplyCloudTabIgnoredWhenOlderWritesNoVersion() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "local text")
        let record = CloudTabRecord(
            id: tabID, name: "Old", content: "old", language: "plain", languageLocked: false, lastModified: .distantPast
        )
        store.applyCloudTab(record)
        XCTAssertTrue(versions.isEmpty)
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

    func testCloseTabDeletesVersionsAndQueuesCloudDeletes() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "one")
        store.fireIdleTimer(id: tabID)
        clock.addTimeInterval(1)
        store.updateContent(id: tabID, content: "one two")
        store.fireIdleTimer(id: tabID)
        let ids = Set(store.versionStore.versions(for: tabID).map(\.id))
        XCTAssertEqual(ids.count, 2)

        store.closeTab(id: tabID)
        XCTAssertTrue(store.versionStore.versions(for: tabID).isEmpty)
        XCTAssertEqual(Set(hookLog.deleted), ids)
    }

    func testCloseFileBackedTabDeletesVersionsLocallyOnly() {
        let tabID = store.tabs.first!.id
        store.tabs[0].fileURL = URL(fileURLWithPath: "/tmp/notes.txt")
        store.updateContent(id: tabID, content: "file text")
        store.fireIdleTimer(id: tabID)
        XCTAssertEqual(store.versionStore.versions(for: tabID).count, 1)
        XCTAssertTrue(hookLog.changed.isEmpty)

        store.closeTab(id: tabID)
        XCTAssertTrue(store.versionStore.versions(for: tabID).isEmpty)
        XCTAssertTrue(hookLog.deleted.isEmpty)
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
}
