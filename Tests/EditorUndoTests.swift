import XCTest
@testable import ItsypadCore

/// Undo/redo through EditorTextView must keep EditorCoordinator's
/// pendingLocalEdits balanced: exactly one textViewDidChange (and therefore
/// one onTextChange) per undo or redo.
final class EditorUndoTests: XCTestCase {
    private var window: UIWindow!
    private var textView: EditorTextView!
    private var coordinator: EditorCoordinator!
    private var textChanges: [String] = []

    override func setUp() {
        super.setUp()

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        textView = EditorTextView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), textContainer: textContainer)
        textView.ownedTextStorage = textStorage

        coordinator = EditorCoordinator()
        textView.font = coordinator.font
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.language = "plain"

        textChanges = []
        textView.onTextChange = { [weak self] content in
            self?.textChanges.append(content)
        }

        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()
        textView.becomeFirstResponder()
    }

    override func tearDown() {
        textView.resignFirstResponder()
        textView.delegate = nil
        coordinator.textView = nil
        coordinator = nil
        textView.removeFromSuperview()
        textView = nil
        window = nil
        super.tearDown()
    }

    private func pumpRunLoop(seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func insertUndoable(_ string: String, at location: Int) {
        let end = location + string.utf16.count
        textView.applyEdit(in: NSRange(location: location, length: 0), with: string, selection: NSRange(location: end, length: 0))
        // Let the undo manager close the event group, as it would between keystrokes
        pumpRunLoop()
    }

    func testReplaceTextPreservingUndoNotifiesDelegateItself() {
        // UITextInput.replace(_:withText:) delivers textViewDidChange on its
        // own – the manual follow-up call elsewhere in the editor is a duplicate
        textView.text = "hello"
        textView.replaceTextPreservingUndo(in: NSRange(location: 5, length: 0), with: "!")

        XCTAssertEqual(textChanges, ["hello!"])
        XCTAssertEqual(textView.textChangeCount, 1)
    }

    func testApplyEditNotifiesExactlyOnce() {
        textView.text = "hello"
        textView.applyEdit(in: NSRange(location: 5, length: 0), with: " world", selection: NSRange(location: 11, length: 0))

        XCTAssertEqual(textChanges, ["hello world"])
        XCTAssertEqual(coordinator.pendingLocalEdits, 1)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 11, length: 0))
    }

    // MARK: - Undo

    func testUndoRevertsTextAndFiresOnTextChangeExactlyOnce() {
        textView.text = "hello"
        insertUndoable(" world", at: 5)
        XCTAssertEqual(textView.text, "hello world")
        XCTAssertEqual(textChanges.count, 1)
        XCTAssertEqual(coordinator.pendingLocalEdits, 1)
        XCTAssertTrue(textView.undoManager?.canUndo ?? false, "replaceTextPreservingUndo must register with the undo manager")

        textView.performUndo()

        XCTAssertEqual(textView.text, "hello")
        XCTAssertEqual(textChanges.count, 2, "undo must produce exactly one onTextChange")
        XCTAssertEqual(textChanges.last, "hello")
        XCTAssertEqual(coordinator.pendingLocalEdits, 2)
    }

    func testRedoReappliesTextAndFiresOnTextChangeExactlyOnce() {
        textView.text = "hello"
        insertUndoable(" world", at: 5)
        textView.performUndo()
        pumpRunLoop()
        XCTAssertEqual(textChanges.count, 2)
        XCTAssertTrue(textView.undoManager?.canRedo ?? false)

        textView.performRedo()

        XCTAssertEqual(textView.text, "hello world")
        XCTAssertEqual(textChanges.count, 3, "redo must produce exactly one onTextChange")
        XCTAssertEqual(textChanges.last, "hello world")
        XCTAssertEqual(coordinator.pendingLocalEdits, 3)
    }

    func testUndoWithNothingToUndoIsNoop() {
        textView.text = "hello"

        textView.performUndo()
        textView.performRedo()

        XCTAssertEqual(textView.text, "hello")
        XCTAssertEqual(textChanges.count, 0)
        XCTAssertEqual(coordinator.pendingLocalEdits, 0)
    }

    func testMarkdownEditIsUndoableInOneStep() {
        textView.text = "hello world"
        textView.selectedRange = NSRange(location: 6, length: 5)

        textView.toggleBold()
        pumpRunLoop()
        XCTAssertEqual(textView.text, "hello **world**")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 8, length: 5))
        XCTAssertEqual(textChanges.count, 1)

        textView.performUndo()

        XCTAssertEqual(textView.text, "hello world")
        XCTAssertEqual(textChanges.count, 2)
    }

    // MARK: - Accessory bar state

    func testAccessoryBarIsInstalledAndTracksUndoState() {
        XCTAssertTrue(textView.inputAccessoryView === textView.accessoryBar)

        textView.text = "hello"
        textView.accessoryBar.refresh()
        XCTAssertFalse(textView.accessoryBar.undoButton.isEnabled)
        XCTAssertFalse(textView.accessoryBar.redoButton.isEnabled)

        insertUndoable(" world", at: 5)
        XCTAssertTrue(textView.accessoryBar.undoButton.isEnabled)
        XCTAssertFalse(textView.accessoryBar.redoButton.isEnabled)

        textView.performUndo()
        pumpRunLoop()
        XCTAssertTrue(textView.accessoryBar.redoButton.isEnabled)
    }

    func testAccessoryBarHidesProseButtonsForCode() {
        coordinator.language = "swift"
        XCTAssertTrue(textView.accessoryBar.boldButton.isHidden)
        XCTAssertTrue(textView.accessoryBar.headingButton.isHidden)
        XCTAssertTrue(textView.accessoryBar.linkButton.isHidden)
        XCTAssertTrue(textView.accessoryBar.bulletButton.isHidden)
        XCTAssertFalse(textView.accessoryBar.undoButton.isHidden)
        XCTAssertFalse(textView.accessoryBar.indentButton.isHidden)
        XCTAssertFalse(textView.accessoryBar.dismissButton.isHidden)

        coordinator.language = "markdown"
        XCTAssertFalse(textView.accessoryBar.boldButton.isHidden)
        XCTAssertFalse(textView.accessoryBar.headingButton.isHidden)
        XCTAssertEqual(textView.accessoryBar.bulletButton.isHidden, !SettingsStore.shared.bulletListsEnabled)
    }

    func testMarkdownShortcutsIgnoredForCode() {
        coordinator.language = "swift"
        textView.text = "let x = 1"
        textView.selectedRange = NSRange(location: 4, length: 1)

        textView.toggleBold()
        textView.toggleHeading()
        textView.insertLink()

        XCTAssertEqual(textView.text, "let x = 1")
        XCTAssertEqual(textChanges.count, 0)
    }

    func testBoldAndItalicKeyCommandsOnlyForProse() {
        func hasCommand(_ input: String) -> Bool {
            textView.keyCommands?.contains { $0.input == input && $0.modifierFlags == .command } ?? false
        }
        XCTAssertTrue(hasCommand("b"))
        XCTAssertTrue(hasCommand("i"))

        coordinator.language = "swift"
        XCTAssertFalse(hasCommand("b"))
        XCTAssertFalse(hasCommand("i"))
    }
}
