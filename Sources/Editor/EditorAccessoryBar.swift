import UIKit

/// Toolbar shown above the keyboard: undo/redo, markdown shortcuts (prose
/// only), list toggles (prose + setting) and indent/outdent, with a pinned
/// "hide keyboard" button at the trailing edge.
final class EditorAccessoryBar: UIInputView {
    static let barHeight: CGFloat = 44

    weak var textView: EditorTextView?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let separator = UIView()

    private(set) var undoButton: UIButton!
    private(set) var redoButton: UIButton!
    private(set) var headingButton: UIButton!
    private(set) var boldButton: UIButton!
    private(set) var italicButton: UIButton!
    private(set) var strikethroughButton: UIButton!
    private(set) var codeButton: UIButton!
    private(set) var linkButton: UIButton!
    private(set) var checklistButton: UIButton!
    private(set) var bulletButton: UIButton!
    private(set) var numberedButton: UIButton!
    private(set) var outdentButton: UIButton!
    private(set) var indentButton: UIButton!
    private(set) var dismissButton: UIButton!

    private var proseButtons: [UIButton] { [headingButton, boldButton, italicButton, strikethroughButton, codeButton, linkButton] }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.barHeight), inputViewStyle: .keyboard)
        autoresizingMask = .flexibleWidth
        buildButtons()
        buildLayout()
        observeUndoManager()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight)
    }

    // MARK: - Setup

    private func makeButton(symbol: String, label: String, action: @escaping (EditorTextView) -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        config.contentInsets = .zero
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            guard let tv = self?.textView else { return }
            action(tv)
        })
        button.accessibilityLabel = label
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: Self.barHeight),
        ])
        return button
    }

    private func buildButtons() {
        undoButton = makeButton(symbol: "arrow.uturn.backward",
                                label: String(localized: "editor.accessory.undo", defaultValue: "Undo")) { $0.performUndo() }
        redoButton = makeButton(symbol: "arrow.uturn.forward",
                                label: String(localized: "editor.accessory.redo", defaultValue: "Redo")) { $0.performRedo() }
        headingButton = makeButton(symbol: "textformat.size",
                                   label: String(localized: "editor.accessory.heading", defaultValue: "Heading")) { $0.toggleHeading() }
        boldButton = makeButton(symbol: "bold",
                                label: String(localized: "editor.accessory.bold", defaultValue: "Bold")) { $0.toggleBold() }
        italicButton = makeButton(symbol: "italic",
                                  label: String(localized: "editor.accessory.italic", defaultValue: "Italic")) { $0.toggleItalic() }
        strikethroughButton = makeButton(symbol: "strikethrough",
                                         label: String(localized: "editor.accessory.strikethrough", defaultValue: "Strikethrough")) { $0.toggleStrikethrough() }
        codeButton = makeButton(symbol: "chevron.left.forwardslash.chevron.right",
                                label: String(localized: "editor.accessory.code", defaultValue: "Inline code")) { $0.toggleInlineCode() }
        linkButton = makeButton(symbol: "link",
                                label: String(localized: "editor.accessory.link", defaultValue: "Link")) { $0.insertLink() }
        checklistButton = makeButton(symbol: "checklist",
                                     label: String(localized: "editor.accessory.checklist", defaultValue: "Checklist")) { $0.toggleChecklist() }
        bulletButton = makeButton(symbol: "list.bullet",
                                  label: String(localized: "editor.accessory.bullet_list", defaultValue: "Bullet list")) { $0.toggleBulletList() }
        numberedButton = makeButton(symbol: "list.number",
                                    label: String(localized: "editor.accessory.numbered_list", defaultValue: "Numbered list")) { $0.toggleNumberedList() }
        outdentButton = makeButton(symbol: "decrease.indent",
                                   label: String(localized: "editor.accessory.outdent", defaultValue: "Outdent")) { tv in
            (tv.delegate as? EditorCoordinator)?.outdentLines(tv: tv)
        }
        indentButton = makeButton(symbol: "increase.indent",
                                  label: String(localized: "editor.accessory.indent", defaultValue: "Indent")) { tv in
            (tv.delegate as? EditorCoordinator)?.indentLines(tv: tv)
        }
        dismissButton = makeButton(symbol: "keyboard.chevron.compact.down",
                                   label: String(localized: "editor.accessory.dismiss_keyboard", defaultValue: "Hide keyboard")) { tv in
            tv.resignFirstResponder()
        }
    }

    private func buildLayout() {
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for button in [undoButton, redoButton, headingButton, boldButton, italicButton, strikethroughButton,
                       codeButton, linkButton, checklistButton, bulletButton, numberedButton, outdentButton, indentButton] {
            stack.addArrangedSubview(button!)
        }

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        addSubview(scrollView)

        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        addSubview(dismissButton)

        let hairline = 1 / UIScreen.main.scale
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: separator.leadingAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

            separator.widthAnchor.constraint(equalToConstant: hairline),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            separator.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -4),

            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func observeUndoManager() {
        for name in [NSNotification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoManagerDidChange(_:)), name: name, object: nil)
        }
    }

    @objc private func undoManagerDidChange(_ notification: Notification) {
        guard let manager = notification.object as? UndoManager, manager === textView?.undoManager else { return }
        refresh()
    }

    // MARK: - State

    /// Cheap: only toggles isEnabled on undo/redo and isHidden on the
    /// prose-only buttons.
    func refresh() {
        let isProse = textView?.isProse ?? true
        let undoManager = textView?.undoManager
        update(isProse: isProse, canUndo: undoManager?.canUndo ?? false, canRedo: undoManager?.canRedo ?? false)
    }

    func update(isProse: Bool, canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo

        for button in proseButtons {
            setHidden(!isProse, button)
        }

        let store = SettingsStore.shared
        setHidden(!(isProse && store.checklistsEnabled), checklistButton)
        setHidden(!(isProse && store.bulletListsEnabled), bulletButton)
        setHidden(!(isProse && store.numberedListsEnabled), numberedButton)
    }

    private func setHidden(_ hidden: Bool, _ button: UIButton) {
        if button.isHidden != hidden {
            button.isHidden = hidden
        }
    }
}
