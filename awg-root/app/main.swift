// AWG Root: a small UIKit front end for /usr/bin/awg-root on jailbroken iOS 12+.

import UIKit
import Darwin

let helperPath = "/usr/bin/awg-root"

struct CommandResult {
    let status: Int32
    let output: String
}

/// Runs the setuid helper with the given arguments, optionally feeding `input` on stdin.
/// Returns its exit status and combined stdout/stderr. Blocks; call it off the main thread.
func runHelper(_ args: [String], input: Data? = nil) -> CommandResult {
    guard FileManager.default.isExecutableFile(atPath: helperPath) else {
        return CommandResult(status: -1, output: "找不到 \(helperPath),请重新安装 deb。")
    }
    var inPipe: [Int32] = [0, 0]
    var outPipe: [Int32] = [0, 0]
    guard pipe(&inPipe) == 0 else { return CommandResult(status: -1, output: "pipe() 失败") }
    guard pipe(&outPipe) == 0 else {
        close(inPipe[0]); close(inPipe[1])
        return CommandResult(status: -1, output: "pipe() 失败")
    }

    // The helper may start a long-running daemon; mark our pipe ends close-on-exec so only the dup2'd
    // copies (fds 0-2) reach the child. Otherwise the daemon inherits the write end and we never see EOF.
    for fd in inPipe + outPipe {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], 2)
    posix_spawn_file_actions_addclose(&actions, inPipe[1])
    posix_spawn_file_actions_addclose(&actions, outPipe[0])

    let argv: [UnsafeMutablePointer<CChar>?] = ([helperPath] + args).map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"), nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, helperPath, &actions, nil, argv, envp)
    close(inPipe[0])
    close(outPipe[1])
    if rc != 0 {
        close(inPipe[1])
        close(outPipe[0])
        return CommandResult(status: -1, output: "无法启动 \(helperPath):\(String(cString: strerror(rc)))")
    }
    if let input = input, !input.isEmpty {
        input.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(inPipe[1], buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }
    close(inPipe[1])
    let data = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true).readDataToEndOfFile()
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
    return CommandResult(status: exitCode, output: String(decoding: data, as: UTF8.self))
}

/// Replaces characters the helper does not accept in config names.
func sanitizedName(_ raw: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
    var name = String(raw.map { allowed.contains($0) ? $0 : "_" })
    while name.hasPrefix(".") { name.removeFirst() }
    if name.isEmpty { name = "tunnel" }
    return String(name.prefix(32))
}

final class MainViewController: UITableViewController, UIDocumentPickerDelegate {
    private let helperQueue = DispatchQueue(label: "awg-root.helper")
    private var configs: [String] = []
    private var activeConfig: String?
    private var statusText = "正在读取状态…"
    private var busy = false
    private var refreshTimer: Timer?
    private let spinner = UIActivityIndicatorView(style: .gray)

    init() {
        super.init(style: .grouped)
        title = "AmneziaWG"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addTapped(_:)))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "日志", style: .plain, target: self, action: #selector(logTapped))
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func pulledToRefresh() {
        reload { [weak self] in self?.refreshControl?.endRefreshing() }
    }

    private func setBusy(_ value: Bool) {
        busy = value
        if value {
            spinner.startAnimating()
            navigationItem.titleView = spinner
        } else {
            spinner.stopAnimating()
            navigationItem.titleView = nil
        }
        tableView.reloadData()
    }

    private func reload(completion: (() -> Void)? = nil) {
        helperQueue.async {
            let list = runHelper(["list"])
            let status = runHelper(["status"])
            DispatchQueue.main.async {
                if list.status == 0 {
                    self.configs = list.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                }
                var active: String?
                for line in status.output.split(separator: "\n") where line.hasPrefix("config: ") {
                    active = String(line.dropFirst("config: ".count)).trimmingCharacters(in: .whitespaces)
                }
                self.activeConfig = (active?.isEmpty ?? true) ? nil : active
                let text = status.output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.statusText = text == "not running" ? "未连接" : text
                if !self.busy {
                    self.tableView.reloadData()
                }
                completion?()
            }
        }
    }

    private func showError(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? "状态" : "配置"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return section == 1 ? "打开开关即连接,同一时间只能连一个。左滑可删除配置。" : nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? 1 : max(configs.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        if indexPath.section == 0 {
            cell.textLabel?.text = statusText
            cell.textLabel?.numberOfLines = 0
            cell.textLabel?.font = UIFont(name: "Menlo", size: 13) ?? UIFont.systemFont(ofSize: 13)
            return cell
        }
        guard !configs.isEmpty else {
            cell.textLabel?.text = "还没有配置,点右上角 + 导入"
            cell.textLabel?.textColor = .gray
            return cell
        }
        let name = configs[indexPath.row]
        cell.textLabel?.text = name
        let toggle = UISwitch()
        toggle.isOn = name == activeConfig
        toggle.isEnabled = !busy
        toggle.tag = indexPath.row
        toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return indexPath.section == 1 && !configs.isEmpty && !busy
    }

    override func tableView(_ tableView: UITableView, titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        return "删除"
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.row < configs.count else { return }
        let name = configs[indexPath.row]
        let wasActive = name == activeConfig
        setBusy(true)
        helperQueue.async {
            if wasActive { _ = runHelper(["down"]) }
            let result = runHelper(["delete", name])
            DispatchQueue.main.async {
                self.setBusy(false)
                if result.status != 0 { self.showError("删除失败", result.output) }
                self.reload()
            }
        }
    }

    @objc private func toggleChanged(_ sender: UISwitch) {
        guard sender.tag < configs.count else { return }
        let name = configs[sender.tag]
        let turnOn = sender.isOn
        let previous = activeConfig
        setBusy(true)
        helperQueue.async {
            let result: CommandResult
            if turnOn {
                if previous != nil { _ = runHelper(["down"]) }
                result = runHelper(["up", name])
            } else {
                result = runHelper(["down"])
            }
            DispatchQueue.main.async {
                self.setBusy(false)
                if result.status != 0 {
                    self.showError(turnOn ? "连接失败" : "断开失败", result.output)
                }
                self.reload()
            }
        }
    }

    // MARK: Import

    @objc private func addTapped(_ sender: UIBarButtonItem) {
        let sheet = UIAlertController(title: "导入配置", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "从文件导入", style: .default) { _ in
            let picker = UIDocumentPickerViewController(documentTypes: ["public.data", "public.text", "public.item"], in: .import)
            picker.delegate = self
            self.present(picker, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "从剪贴板导入", style: .default) { _ in
            guard let text = UIPasteboard.general.string, !text.isEmpty else {
                self.showError("剪贴板为空", "请先复制 .conf 文件的全部内容。")
                return
            }
            self.askNameAndImport(Data(text.utf8), suggested: "tunnel")
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = sender
        present(sheet, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        guard let data = try? Data(contentsOf: url) else {
            showError("读取失败", "无法读取 \(url.lastPathComponent)")
            return
        }
        askNameAndImport(data, suggested: url.deletingPathExtension().lastPathComponent)
    }

    private func askNameAndImport(_ data: Data, suggested: String) {
        let alert = UIAlertController(title: "配置名称", message: "只能用字母、数字、_、-、.", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = sanitizedName(suggested)
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "导入", style: .default) { _ in
            let name = sanitizedName(alert.textFields?.first?.text ?? suggested)
            self.setBusy(true)
            self.helperQueue.async {
                let result = runHelper(["import", name], input: data)
                DispatchQueue.main.async {
                    self.setBusy(false)
                    if result.status != 0 { self.showError("导入失败", result.output) }
                    self.reload()
                }
            }
        })
        present(alert, animated: true)
    }

    // MARK: Log

    @objc private func logTapped() {
        navigationController?.pushViewController(LogViewController(), animated: true)
    }
}

final class LogViewController: UIViewController {
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "日志"
        view.backgroundColor = .white
        textView.isEditable = false
        textView.font = UIFont(name: "Menlo", size: 11) ?? UIFont.systemFont(ofSize: 11)
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(textView)
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(load))
        load()
    }

    @objc private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runHelper(["log"])
            DispatchQueue.main.async {
                self.textView.text = result.output
                let end = NSRange(location: max(result.output.utf16.count - 1, 0), length: 1)
                self.textView.scrollRangeToVisible(end)
            }
        }
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: MainViewController())
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
