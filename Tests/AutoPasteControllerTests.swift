import XCTest
@testable import ItsypadCore

private final class FakePasteboard: PasteboardReading {
    var string: String?
    var changeCount = 1
    var hasStrings: Bool { string != nil }
}

final class AutoPasteControllerTests: XCTestCase {
    private var store: TabStore!
    private var settings: SettingsStore!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var pasteboard: FakePasteboard!
    private var controller: AutoPasteController!
    private var tempURL: URL!
    private var versionsURL: URL!
    private var hookLog: VersionHookLog!
    private var tabID: UUID!
    private var textView: EditorTextView?
    private var coordinator: EditorCoordinator?
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        versionsURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suiteName = "AutoPasteControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!

        store = TabStore(sessionURL: tempURL, launchBehavior: .reopenLast)
        let versionStore = VersionStore(baseURL: versionsURL)
        hookLog = VersionHookLog()
        versionStore.cloudHooks = hookLog.hooks
        store.versionStore = versionStore
        store.deviceName = "Test phone"
        store.versionSyncPolicy = { _ in false }

        tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "hello world")
        store.fireIdleTimer(id: tabID)
        store.updateCursorPosition(id: tabID, position: 5)

        settings = SettingsStore(defaults: defaults)
        settings.autoPasteOnOpen = true
        pasteboard = FakePasteboard()
        pasteboard.string = " big"
        controller = makeController()
    }

    override func tearDown() {
        textView?.delegate = nil
        textView?.removeFromSuperview()
        textView = nil
        coordinator = nil
        window = nil
        controller = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: versionsURL)
        store = nil
        super.tearDown()
    }

    private func makeController() -> AutoPasteController {
        AutoPasteController(
            pasteboard: pasteboard,
            tabStore: store,
            settings: settings,
            defaults: defaults,
            textViewProvider: { [weak self] id in id == self?.tabID ? self?.textView : nil }
        )
    }

    private var content: String {
        store.tabs.first { $0.id == tabID }!.content
    }

    private var versions: [TabVersion] {
        store.versionStore.versions(for: tabID)
    }

    private func pumpRunLoop(seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Mirrors EditorView's wiring: text changes reach the store asynchronously.
    private func attachTextView() -> EditorTextView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let tv = EditorTextView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), textContainer: textContainer)
        tv.ownedTextStorage = textStorage
        let coordinator = EditorCoordinator()
        tv.font = coordinator.font
        tv.delegate = coordinator
        coordinator.textView = tv
        coordinator.language = "plain"
        tv.text = content
        tv.selectedRange = NSRange(location: 5, length: 0)
        let id: UUID = tabID
        tv.onTextChange = { [weak store, weak coordinator] text in
            DispatchQueue.main.async {
                store?.updateContent(id: id, content: text)
                coordinator?.pendingLocalEdits -= 1
            }
        }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(tv)
        window.makeKeyAndVisible()
        tv.layoutIfNeeded()

        self.window = window
        self.coordinator = coordinator
        self.textView = tv
        return tv
    }

    // MARK: - Paste

    func testPastesClipboardAtCursorAndHoldsTheSnapshot() {
        controller.handleAppOpened()

        XCTAssertEqual(content, "hello big world")
        XCTAssertEqual(store.cursorPosition(for: tabID), 9)
        XCTAssertNil(store.takePendingExternalCursor(for: tabID))
        XCTAssertEqual(controller.pending?.characterCount, 4)
        XCTAssertEqual(controller.pending?.range, NSRange(location: 5, length: 4))
        XCTAssertEqual(versions.map(\.text), ["hello world"])
    }

    func testCursorBeyondTextIsClamped() {
        store.updateCursorPosition(id: tabID, position: 999)
        controller.handleAppOpened()
        XCTAssertEqual(content, "hello world big")
        XCTAssertEqual(store.cursorPosition(for: tabID), 15)
    }

    func testCountsCharactersNotUTF16Units() {
        pasteboard.string = "👋🏽 hi"
        controller.handleAppOpened()
        XCTAssertEqual(controller.pending?.characterCount, 4)
        XCTAssertEqual(controller.pending?.range.length, "👋🏽 hi".utf16.count)
    }

    func testSameChangeCountIsPastedOnlyOnce() {
        controller.handleAppOpened()
        controller.dismiss()
        controller.handleAppOpened()
        XCTAssertEqual(content, "hello big world")

        // Persisted – a relaunch with the same clipboard does not paste again
        controller = makeController()
        controller.handleAppOpened()
        XCTAssertEqual(content, "hello big world")
        XCTAssertNil(controller.pending)

        pasteboard.changeCount += 1
        pasteboard.string = "!"
        controller.handleAppOpened()
        XCTAssertEqual(content, "hello big! world")
    }

    func testSettingOffDoesNothing() {
        settings.autoPasteOnOpen = false
        controller.handleAppOpened()
        XCTAssertEqual(content, "hello world")
        XCTAssertNil(controller.pending)
    }

    func testEmptyClipboardDoesNothing() {
        pasteboard.string = nil
        controller.handleAppOpened()
        XCTAssertEqual(content, "hello world")

        pasteboard.string = ""
        pasteboard.changeCount += 1
        controller.handleAppOpened()
        XCTAssertEqual(content, "hello world")
        XCTAssertNil(controller.pending)
    }

    func testNoSelectedTabDoesNothing() {
        store.selectedTabID = nil
        controller.handleAppOpened()
        XCTAssertEqual(content, "hello world")
        XCTAssertNil(controller.pending)
    }

    // MARK: - Undo

    func testUndoRestoresContentAndCursorAndLeavesNoPasteVersion() {
        controller.handleAppOpened()
        controller.undo()

        XCTAssertEqual(content, "hello world")
        XCTAssertEqual(store.cursorPosition(for: tabID), 5)
        XCTAssertNil(store.takePendingExternalCursor(for: tabID))
        XCTAssertNil(controller.pending)

        store.fireIdleTimer(id: tabID)
        store.fireHoldTimer(id: tabID)
        store.flushPendingVersions()
        XCTAssertEqual(versions.map(\.text), ["hello world"])
        XCTAssertFalse(versions.contains { $0.source == .paste })
    }

    func testUndoAfterFurtherEditIsIgnored() {
        controller.handleAppOpened()
        store.updateContent(id: tabID, content: "hello big world!")
        controller.undo()
        XCTAssertEqual(content, "hello big world!")
        XCTAssertEqual(versions.filter { $0.source == .paste }.count, 1)
    }

    // MARK: - Dismiss

    func testDismissCommitsExactlyOnePasteVersion() {
        controller.handleAppOpened()
        controller.dismiss()

        XCTAssertNil(controller.pending)
        store.fireHoldTimer(id: tabID)
        store.flushPendingVersions()
        XCTAssertEqual(versions.map(\.text), ["hello big world", "hello world"])
        XCTAssertEqual(versions.first?.source, .paste)
        XCTAssertEqual(versions.first?.parentID, versions.last?.id)
    }

    func testTimeoutCommitsThePaste() {
        controller.dismissInterval = 0.05
        controller.handleAppOpened()
        XCTAssertNotNil(controller.pending)

        pumpRunLoop(seconds: 0.2)
        XCTAssertNil(controller.pending)
        XCTAssertEqual(versions.filter { $0.source == .paste }.count, 1)
    }

    func testFurtherEditClosesTheUndoWindow() {
        controller.handleAppOpened()
        store.updateContent(id: tabID, content: "hello big world!")
        XCTAssertNil(controller.pending)
        XCTAssertEqual(versions.filter { $0.source == .paste }.map(\.text), ["hello big world"])
    }

    func testNewClipboardOnReturnCommitsThePreviousPaste() {
        controller.handleAppOpened()
        pasteboard.changeCount += 1
        pasteboard.string = "!"
        controller.handleAppOpened()

        XCTAssertEqual(content, "hello big! world")
        XCTAssertEqual(versions.filter { $0.source == .paste }.map(\.text), ["hello big world"])
        XCTAssertEqual(controller.pending?.previousContent, "hello big world")
    }

    // MARK: - Live text view

    func testTextViewPasteKeepsSnapshotHeldUntilUndo() {
        let tv = attachTextView()
        controller.handleAppOpened()

        XCTAssertEqual(tv.text, "hello big world")
        XCTAssertEqual(tv.selectedRange, NSRange(location: 9, length: 0))
        XCTAssertNil(store.takePendingExternalCursor(for: tabID))

        // The text view's async content report must not count as a real edit
        pumpRunLoop()
        XCTAssertEqual(content, "hello big world")
        XCTAssertNotNil(controller.pending)
        XCTAssertFalse(versions.contains { $0.source == .paste })

        controller.undo()
        XCTAssertEqual(tv.text, "hello world")
        XCTAssertEqual(tv.selectedRange, NSRange(location: 5, length: 0))
        pumpRunLoop()
        XCTAssertEqual(content, "hello world")
        XCTAssertEqual(coordinator?.pendingLocalEdits, 0)

        store.fireIdleTimer(id: tabID)
        store.flushPendingVersions()
        XCTAssertEqual(versions.map(\.text), ["hello world"])
    }

    func testTextViewPasteThenDismissCommitsOnce() {
        _ = attachTextView()
        controller.handleAppOpened()
        pumpRunLoop()
        controller.dismiss()
        store.flushPendingVersions()
        XCTAssertEqual(versions.map(\.source), [.paste, .edit])
    }
}
