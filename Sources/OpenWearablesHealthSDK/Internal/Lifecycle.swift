import Foundation

/// What coming back to the foreground starts. A pure decision, so it can be tested
/// without launching an app.
extension OpenWearablesHealthSDK {

    internal enum ForegroundSync: Equatable {
        /// Nothing starts.
        case skip
        /// An interrupted run, or an initial export that never finished, continues.
        case resume
        /// Pick up whatever HealthKit gained while the app was away.
        case incremental
    }

    /// The shortest gap between two incremental syncs started by the app coming to
    /// the foreground. Switching apps back and forth must not re-query every type each
    /// time; a resume is never held back by it.
    internal static let foregroundSyncInterval: TimeInterval = 120

    internal static func foregroundSync(
        syncActive: Bool,
        hasAuth: Bool,
        inProgress: Bool,
        resumable: Bool,
        lastForegroundSyncAt: Date?,
        now: Date
    ) -> ForegroundSync {
        guard syncActive, hasAuth, !inProgress else { return .skip }
        if resumable { return .resume }
        if let last = lastForegroundSyncAt, now.timeIntervalSince(last) < foregroundSyncInterval {
            return .skip
        }
        return .incremental
    }
}
