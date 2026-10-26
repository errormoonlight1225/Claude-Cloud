import UIKit

final class ChatViewController: UIViewController, UITableViewDataSource, UITextViewDelegate {
    private let conversation: Conversation
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let inputBar = UIView()
    private let inputTextView = UITextView()
    private let placeholderLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private var inputBottom: NSLayoutConstraint!
    private var inputHeight: NSLayoutConstraint!

    private var stream: ClaudeStream?
    private var streamingMessage: ChatMessage?
    private var refreshScheduled = false

    init(conversation: Conversation) {
        self.conversation = conversation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "设置", style: .plain, target: self, action: #selector(openSettings))
        setupTable()
        setupInputBar()

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        title = Settings.modelOption.name
        tableView.reloadData()
        scrollToBottom(animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            stream?.cancel()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layout

    private func setupTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = Theme.background
        tableView.estimatedRowHeight = 80
        tableView.rowHeight = UITableView.automaticDimension
        tableView.keyboardDismissMode = .interactive
        tableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseID)
        view.addSubview(tableView)
    }

    private func setupInputBar() {
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.backgroundColor = .white
        view.addSubview(inputBar)

        let separator = UIView()
        separator.backgroundColor = UIColor(white: 0.85, alpha: 1)
        separator.translatesAutoresizingMaskIntoConstraints = false
        inputBar.addSubview(separator)

        inputTextView.font = UIFont.systemFont(ofSize: 16)
        inputTextView.layer.cornerRadius = 18
        inputTextView.layer.borderWidth = 1
        inputTextView.layer.borderColor = UIColor(white: 0.85, alpha: 1).cgColor
        inputTextView.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        inputTextView.delegate = self
        inputTextView.translatesAutoresizingMaskIntoConstraints = false
        inputBar.addSubview(inputTextView)

        placeholderLabel.text = "给 Claude 发消息"
        placeholderLabel.font = UIFont.systemFont(ofSize: 16)
        placeholderLabel.textColor = UIColor(white: 0.7, alpha: 1)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        inputTextView.addSubview(placeholderLabel)

        sendButton.setTitle("发送", for: .normal)
        sendButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        inputBar.addSubview(sendButton)

        inputBottom = inputBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        inputHeight = inputTextView.heightAnchor.constraint(equalToConstant: 36)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),

            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBottom,

            separator.topAnchor.constraint(equalTo: inputBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            inputTextView.topAnchor.constraint(equalTo: inputBar.topAnchor, constant: 8),
            inputTextView.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            inputTextView.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8).withPriority(.defaultHigh),
            inputTextView.bottomAnchor.constraint(lessThanOrEqualTo: inputBar.bottomAnchor, constant: -8),
            inputHeight,

            placeholderLabel.leadingAnchor.constraint(equalTo: inputTextView.leadingAnchor, constant: 15),
            placeholderLabel.topAnchor.constraint(equalTo: inputTextView.topAnchor, constant: 8),

            sendButton.leadingAnchor.constraint(equalTo: inputTextView.trailingAnchor, constant: 10),
            sendButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            sendButton.bottomAnchor.constraint(equalTo: inputTextView.bottomAnchor),
            sendButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let info = note.userInfo,
              let frame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let local = view.convert(frame, from: nil)
        let overlap = max(0, view.bounds.maxY - local.minY)
        // While the keyboard is up, the input bar sits on it instead of on the home indicator area.
        inputBottom.constant = -overlap
        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        UIView.animate(withDuration: duration) {
            self.view.layoutIfNeeded()
        }
        scrollToBottom(animated: true)
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        let height = min(max(36, fitting.height), 120)
        textView.isScrollEnabled = fitting.height > 120
        if inputHeight.constant != height {
            inputHeight.constant = height
            view.layoutIfNeeded()
        }
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return conversation.messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: MessageCell.reuseID, for: indexPath) as! MessageCell
        let message = conversation.messages[indexPath.row]
        cell.configure(with: message, streaming: message === streamingMessage)
        return cell
    }

    private func scrollToBottom(animated: Bool) {
        let count = conversation.messages.count
        guard count > 0 else { return }
        tableView.scrollToRow(at: IndexPath(row: count - 1, section: 0), at: .bottom, animated: animated)
    }

    private var isNearBottom: Bool {
        let visibleBottom = tableView.contentOffset.y + tableView.bounds.height - tableView.adjustedContentInset.bottom
        return tableView.contentSize.height - visibleBottom < 120
    }

    // MARK: - Sending

    @objc private func openSettings() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    @objc private func sendTapped() {
        if let stream = stream {
            stream.cancel()
            return
        }
        let text = inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !Settings.apiKey.isEmpty else {
            let alert = UIAlertController(title: "需要 API Key", message: "请先在设置中填写 Anthropic API Key。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "去设置", style: .default) { _ in self.openSettings() })
            present(alert, animated: true)
            return
        }

        inputTextView.text = ""
        textViewDidChange(inputTextView)

        if conversation.messages.isEmpty {
            conversation.title = String(text.prefix(30))
        }
        conversation.messages.append(ChatMessage(role: .user, text: text))
        ConversationStore.shared.touch(conversation)
        startResponse()
    }

    private func startResponse() {
        let request: URLRequest
        do {
            request = try ClaudeStream.makeRequest(messages: conversation.apiMessages())
        } catch {
            showError(error.localizedDescription)
            return
        }

        let reply = ChatMessage(role: .assistant, text: "")
        reply.model = Settings.model
        conversation.messages.append(reply)
        streamingMessage = reply
        tableView.reloadData()
        scrollToBottom(animated: true)

        let stream = ClaudeStream { [weak self] event in
            self?.handle(event, for: reply)
        }
        self.stream = stream
        setStreaming(true)
        stream.start(request)
    }

    private func handle(_ event: StreamEvent, for reply: ChatMessage) {
        switch event {
        case .started(let model):
            if !model.isEmpty { reply.model = model }
        case .thinkingDelta(let text):
            reply.thinking += text
            scheduleRefresh()
        case .textDelta(let text):
            reply.text += text
            scheduleRefresh()
        case .fallback(let to):
            reply.thinking = ""
            reply.note = "已自动切换到 \(to) 继续回答"
            scheduleRefresh()
        case .finished(let stopReason, let category):
            switch stopReason ?? "" {
            case "refusal":
                reply.note = "该请求被安全策略拒绝" + (category.map { "（\($0)）" } ?? "")
                // A declined partial answer is not complete; keep it visible but out of the history.
                reply.excluded = true
            case "max_tokens":
                reply.note = "回答已达到长度上限，被截断"
            default:
                break
            }
            finish(reply)
        case .failed(let message):
            reply.note = "出错：" + message
            if reply.text.isEmpty { reply.excluded = true }
            finish(reply)
        case .cancelled:
            reply.note = "已停止"
            if reply.text.isEmpty { reply.excluded = true }
            finish(reply)
        }
    }

    private func finish(_ reply: ChatMessage) {
        stream = nil
        streamingMessage = nil
        setStreaming(false)
        ConversationStore.shared.touch(conversation)
        refreshLastRow()
    }

    private func setStreaming(_ streaming: Bool) {
        sendButton.setTitle(streaming ? "停止" : "发送", for: .normal)
        sendButton.setTitleColor(streaming ? Theme.error : Theme.accent, for: .normal)
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.refreshScheduled = false
            self?.refreshLastRow()
        }
    }

    private func refreshLastRow() {
        let count = conversation.messages.count
        guard count > 0 else { return }
        let indexPath = IndexPath(row: count - 1, section: 0)
        let follow = isNearBottom
        UIView.performWithoutAnimation {
            if let cell = tableView.cellForRow(at: indexPath) as? MessageCell {
                let message = conversation.messages[count - 1]
                cell.configure(with: message, streaming: message === streamingMessage)
                tableView.beginUpdates()
                tableView.endUpdates()
            } else {
                tableView.reloadData()
            }
        }
        if follow { scrollToBottom(animated: false) }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "错误", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
