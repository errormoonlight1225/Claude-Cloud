import IrisinProtocol

extension PrivilegedBackend {
    /// Runs one maintenance job (rebuild icons, respring) and keeps the last
    /// failure it reported, for a screen that started it and owes the user
    /// an answer.
    static nonisolated func runMaintenance(_ job: InstallerJob) -> OperationMonitor.Outcome {
        var problem: InstallerEvent.Problem?
        let status = run(job) { @MainActor event in
            if case let .failure(reported) = event {
                problem = reported
            }
        }
        return .init(status: status, failure: problem)
    }
}
