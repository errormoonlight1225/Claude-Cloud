import LegacyCompat
import SPIndicator
import UIKit

extension UIViewController {
    /// A toast for a job that worked, the reason for one that did not.
    func report(
        _ outcome: OperationMonitor.Outcome,
        succeeded: LegacyLocalizationValue,
        failed: LegacyLocalizationValue
    ) {
        switch outcome {
        case .succeeded:
            SPIndicator.present(title: String(resolving: succeeded), preset: .done)
        case let .failed(reason):
            presentNotice(title: failed, message: reason)
        }
    }
}
