import Foundation
import UIKit

/// Begins and ends `UIApplication` background tasks. A seam so tests can count the
/// assertions a sync holds and expire them on demand.
internal protocol BackgroundAssertionProvider: AnyObject {
    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ identifier: UIBackgroundTaskIdentifier)
}

internal final class UIApplicationBackgroundAssertions: BackgroundAssertionProvider {
    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

/// One background task, owned by one holder and ended exactly once, by the holder or by
/// expiration, whichever comes first.
///
/// Each holder gets its own. A single shared identifier let whoever finished first end
/// the time another piece of work was still running on: a HealthKit delivery that found
/// a sync already running ended the assertion that sync depended on, and iOS suspended
/// the app mid-run until it was next opened.
internal final class BackgroundAssertion {
    private let lock = NSLock()
    private let provider: BackgroundAssertionProvider
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var ended = false

    /// `onExpiration` runs before the task is ended, while the process still has time.
    init(name: String, provider: BackgroundAssertionProvider, onExpiration: @escaping () -> Void = {}) {
        self.provider = provider
        let id = provider.begin(name: name) { [self] in
            onExpiration()
            end()
        }
        lock.lock()
        if ended {
            // Expired before `begin` returned: the identifier was never stored, so end it here.
            lock.unlock()
            if id != .invalid { provider.end(id) }
            return
        }
        identifier = id
        lock.unlock()
    }

    /// False when iOS granted no background time (the app has none left).
    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return identifier != .invalid
    }

    func end() {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        let id = identifier
        identifier = .invalid
        lock.unlock()
        if id != .invalid { provider.end(id) }
    }
}
