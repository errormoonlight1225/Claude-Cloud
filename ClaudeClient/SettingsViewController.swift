import UIKit

final class SettingsViewController: UITableViewController, UITextFieldDelegate, UITextViewDelegate {
    private enum Section: Int, CaseIterable {
        case account, model, thinking, system, about
    }

    private let apiKeyField = UITextField()
    private let baseURLField = UITextField()
    private let systemTextView = UITextView()
    private let thinkingSwitch = UISwitch()

    init() {
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        tableView.keyboardDismissMode = .onDrag

        apiKeyField.placeholder = "sk-ant-..."
        apiKeyField.isSecureTextEntry = true
        apiKeyField.autocapitalizationType = .none
        apiKeyField.autocorrectionType = .no
        apiKeyField.clearButtonMode = .whileEditing
        apiKeyField.text = Settings.apiKey
        apiKeyField.delegate = self

        baseURLField.placeholder = Settings.defaultBaseURL
        baseURLField.keyboardType = .URL
        baseURLField.autocapitalizationType = .none
        baseURLField.autocorrectionType = .no
        baseURLField.clearButtonMode = .whileEditing
        baseURLField.text = Settings.baseURL == Settings.defaultBaseURL ? "" : Settings.baseURL
        baseURLField.delegate = self

        systemTextView.font = UIFont.systemFont(ofSize: 15)
        systemTextView.text = Settings.systemPrompt
        systemTextView.backgroundColor = .clear
        systemTextView.delegate = self

        thinkingSwitch.isOn = Settings.showThinking
        thinkingSwitch.onTintColor = Theme.accent
        thinkingSwitch.addTarget(self, action: #selector(thinkingSwitchChanged), for: .valueChanged)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveFields()
    }

    private func saveFields() {
        Settings.apiKey = (apiKeyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.baseURL = baseURLField.text ?? ""
        Settings.systemPrompt = systemTextView.text
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        saveFields()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        saveFields()
    }

    @objc private func thinkingSwitchChanged() {
        Settings.showThinking = thinkingSwitch.isOn
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .account: return 2
        case .model: return Settings.models.count + 1
        case .thinking: return Settings.efforts.count + 1
        case .system: return 1
        case .about: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .account: return "账户"
        case .model: return "模型"
        case .thinking: return "思考强度（effort）"
        case .system: return "系统提示词"
        case .about: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .account:
            return "API Key 保存在本机钥匙串中。API 地址留空则使用官方地址；如需通过自建代理访问，可填写代理地址。"
        case .thinking:
            return "强度越高回答越深入，但更慢、消耗更多 token。日常对话推荐 low 或 medium。"
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return Section(rawValue: indexPath.section) == .system ? 120 : 44
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .default
        switch Section(rawValue: indexPath.section)! {
        case .account:
            let field = indexPath.row == 0 ? apiKeyField : baseURLField
            cell.textLabel?.text = indexPath.row == 0 ? "API Key" : "API 地址"
            cell.selectionStyle = .none
            embed(field, in: cell, leading: 100)
        case .model:
            if indexPath.row < Settings.models.count {
                let option = Settings.models[indexPath.row]
                cell.textLabel?.text = option.name
                cell.accessoryType = option.id == Settings.model ? .checkmark : .none
            } else {
                let isCustom = !Settings.models.contains { $0.id == Settings.model }
                cell.textLabel?.text = "自定义模型 ID…"
                cell.detailTextLabel?.text = isCustom ? Settings.model : nil
                cell.accessoryType = isCustom ? .checkmark : .none
            }
        case .thinking:
            if indexPath.row < Settings.efforts.count {
                let effort = Settings.efforts[indexPath.row]
                cell.textLabel?.text = effort
                cell.accessoryType = effort == Settings.effort ? .checkmark : .none
            } else {
                cell.textLabel?.text = "显示思考摘要"
                cell.selectionStyle = .none
                cell.accessoryView = thinkingSwitch
            }
        case .system:
            cell.selectionStyle = .none
            embed(systemTextView, in: cell, leading: 10)
        case .about:
            cell.textLabel?.text = "版本"
            cell.detailTextLabel?.text = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            cell.selectionStyle = .none
        }
        return cell
    }

    private func embed(_ view: UIView, in cell: UITableViewCell, leading: CGFloat) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: leading),
            view.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -12),
            view.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 4),
            view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -4),
        ])
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .model:
            if indexPath.row < Settings.models.count {
                Settings.model = Settings.models[indexPath.row].id
                tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)
            } else {
                promptCustomModel()
            }
        case .thinking where indexPath.row < Settings.efforts.count:
            Settings.effort = Settings.efforts[indexPath.row]
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)
        default:
            break
        }
    }

    private func promptCustomModel() {
        let alert = UIAlertController(title: "自定义模型", message: "输入模型 ID。自定义模型不会发送思考与 effort 参数。", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "claude-..."
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self, weak alert] _ in
            let id = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty else { return }
            Settings.model = id
            self?.tableView.reloadSections(IndexSet(integer: Section.model.rawValue), with: .none)
        })
        present(alert, animated: true)
    }
}
