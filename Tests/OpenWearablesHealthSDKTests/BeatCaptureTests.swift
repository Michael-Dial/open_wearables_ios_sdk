import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Beat-to-beat capture: turning a heartbeat series into interval records, deciding which
/// spans a participant's mode covers, and the two backend calls around a beat pass.
final class BeatCaptureTests: XCTestCase {

    private let seriesStart = Date(timeIntervalSince1970: 1_791_000_000) // 2026-10-03T04:00:00Z
    private let source: [String: Any] = ["name": "Test Apple Watch", "deviceModel": "Watch8,1"]

    private func date(_ iso: String) -> Date {
        BeatCaptureConfig.parseDate(iso)!
    }

    // MARK: - Records

    func testEachBeatAfterTheFirstBecomesAnIntervalRecord() {
        let beats = [
            BeatCapture.Beat(timeSinceStart: 0.0, precededByGap: false),
            BeatCapture.Beat(timeSinceStart: 0.85, precededByGap: false),
            BeatCapture.Beat(timeSinceStart: 1.7, precededByGap: false),
            BeatCapture.Beat(timeSinceStart: 8.2, precededByGap: true),
        ]

        let records = BeatCapture.records(
            seriesId: "S1", seriesStart: seriesStart, beats: beats, source: source,
            zoneOffset: "-04:00", formatter: BeatCapture.secondFormatter()
        )

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map { $0["id"] as? String }, ["S1:1", "S1:2", "S1:3"])
        XCTAssertEqual(records.map { $0["value"] as? Double }, [850, 850, 6500])
        XCTAssertEqual(records.compactMap { $0["type"] as? String }, Array(repeating: HKDataTypeIdentifierHeartbeatSeries, count: 3))
        XCTAssertEqual(records.map { $0["unit"] as? String }, ["ms", "ms", "ms"])
        let flags = records.map { ($0["metadata"] as? [String: Any])?["precededByGap"] as? Bool }
        XCTAssertEqual(flags, [false, false, true])
        let indexes = records.map { ($0["metadata"] as? [String: Any])?["beatIndex"] as? Int }
        XCTAssertEqual(indexes, [1, 2, 3])
    }

    /// Above 60 bpm two beats share a second, so the timestamp has to carry milliseconds.
    func testBeatTimesCarryMilliseconds() {
        let beats = [
            BeatCapture.Beat(timeSinceStart: 0.0, precededByGap: false),
            BeatCapture.Beat(timeSinceStart: 0.25, precededByGap: false),
            BeatCapture.Beat(timeSinceStart: 0.9, precededByGap: false),
            BeatCapture.Beat(timeSinceStart: 1.75, precededByGap: false),
        ]

        let records = BeatCapture.records(
            seriesId: "S1", seriesStart: seriesStart, beats: beats, source: source,
            zoneOffset: NSNull(), formatter: BeatCapture.secondFormatter()
        )

        let times = records.compactMap { $0["startDate"] as? String }
        XCTAssertEqual(times, ["2026-10-03T04:00:00.250Z", "2026-10-03T04:00:00.900Z", "2026-10-03T04:00:01.750Z"])
        XCTAssertEqual(records.map { $0["startDate"] as? String }, records.map { $0["endDate"] as? String })
    }

    func testSeriesWithFewerThanTwoBeatsHasNoIntervals() {
        let one = [BeatCapture.Beat(timeSinceStart: 0.4, precededByGap: false)]

        XCTAssertTrue(BeatCapture.records(
            seriesId: "S1", seriesStart: seriesStart, beats: one, source: source,
            zoneOffset: NSNull(), formatter: BeatCapture.secondFormatter()
        ).isEmpty)
    }

    func testNonPositiveIntervalIsDropped() {
        let beats = [
            BeatCapture.Beat(timeSinceStart: 1.0, precededByGap: false),
            BeatCapture.Beat(timeSinceStart: 1.0, precededByGap: false),
            BeatCapture.Beat(timeSinceStart: 1.8, precededByGap: false),
        ]

        let records = BeatCapture.records(
            seriesId: "S1", seriesStart: seriesStart, beats: beats, source: source,
            zoneOffset: NSNull(), formatter: BeatCapture.secondFormatter()
        )

        XCTAssertEqual(records.map { $0["id"] as? String }, ["S1:2"])
        XCTAssertEqual(records.first?["value"] as? Double, 800)
    }

    // MARK: - Windows

    func testSleepSamplesOfOneNightBecomeOnePaddedWindow() {
        let samples = [
            DateInterval(start: date("2026-10-11T03:00:00Z"), end: date("2026-10-11T03:30:00Z")),
            DateInterval(start: date("2026-10-11T03:40:00Z"), end: date("2026-10-11T06:00:00Z")),
            DateInterval(start: date("2026-10-11T06:10:00Z"), end: date("2026-10-11T10:30:00Z")),
        ]

        let windows = BeatCapture.sleepWindows(from: samples, paddingMinutes: 30)

        XCTAssertEqual(windows, [DateInterval(start: date("2026-10-11T02:30:00Z"), end: date("2026-10-11T11:00:00Z"))])
    }

    func testTwoNightsStayApart() {
        let samples = [
            DateInterval(start: date("2026-10-10T03:00:00Z"), end: date("2026-10-10T10:00:00Z")),
            DateInterval(start: date("2026-10-11T03:00:00Z"), end: date("2026-10-11T10:00:00Z")),
        ]

        XCTAssertEqual(BeatCapture.sleepWindows(from: samples, paddingMinutes: 30).count, 2)
    }

    func testAutomaticWindowsFollowTheMode() {
        let now = date("2026-10-13T12:00:00Z")
        let night = DateInterval(start: date("2026-10-13T03:00:00Z"), end: date("2026-10-13T10:00:00Z"))
        let oldNight = DateInterval(start: date("2026-09-01T03:00:00Z"), end: date("2026-09-01T10:00:00Z"))

        let off = BeatCaptureConfig(mode: .off, lookbackDays: 3, sleepPaddingMinutes: 0, windows: [])
        let allDay = BeatCaptureConfig(mode: .allDay, lookbackDays: 3, sleepPaddingMinutes: 0, windows: [])
        let sleep = BeatCaptureConfig(mode: .sleep, lookbackDays: 3, sleepPaddingMinutes: 0, windows: [])

        XCTAssertEqual(BeatCapture.automaticWindows(config: off, now: now, sleepSamples: [night]), [])
        XCTAssertEqual(
            BeatCapture.automaticWindows(config: allDay, now: now, sleepSamples: []),
            [DateInterval(start: date("2026-10-10T12:00:00Z"), end: now)]
        )
        XCTAssertEqual(BeatCapture.automaticWindows(config: sleep, now: now, sleepSamples: [oldNight, night]), [night])
    }

    func testPruneForgetsSeriesPastTheCutoff() {
        let cutoff = date("2026-10-01T00:00:00Z")
        let uploaded = [
            "old": date("2026-09-20T00:00:00Z").timeIntervalSince1970,
            "recent": date("2026-10-05T00:00:00Z").timeIntervalSince1970,
        ]

        XCTAssertEqual(Array(BeatCapture.prune(uploaded, olderThan: cutoff).keys), ["recent"])
    }

    // MARK: - Instructions

    func testConfigParsesModesWindowsAndBothDateForms() {
        let json: [String: Any] = [
            "mode": "all_day",
            "lookback_days": 14,
            "sleep_padding_minutes": 15,
            "windows": [
                ["id": "w1", "start_at": "2026-10-12T02:00:00Z", "end_at": "2026-10-12T10:00:00.500000Z"],
                ["id": "bad", "start_at": "2026-10-12T10:00:00Z", "end_at": "2026-10-12T09:00:00Z"],
            ],
        ]

        let config = BeatCaptureConfig(json: json)

        XCTAssertEqual(config?.mode, .allDay)
        XCTAssertEqual(config?.lookbackDays, 14)
        XCTAssertEqual(config?.sleepPaddingMinutes, 15)
        XCTAssertEqual(config?.windows.map(\.id), ["w1"])
        XCTAssertEqual(config?.windows.first?.end.timeIntervalSince(date("2026-10-12T10:00:00Z")) ?? 0, 0.5, accuracy: 0.001)
    }

    func testUnknownModeIsRejectedAndLookbackIsClamped() {
        XCTAssertNil(BeatCaptureConfig(json: ["mode": "sometimes"]))
        XCTAssertEqual(BeatCaptureConfig(json: ["mode": "sleep", "lookback_days": 400])?.lookbackDays, 30)
    }

    // MARK: - Type routing

    func testHeartbeatSeriesIsAuthorizedButNotInTheRegularLoop() {
        let sdk = OpenWearablesHealthSDK.shared
        let previous = sdk.trackedTypes
        defer { sdk.trackedTypes = previous }

        sdk.trackedTypes = sdk.mapTypes([.heartRate, .heartbeatSeries])

        XCTAssertTrue(sdk.isBeatCaptureTracked)
        XCTAssertEqual(
            Set(sdk.getAuthorizationTypes().map(\.identifier)),
            [HKQuantityTypeIdentifier.heartRate.rawValue, HKDataTypeIdentifierHeartbeatSeries]
        )
        XCTAssertEqual(sdk.getQueryableTypes().map(\.identifier), [HKQuantityTypeIdentifier.heartRate.rawValue])
    }

    // MARK: - Backend calls

    func testInstructionsAreFetchedAndTheModeIsRemembered() {
        withIsolatedSDK { sdk, _ in
            defer { sdk.clearBeatCaptureState() }
            StubURLProtocol.install { _ in
                .status(200, #"{"mode":"sleep","lookback_days":5,"sleep_padding_minutes":20,"windows":[{"id":"w1","start_at":"2026-10-12T02:00:00Z","end_at":"2026-10-12T10:00:00Z"}]}"#)
            }

            var fetched: BeatCaptureConfig?
            sdk.fetchBeatCaptureConfig { fetched = $0 }
            waitUntil { fetched != nil }

            XCTAssertEqual(fetched?.mode, .sleep)
            XCTAssertEqual(fetched?.windows.map(\.id), ["w1"])
            let request = StubURLProtocol.requests(matching: "/beat-capture").first
            XCTAssertEqual(request?.httpMethod, "GET")
            XCTAssertEqual(request?.url?.path, "/api/v1/sdk/users/test-user/beat-capture")
            XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")

            // A failed fetch keeps the last known mode but never the windows.
            StubURLProtocol.install { _ in .status(503) }
            var fallback: BeatCaptureConfig?
            sdk.fetchBeatCaptureConfig { fallback = $0 }
            waitUntil { fallback != nil }

            XCTAssertEqual(fallback?.mode, .sleep)
            XCTAssertEqual(fallback?.lookbackDays, 5)
            XCTAssertEqual(fallback?.windows, [])
        }
    }

    /// A backend that predates beat capture answers 404: the phone collects nothing.
    func testNoInstructionsMeansNothingIsCollected() {
        withIsolatedSDK { sdk, _ in
            defer { sdk.clearBeatCaptureState() }
            sdk.clearBeatCaptureState()
            StubURLProtocol.install { _ in .status(404) }

            var fetched: BeatCaptureConfig?
            sdk.fetchBeatCaptureConfig { fetched = $0 }
            waitUntil { fetched != nil }

            XCTAssertEqual(fetched, .inactive)
        }
    }

    func testFulfilledWindowIsReportedWithItsCounts() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(200) }

            var reported: Bool?
            sdk.reportBeatWindowFulfilled(windowId: "w1", beats: 5400, series: 90) { reported = $0 }
            waitUntil { reported != nil }

            XCTAssertEqual(reported, true)
            let call = StubURLProtocol.recorded(matching: "/fulfilled").first
            XCTAssertEqual(call?.request.httpMethod, "POST")
            XCTAssertEqual(call?.request.url?.path, "/api/v1/sdk/users/test-user/beat-capture/windows/w1/fulfilled")
            XCTAssertEqual(call?.json?["beats"] as? Int, 5400)
            XCTAssertEqual(call?.json?["series"] as? Int, 90)
        }
    }
}
