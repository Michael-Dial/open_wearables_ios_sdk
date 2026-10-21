import XCTest
@testable import OpenWearablesHealthSDK

/// What coming back to the foreground starts. Reopening a suspended app used to sync
/// nothing unless a run had been interrupted, so new data waited for a manual stop and
/// start of sync.
final class LifecycleTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func foreground(
        syncActive: Bool = true,
        hasAuth: Bool = true,
        inProgress: Bool = false,
        resumable: Bool = false,
        lastSyncSecondsAgo: TimeInterval? = nil
    ) -> OpenWearablesHealthSDK.ForegroundSync {
        OpenWearablesHealthSDK.foregroundSync(
            syncActive: syncActive,
            hasAuth: hasAuth,
            inProgress: inProgress,
            resumable: resumable,
            lastForegroundSyncAt: lastSyncSecondsAgo.map { now.addingTimeInterval(-$0) },
            now: now
        )
    }

    /// The case that needed a manual stop and start: nothing interrupted, new data waiting.
    func testOpeningTheAppSyncsNewDataWhenNothingWasInterrupted() {
        XCTAssertEqual(foreground(), .incremental)
        XCTAssertEqual(foreground(lastSyncSecondsAgo: OpenWearablesHealthSDK.foregroundSyncInterval + 1), .incremental)
    }

    func testSwitchingBackQuicklyDoesNotSyncAgain() {
        XCTAssertEqual(foreground(lastSyncSecondsAgo: 30), .skip)
    }

    func testAnInterruptedRunResumesWhateverTheInterval() {
        XCTAssertEqual(foreground(resumable: true, lastSyncSecondsAgo: 5), .resume)
    }

    func testNothingStartsWhileARunIsGoingOrWithoutAnActiveSignedInSync() {
        XCTAssertEqual(foreground(inProgress: true), .skip)
        XCTAssertEqual(foreground(syncActive: false), .skip)
        XCTAssertEqual(foreground(hasAuth: false), .skip)
    }
}
