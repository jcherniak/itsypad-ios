import Combine
import UIKit

protocol PasteboardReading: AnyObject {
    var hasStrings: Bool { get }
    var string: String? { get }
    var changeCount: Int { get }
}

extension UIPasteboard: PasteboardReading {}

struct PendingPaste: Equatable {
    let tabID: UUID
    let range: NSRange
    let previousContent: String
    let newContent: String
    let previousCursor: Int
    let characterCount: Int
}

/// Inserts the clipboard into the selected note when the app opens and keeps
/// the paste undoable for a few seconds. The paste version is held in
/// TabStore until the undo window closes, so an undone paste never reaches
/// version history.
final class AutoPasteController: ObservableObject {
    static let shared = AutoPasteController()

    @Published private(set) var pending: PendingPaste?

    var pasteboard: PasteboardReading
    var tabStore: TabStore
    var settings: SettingsStore
    var defaults: UserDefaults
    var textViewProvider: (UUID) -> EditorTextView?
    var dismissInterval: TimeInterval = 8

    private static let lastChangeCountKey = "autoPasteLastChangeCount"
    private var dismissWork: DispatchWorkItem?
    private var tabsObservation: AnyCancellable?

    init(
        pasteboard: PasteboardReading = UIPasteboard.general,
        tabStore: TabStore = .shared,
        settings: SettingsStore = .shared,
        defaults: UserDefaults = .standard,
        textViewProvider: @escaping (UUID) -> EditorTextView? = { EditorView.textView(for: $0) }
    ) {
        self.pasteboard = pasteboard
        self.tabStore = tabStore
        self.settings = settings
        self.defaults = defaults
        self.textViewProvider = textViewProvider
    }

    private var lastPastedChangeCount: Int? {
        get { defaults.object(forKey: Self.lastChangeCountKey) as? Int }
        set { defaults.set(newValue, forKey: Self.lastChangeCountKey) }
    }

    /// Cold launch and every return from background.
    func handleAppOpened() {
        guard settings.autoPasteOnOpen else { return }
        // hasStrings does not trigger the system paste prompt – reading does
        guard pasteboard.hasStrings else { return }
        let changeCount = pasteboard.changeCount
        guard changeCount != lastPastedChangeCount else { return }
        guard let id = tabStore.selectedTabID,
              let tab = tabStore.tabs.first(where: { $0.id == id }) else { return }
        lastPastedChangeCount = changeCount
        guard let string = pasteboard.string, !string.isEmpty else { return }

        dismiss()
        paste(string, into: tab)
    }

    private func paste(_ string: String, into tab: TabData) {
        let id = tab.id
        let textView = textViewProvider(id)
        let previousContent = textView?.text ?? tab.content
        let length = previousContent.utf16.count
        let previousCursor = min(max(tabStore.cursorPosition(for: id), 0), length)
        let range = NSRange(location: previousCursor, length: string.utf16.count)
        let newContent = (previousContent as NSString)
            .replacingCharacters(in: NSRange(location: previousCursor, length: 0), with: string)
        let newCursor = NSMaxRange(range)

        tabStore.recordEdit(id: id, content: newContent, source: .paste, hold: true)
        if let textView {
            textView.applyEdit(
                in: NSRange(location: previousCursor, length: 0),
                with: string,
                selection: NSRange(location: newCursor, length: 0)
            )
        }
        // Pushed synchronously so the text view's async change report is a
        // no-op rather than a real edit (which would commit the held paste).
        // Without a text view the editor is built later from content and
        // cursorPosition, so no pending external cursor is needed either.
        tabStore.setContentExternally(id: id, content: newContent, cursor: nil)
        tabStore.updateCursorPosition(id: id, position: newCursor)

        pending = PendingPaste(
            tabID: id,
            range: range,
            previousContent: previousContent,
            newContent: newContent,
            previousCursor: previousCursor,
            characterCount: string.count
        )
        observeFurtherEdits(tabID: id, newContent: newContent)
        scheduleDismiss()
    }

    func undo() {
        guard let paste = pending else { return }
        stopTracking()
        pending = nil

        guard let tab = tabStore.tabs.first(where: { $0.id == paste.tabID }),
              tab.content == paste.newContent else {
            tabStore.commitHeldSnapshot(id: paste.tabID)
            return
        }

        let textView = textViewProvider(paste.tabID)
        if let textView, textView.text == paste.newContent {
            textView.applyEdit(
                in: paste.range,
                with: "",
                selection: NSRange(location: paste.previousCursor, length: 0)
            )
            tabStore.setContentExternally(id: paste.tabID, content: paste.previousContent, cursor: nil)
        } else {
            let cursor = textView == nil ? nil : paste.previousCursor
            tabStore.setContentExternally(id: paste.tabID, content: paste.previousContent, cursor: cursor)
        }
        tabStore.updateCursorPosition(id: paste.tabID, position: paste.previousCursor)
        tabStore.discardHeldSnapshot(id: paste.tabID)
    }

    /// Closes the undo window and keeps the paste as a version.
    func dismiss() {
        guard let paste = pending else { return }
        stopTracking()
        pending = nil
        tabStore.commitHeldSnapshot(id: paste.tabID)
    }

    private func observeFurtherEdits(tabID: UUID, newContent: String) {
        tabsObservation = tabStore.$tabs.sink { [weak self] tabs in
            guard self?.pending != nil else { return }
            if tabs.first(where: { $0.id == tabID })?.content != newContent {
                self?.dismiss()
            }
        }
    }

    private func scheduleDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissInterval, execute: work)
    }

    private func stopTracking() {
        dismissWork?.cancel()
        dismissWork = nil
        tabsObservation?.cancel()
        tabsObservation = nil
    }
}
