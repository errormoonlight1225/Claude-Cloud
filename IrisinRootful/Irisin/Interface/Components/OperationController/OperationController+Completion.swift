import LegacyCompat
import AlertController
import UIKit

extension OperationController {
    /// The page's menu, at the leading edge for as long as the page lives.
    /// Built as it opens: the home screen work joins the log only once the
    /// operation has ended.
    func menuItem() -> UIBarButtonItem {
        let more = UIBarButtonItem(
            image: UIImage.compatSystemImage("ellipsis"),
            menu: LegacyMenu(children: [
                LegacyDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.menuElements() ?? [])
                },
            ])
        )
        more.accessibilityLabel = String(legacyLocalized: "More")
        return more
    }

    private func menuElements() -> [LegacyMenuElement] {
        let log = LegacyAction(title: String(legacyLocalized: "View Full Log"), image: UIImage.compatSystemImage("scroll")) { [weak self] _ in
            guard let self, let monitor else { return }
            navigationController?.pushViewController(OperationLogController(monitor: monitor), animated: true)
        }
        guard let monitor else { return [log] }
        if monitor.outcome?.succeeded == false, !isRecoveryMode {
            let ignore = LegacyAction(
                title: String(legacyLocalized: "Ignore Script Errors and Retry"),
                image: UIImage.compatSystemImage("exclamationmark.shield"),
                attributes: retrying ? .disabled : []
            ) { [weak self] _ in
                self?.retryIgnoringScriptFailures()
            }
            return [log, LegacyMenu(options: .displayInline, children: [ignore])]
        }
        // home screen work follows an install that happened, not one that is running or did not
        guard monitor.outcome?.succeeded == true, !monitor.requiresExit else { return [log] }
        return [
            log,
            LegacyMenu(options: .displayInline, children: [
                LegacyAction(
                    title: String(legacyLocalized: "Rebuild Icons"),
                    image: UIImage.compatSystemImage("square.grid.2x2")
                ) { [weak self] _ in self?.rebuildIcons() },
                LegacyAction(
                    title: String(legacyLocalized: "Reload Home Screen"),
                    image: UIImage.compatSystemImage("arrow.clockwise")
                ) { [weak self] _ in self?.reloadHomeScreen() },
            ]),
        ]
    }

    func finishOperation(succeeded: Bool, ending: OperationMonitor.Ending) {
        // the status row says how it went; this button only says what it does
        let button = switch ending {
        case .reloadHomeScreen:
            reloadButton()
        case .close, .updateApp:
            UIBarButtonItem(
                image: UIImage.compatSystemImage("checkmark"),
                primaryAction: LegacyAction { [weak self] _ in
                    guard let self else { return }
                    if ending == .updateApp {
                        exitForUpgrade()
                    } else {
                        dismiss(animated: true)
                    }
                }
            ).then { $0.accessibilityLabel = String(legacyLocalized: "Done") }
        }
        button.style = .done
        // Try Again tapped before the button came holds it too (`retrying`)
        button.isEnabled = !retrying
        button.accessibilityValue = succeeded
            ? String(legacyLocalized: "Operation completed.")
            : String(legacyLocalized: "Operation failed. Try again.")
        navigationItem.rightBarButtonItems = [button]
    }

    /// The tweaks changed: a tap reloads the home screen, and touching and
    /// holding offers to close the page without it.
    private func reloadButton() -> UIBarButtonItem {
        let reason = String(legacyLocalized: "Changed tweaks take effect after the home screen reloads.")
        let button = UIBarButtonItem(
            title: String(localized: "Reload Home Screen"),
            image: nil,
            primaryAction: LegacyAction { [weak self] _ in self?.reloadHomeScreen() },
            menu: LegacyMenu(title: reason, children: [
                LegacyAction(
                    title: String(localized: "Skip for Now"),
                    image: UIImage.compatSystemImage("xmark")
                ) { [weak self] _ in self?.dismiss(animated: true) },
            ])
        )
        button.accessibilityHint = reason
        return button
    }

    /// The page closes, then the home screen restarts and this app with it.
    private func reloadHomeScreen() {
        dismiss(animated: true) {
            UIApplication.prepareForExitAndSuspend()
            LegacyTask.detached { PrivilegedBackend.run(.respring) }
        }
    }

    private func rebuildIcons() {
        let progress = progressAlert(
            title: "Rebuilding Icons…",
            message: "Rebuilding home screen icons will take some time."
        )
        present(progress, animated: true) { [weak self] in
            LegacyTask.detached { [weak self] in
                let outcome = PrivilegedBackend.runMaintenance(.rebuildIconCache)
                progress.dismiss(animated: true) {
                    self?.report(outcome, succeeded: "Icons rebuilt", failed: "Unable to Rebuild Icons")
                }
            }
        }
    }

    private func exitForUpgrade() {
        OwnRegistration.finishUpdate(
            from: self,
            registering: monitor?.operation.transaction.installsSelf ?? false
        )
    }
}
