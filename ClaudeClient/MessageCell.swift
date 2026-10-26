import UIKit

final class MessageCell: UITableViewCell {
    static let reuseID = "MessageCell"

    private let bubble = UIView()
    private let thinkingLabel = UILabel()
    private let bodyView = UITextView()
    private let noteLabel = UILabel()
    private let stack = UIStackView()

    private var leadingEqual: NSLayoutConstraint!
    private var leadingFlexible: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        bubble.layer.cornerRadius = 14
        bubble.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bubble)

        thinkingLabel.font = UIFont.italicSystemFont(ofSize: 13)
        thinkingLabel.textColor = Theme.secondaryText
        thinkingLabel.numberOfLines = 6

        bodyView.isScrollEnabled = false
        bodyView.isEditable = false
        bodyView.isSelectable = true
        bodyView.dataDetectorTypes = [.link]
        bodyView.backgroundColor = .clear
        bodyView.textContainerInset = .zero
        bodyView.textContainer.lineFragmentPadding = 0

        noteLabel.font = UIFont.systemFont(ofSize: 13)
        noteLabel.textColor = Theme.error
        noteLabel.numberOfLines = 0

        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        [thinkingLabel, bodyView, noteLabel].forEach(stack.addArrangedSubview)
        bubble.addSubview(stack)

        leadingEqual = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        leadingFlexible = bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 56)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with message: ChatMessage, streaming: Bool) {
        let isUser = message.role == .user
        // Deactivate before activating so the two leading constraints never conflict.
        if isUser {
            leadingEqual.isActive = false
            leadingFlexible.isActive = true
        } else {
            leadingFlexible.isActive = false
            leadingEqual.isActive = true
        }
        bubble.backgroundColor = isUser ? Theme.userBubble : .clear

        if isUser {
            bodyView.attributedText = NSAttributedString(string: message.text, attributes: [
                .font: Markdown.bodyFont, .foregroundColor: Theme.text,
            ])
        } else {
            var text = message.text
            if streaming && text.isEmpty && message.thinking.isEmpty { text = "…" }
            bodyView.attributedText = Markdown.render(text)
        }
        bodyView.isHidden = bodyView.attributedText.length == 0

        let thinking = message.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        thinkingLabel.isHidden = isUser || thinking.isEmpty || !Settings.showThinking
        thinkingLabel.text = "💭 " + thinking

        noteLabel.text = message.note
        noteLabel.isHidden = (message.note ?? "").isEmpty
    }
}
