import UIKit

final class ConversationListViewController: UITableViewController {
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "对话"
        tableView.backgroundColor = Theme.background
        tableView.tableFooterView = UIView()
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "设置", style: .plain, target: self, action: #selector(openSettings))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .compose, target: self, action: #selector(newConversation))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if Settings.apiKey.isEmpty && presentedViewController == nil && !promptedForKey {
            promptedForKey = true
            openSettings()
        }
    }

    private var promptedForKey = false

    @objc private func openSettings() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    @objc private func newConversation() {
        navigationController?.pushViewController(ChatViewController(conversation: Conversation()), animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return ConversationStore.shared.conversations.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "conversation")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "conversation")
        let conversation = ConversationStore.shared.conversations[indexPath.row]
        cell.backgroundColor = Theme.background
        cell.textLabel?.text = conversation.title
        cell.textLabel?.textColor = Theme.text
        cell.detailTextLabel?.text = dateFormatter.string(from: conversation.updatedAt)
        cell.detailTextLabel?.textColor = Theme.secondaryText
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let conversation = ConversationStore.shared.conversations[indexPath.row]
        navigationController?.pushViewController(ChatViewController(conversation: conversation), animated: true)
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        ConversationStore.shared.delete(ConversationStore.shared.conversations[indexPath.row])
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    override func tableView(_ tableView: UITableView,
                            titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        return "删除"
    }
}
