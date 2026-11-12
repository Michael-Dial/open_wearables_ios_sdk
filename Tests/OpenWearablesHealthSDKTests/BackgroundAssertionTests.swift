import XCTest
@testable import OpenWearablesHealthSDK

/// Covers who holds the background time a sync runs on. Every HealthKit delivery used to
/// share one task identifier, and the first piece of work to finish ended it: a delivery
/// that found a sync already running ended the time that sync was using, iOS suspended
/// the app mid-run, and the data waited until the app was next opened.
final class BackgroundAssertionTests: XCTestCase {

    // MARK: - BackgroundAssertion

    func testEndingTwiceEndsTheTaskOnce() {
        let provider = FakeBackgroundAssertions()
        let assertion = BackgroundAssertion(name: "work", provider: provider)
        XCTAssertTrue(assertion.isValid)
        XCTAssertEqual(provider.liveNames, ["work"])

        assertion.end()
        assertion.end()

        XCTAssertEqual(provider.liveNames, [])
        XCTAssertFalse(assertion.isValid)
    }

    /// iOS kills an app that does not end a task in its expiration handler.
    func testExpirationRunsTheHandlerAndEndsTheTask() {
        let provider = FakeBackgroundAssertions()
        var expired = 0
        let assertion = BackgroundAssertion(name: "work", provider: provider) { expired += 1 }

        provider.expireAll()
        assertion.end()

        XCTAssertEqual(expired, 1)
        XCTAssertEqual(provider.liveNames, [])
    }

    func testNoTimeGrantedIsReportedAsInvalid() {
        let provider = FakeBackgroundAssertions()
        provider.grantsTime = false

        let assertion = BackgroundAssertion(name: "work", provider: provider)

        XCTAssertFalse(assertion.isValid)
        assertion.end()
    }

    // MARK: - Sync runs

    func testARunHoldsItsOwnAssertionUntilItEnds() {
        withIsolatedSDK { sdk, _ in
            let provider = FakeBackgroundAssertions()
            sdk.backgroundAssertions = provider
            let previousTypes = sdk.trackedTypes
            defer { sdk.trackedTypes = previousTypes }
            sdk.trackedTypes = []

            var finished = false
            sdk.collectAllData(fullExport: false, isBackground: false, trigger: .healthKitObserver) {
                finished = true
            }

            XCTAssertTrue(finished, "with no tracked types the run ends before any HealthKit read")
            XCTAssertEqual(provider.begun, ["health_sync_run"])
            XCTAssertEqual(provider.liveNames, [], "the run ends its assertion when it ends")
        }
    }

    /// A BGTask keeps the process alive itself and has its own expiration handler.
    func testABackgroundTaskRunTakesNoAssertion() {
        withIsolatedSDK { sdk, _ in
            let provider = FakeBackgroundAssertions()
            sdk.backgroundAssertions = provider
            let previousTypes = sdk.trackedTypes
            defer { sdk.trackedTypes = previousTypes }
            sdk.trackedTypes = []

            sdk.collectAllData(fullExport: false, isBackground: true, trigger: .processing) {}

            XCTAssertEqual(provider.begun, [])
        }
    }

    /// The regression: a HealthKit delivery arriving while a sync runs must not end the
    /// time that sync is running on.
    func testADeliveryDuringARunLeavesTheRunsTimeAlone() {
        withIsolatedSDK { sdk, _ in
            let provider = FakeBackgroundAssertions()
            sdk.backgroundAssertions = provider
            let previousTypes = sdk.trackedTypes
            defer { sdk.trackedTypes = previousTypes }
            sdk.trackedTypes = sdk.mapTypes([.heartRate])
            sdk.isInitialSyncInProgress = false

            guard let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not claim the sync slot")
            }
            let liveRun = BackgroundAssertion(name: "health_sync_run", provider: provider)
            defer {
                liveRun.end()
                sdk.finishSync(generation: generation)
            }

            sdk.triggerCombinedSync()

            XCTAssertTrue(
                waitUntil {
                    provider.begun.contains("health_sync_debounce")
                        && provider.liveNames == ["health_sync_run"]
                },
                "the delivery ends only its own debounce assertion; got \(provider.liveNames)"
            )
            XCTAssertFalse(sdk.isSyncCancelled(generation: generation))
        }
    }

    /// When the time does run out, the run stops rather than freezing with the slot held,
    /// so the next wake's run can start.
    func testRunningOutOfTimeStopsTheRunAndStartsTheTakeoverClock() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not claim the sync slot")
            }
            defer { sdk.finishSync(generation: generation) }

            sdk.runOutOfBackgroundTime(generation: generation)

            XCTAssertTrue(sdk.isSyncCancelled(generation: generation))
            XCTAssertTrue(sdk.isSyncInProgress, "the slot is released when the run unwinds")
            XCTAssertFalse(sdk.isSyncingVisible, "a cancel time is set, so a wedged run can be taken over")
        }
    }

    func testAnOlderRunsExpiryLeavesTheLiveRunAlone() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not claim the sync slot")
            }
            defer { sdk.finishSync(generation: generation) }

            sdk.runOutOfBackgroundTime(generation: generation - 1)

            XCTAssertFalse(sdk.isSyncCancelled(generation: generation))
            XCTAssertTrue(sdk.isSyncingVisible)
        }
    }
}
