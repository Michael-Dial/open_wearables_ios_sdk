import UIKit
@testable import OpenWearablesHealthSDK

/// Stands in for `UIApplication`'s background tasks: records which are live and expires
/// them on demand, the way iOS does when the time runs out.
final class FakeBackgroundAssertions: BackgroundAssertionProvider {

    private let lock = NSLock()
    private var nextId = 1
    private var live: [Int: (name: String, expiration: () -> Void)] = [:]
    private var begunNames: [String] = []

    /// Names of every assertion asked for, in order, including ones not granted.
    var begun: [String] {
        lock.lock()
        defer { lock.unlock() }
        return begunNames
    }

    /// When false, `begin` returns `.invalid`, as iOS does once an app has no time left.
    var grantsTime = true

    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        lock.lock()
        defer { lock.unlock() }
        begunNames.append(name)
        guard grantsTime else { return .invalid }
        let id = nextId
        nextId += 1
        live[id] = (name, expiration)
        return UIBackgroundTaskIdentifier(rawValue: id)
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        lock.lock()
        live.removeValue(forKey: identifier.rawValue)
        lock.unlock()
    }

    /// Names of the assertions begun and not yet ended.
    var liveNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return live.keys.sorted().compactMap { live[$0]?.name }
    }

    /// Runs every live assertion's expiration handler, as iOS does when time runs out.
    func expireAll() {
        lock.lock()
        let handlers = live.values.map { $0.expiration }
        lock.unlock()
        handlers.forEach { $0() }
    }
}
