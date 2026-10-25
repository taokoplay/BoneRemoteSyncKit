/// Internal synchronous failure points. Never part of the public transfer API.
enum DAVRecoveryTestPhase: Sendable {
    case partSynced, beforeCheckpointRename, readyCommitted, beforeInstall, installedBeforeCleanup
}
struct DAVRecoveryTestHooks: Sendable {
    var onPhase: (@Sendable (DAVRecoveryTestPhase) throws -> Void)?
    static let none = DAVRecoveryTestHooks()
    func call(_ phase: DAVRecoveryTestPhase) throws { try onPhase?(phase) }
}
