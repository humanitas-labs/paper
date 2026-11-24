import UIKit

/// The row above the keyboard: the Mac's Format menu, a task, list indent,
/// and a key to put the keyboard away. Quiet, in the page's ink.
final class KeyboardRow: UIInputView {
    private weak var textView: MobileTextView?

    init(textView: MobileTextView) {
        self.textView = textView
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let items: [(symbol: String, label: String, action: Selector)] = [
            ("bold", "Bold", #selector(bold)),
            ("italic", "Italic", #selector(italic)),
            ("strikethrough", "Strikethrough", #selector(strikethrough)),
            ("chevron.left.forwardslash.chevron.right", "Code", #selector(code)),
            ("link", "Add Link", #selector(link)),
            ("checklist", "Task", #selector(task)),
            ("decrease.indent", "Outdent", #selector(outdent)),
            ("increase.indent", "Indent", #selector(indent)),
            ("keyboard.chevron.compact.down", "Hide Keyboard", #selector(dismiss)),
        ]
        let stack = UIStackView(arrangedSubviews: items.map { item in
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
            button.accessibilityLabel = item.label
            button.addTarget(self, action: item.action, for: .touchUpInside)
            return button
        })
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.heightAnchor.constraint(equalToConstant: 46),
            stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        ])
        tintColor = Appearance.ink
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @objc private func bold() { textView?.toggle(.bold) }
    @objc private func italic() { textView?.toggle(.italic) }
    @objc private func strikethrough() { textView?.toggle(.strikethrough) }
    @objc private func code() { textView?.toggle(.code) }
    @objc private func link() { textView?.insertLink() }
    @objc private func task() { textView?.toggleTaskLine() }
    @objc private func outdent() { textView?.indentListItem(outdent: true) }
    @objc private func indent() { textView?.indentListItem(outdent: false) }
    @objc private func dismiss() { _ = textView?.resignFirstResponder() }
}

extension MobileTextView {
    /// `[label](destination)` around the selection, or the word at the
    /// caret; the destination is the clipboard's when it holds a URL, as
    /// on the Mac, and the caret waits inside the parentheses otherwise.
    func insertLink() {
        guard markedTextRange == nil else { return }
        let text = textStorage.string as NSString
        var range = selectedRange
        if range.length == 0 { range = InlineFormat.wordRange(at: range.location, in: text) }
        let label = text.substring(with: range)
        let clipboard = UIPasteboard.general.hasStrings
            ? (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let destination = MarkdownResource.isRemote(clipboard) ? clipboard : ""
        let replacement = "[\(label)](\(destination))"
        let selection: NSRange
        if destination.isEmpty {
            selection = NSRange(location: range.location + label.utf16.count + 3, length: 0)
        } else if label.isEmpty {
            selection = NSRange(location: range.location + 1, length: 0)
        } else {
            selection = NSRange(location: range.location + replacement.utf16.count, length: 0)
        }
        replace(range, with: replacement, selecting: selection)
    }

    /// On a task line, flips its box; on a list item, makes it a task; on
    /// any other line, starts one with `- [ ] `.
    func toggleTaskLine() {
        guard markedTextRange == nil else { return }
        let text = textStorage.string as NSString
        let caret = min(selectedRange.location, text.length)
        let paragraph = text.paragraphRange(for: NSRange(location: caret, length: 0))
        let line = text.substring(with: paragraph)
        let local = NSRange(location: 0, length: (line as NSString).length)
        if let match = MarkdownSyntaxStyler.listMarkerPattern.firstMatch(in: line, range: local) {
            let box = match.range(at: 3)
            if box.location != NSNotFound {
                let inner = NSRange(location: paragraph.location + box.location + 1, length: 1)
                let done = text.substring(with: inner) != " "
                replace(inner, with: done ? " " : "x", selecting: selectedRange)
            } else {
                let at = paragraph.location + NSMaxRange(match.range(at: 2))
                replace(NSRange(location: at, length: 0), with: "[ ] ",
                        selecting: NSRange(location: caret + 4, length: 0))
            }
            return
        }
        let indent = (line as NSString).range(of: #"^[\t ]*"#, options: .regularExpression).length
        let at = paragraph.location + indent
        replace(NSRange(location: at, length: 0), with: "- [ ] ",
                selecting: NSRange(location: max(caret, at) + 6, length: 0))
    }

    // MARK: - Hardware keys

    override var keyCommands: [UIKeyCommand]? {
        let format: [(String, UIKeyModifierFlags, Selector, String)] = [
            ("b", .command, #selector(keyBold), "Bold"),
            ("i", .command, #selector(keyItalic), "Italic"),
            ("u", .command, #selector(keyUnderline), "Underline"),
            ("x", [.command, .shift], #selector(keyStrikethrough), "Strikethrough"),
            ("e", .command, #selector(keyCode), "Code"),
            ("k", .command, #selector(keyLink), "Add Link"),
        ]
        var commands = format.map { input, flags, action, title in
            let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        for (flags, action) in [(UIKeyModifierFlags(), #selector(keyTab)), (.shift, #selector(keyBacktab))] {
            let command = UIKeyCommand(input: "\t", modifierFlags: flags, action: action)
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        return commands
    }

    @objc private func keyBold() { toggle(.bold) }
    @objc private func keyItalic() { toggle(.italic) }
    @objc private func keyUnderline() { toggle(.underline) }
    @objc private func keyStrikethrough() { toggle(.strikethrough) }
    @objc private func keyCode() { toggle(.code) }
    @objc private func keyLink() { insertLink() }
    /// Tab indents a list item; anywhere else it types a tab.
    @objc private func keyTab() {
        if !indentListItem(outdent: false) { insertText("\t") }
    }
    @objc private func keyBacktab() { indentListItem(outdent: true) }
}
