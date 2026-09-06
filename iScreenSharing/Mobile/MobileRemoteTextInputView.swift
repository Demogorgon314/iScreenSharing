#if os(iOS)
import UIKit

/// A local input-method buffer, not a mirror of the remote document. UIKit
/// owns selection and marked text; only completed edits leave this view.
@MainActor
final class MobileRemoteTextInputView: UITextView, UITextViewDelegate {
    var onCommit: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onCompositionChange: ((Bool) -> Void)?
    var onDidResign: (() -> Void)?
    var onRemotePressesBegan: ((Set<UIPress>, UIPressesEvent?) -> Void)?
    var onRemotePressesEnded: ((Set<UIPress>, UIPressesEvent?) -> Void)?
    var onRemotePressesCancelled: ((Set<UIPress>, UIPressesEvent?) -> Void)?
    var acceptsInput = true {
        didSet {
            if !acceptsInput {
                routedKeyCodes.removeAll()
                discardPendingText()
            }
        }
    }
    private var mutationDepth = 0
    private var isDiscarding = false
    private var routedKeyCodes = Set<UIKeyboardHIDUsage>()

    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override var hasText: Bool { true }

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        isScrollEnabled = false
        font = .preferredFont(forTextStyle: .callout)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 6
        textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        alpha = 0.01
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func insertText(_ text: String) {
        guard acceptsInput else { return }
        mutate { super.insertText(text) }
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard acceptsInput else { return }
        mutate { super.setMarkedText(markedText, selectedRange: selectedRange) }
    }

    override func unmarkText() {
        mutate { super.unmarkText() }
    }

    override func replace(_ range: UITextRange, withText text: String) {
        guard acceptsInput else { return }
        mutate { super.replace(range, withText: text) }
    }

    override func deleteBackward() {
        guard acceptsInput else { return }
        if markedTextRange == nil, text.isEmpty {
            onDelete?()
        } else {
            // Deleting phonetic text must never delete the remote document.
            let wasComposing = markedTextRange != nil
            mutate {
                super.deleteBackward()
                if wasComposing, markedTextRange == nil { discardPendingText() }
            }
        }
    }

    override func resignFirstResponder() -> Bool {
        discardPendingText()
        let resigned = super.resignFirstResponder()
        if resigned { onDidResign?() }
        return resigned
    }

    func discardPendingText() {
        guard !isDiscarding else { return }
        isDiscarding = true
        super.unmarkText()
        text = ""
        undoManager?.removeAllActions()
        isDiscarding = false
        alpha = 0.01
        onCompositionChange?(false)
    }

    func textViewDidChange(_ textView: UITextView) { publishCompletedEdit() }

    private func mutate(_ operation: () -> Void) {
        mutationDepth += 1
        operation()
        mutationDepth -= 1
        publishCompletedEdit()
    }

    private func publishCompletedEdit() {
        guard mutationDepth == 0, !isDiscarding else { return }
        guard acceptsInput else { discardPendingText(); return }
        let composing = markedTextRange != nil
        alpha = composing ? 1 : 0.01
        onCompositionChange?(composing)
        guard !composing, !text.isEmpty else { return }
        let committed = text ?? ""
        // Clear before calling out so nested callbacks cannot send it twice.
        discardPendingText()
        onCommit?(committed)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard acceptsInput else { return }
        let remote = Set(presses.filter { press in
            guard markedTextRange == nil, let key = press.key else { return false }
            let command = !key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty
            let navigation: Set<UIKeyboardHIDUsage> = [
                .keyboardEscape, .keyboardTab, .keyboardLeftArrow, .keyboardRightArrow,
                .keyboardUpArrow, .keyboardDownArrow, .keyboardHome, .keyboardEnd,
                .keyboardPageUp, .keyboardPageDown, .keyboardDeleteForward,
            ]
            guard command || navigation.contains(key.keyCode) else { return false }
            routedKeyCodes.insert(key.keyCode)
            return true
        })
        if !remote.isEmpty { onRemotePressesBegan?(remote, event) }
        let local = presses.subtracting(remote)
        if !local.isEmpty { super.pressesBegan(local, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remote = Set(presses.filter { press in
            guard let code = press.key?.keyCode else { return false }
            return routedKeyCodes.remove(code) != nil
        })
        if !remote.isEmpty { onRemotePressesEnded?(remote, event) }
        let local = presses.subtracting(remote)
        if !local.isEmpty { super.pressesEnded(local, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        routedKeyCodes.removeAll()
        discardPendingText()
        onRemotePressesCancelled?(presses, event)
        super.pressesCancelled(presses, with: event)
    }
}
#endif
