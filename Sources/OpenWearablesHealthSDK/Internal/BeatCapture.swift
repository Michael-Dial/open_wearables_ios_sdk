import Foundation
import HealthKit

// MARK: - Server instructions

/// What the backend wants collected from this phone's Apple Watch heartbeat series.
///
/// Read from `GET /sdk/users/{id}/beat-capture` before every beat pass. A researcher sets
/// the mode per participant; the phone only carries it out:
/// - `off`: nothing automatic. Requested windows are still uploaded.
/// - `sleep`: heartbeat series overlapping a HealthKit sleep session, padded either side.
/// - `allDay`: every heartbeat series.
internal struct BeatCaptureConfig: Equatable {
    enum Mode: String {
        case off
        case sleep
        case allDay = "all_day"
    }

    /// A span a researcher asked for, uploaded whatever the mode.
    struct Window: Equatable {
        let id: String
        let start: Date
        let end: Date
    }

    let mode: Mode
    let lookbackDays: Int
    let sleepPaddingMinutes: Int
    let windows: [Window]

    /// What the phone does before the backend has ever answered, or when the backend
    /// predates beat capture: nothing.
    static let inactive = BeatCaptureConfig(mode: .off, lookbackDays: 7, sleepPaddingMinutes: 30, windows: [])

    /// The same settings without the windows: what a failed fetch falls back to. A
    /// window is only worked on while the backend can be told it is done.
    var withoutWindows: BeatCaptureConfig {
        BeatCaptureConfig(mode: mode, lookbackDays: lookbackDays, sleepPaddingMinutes: sleepPaddingMinutes, windows: [])
    }
}

extension BeatCaptureConfig {
    /// Parses the backend's JSON. Nil when the mode is missing or unknown.
    init?(json: [String: Any]) {
        guard let rawMode = json["mode"] as? String, let mode = Mode(rawValue: rawMode) else { return nil }
        let lookback = (json["lookback_days"] as? Int) ?? 7
        let padding = (json["sleep_padding_minutes"] as? Int) ?? 30
        var windows: [Window] = []
        for raw in (json["windows"] as? [[String: Any]]) ?? [] {
            guard let id = raw["id"] as? String,
                  let start = (raw["start_at"] as? String).flatMap(BeatCaptureConfig.parseDate),
                  let end = (raw["end_at"] as? String).flatMap(BeatCaptureConfig.parseDate),
                  end > start else { continue }
            windows.append(Window(id: id, start: start, end: end))
        }
        self.init(
            mode: mode,
            lookbackDays: min(max(lookback, 1), 30),
            sleepPaddingMinutes: min(max(padding, 0), 240),
            windows: windows
        )
    }

    /// ISO 8601 with or without fractional seconds, as the backend may send either.
    static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: value)
    }
}

// MARK: - Pure helpers

/// The parts of beat capture that do not touch HealthKit or the network.
internal enum BeatCapture {

    /// One beat as `HKHeartbeatSeriesQuery` reports it.
    struct Beat: Equatable {
        let timeSinceStart: TimeInterval
        let precededByGap: Bool
    }

    static var heartbeatTypeIdentifier: String { HKDataTypeIdentifierHeartbeatSeries }

    /// Gaps shorter than this between sleep samples belong to the same night.
    static let sleepJoiningGap: TimeInterval = 60 * 60

    /// Whole-second UTC formatter that `timestamp` appends milliseconds to.
    static func secondFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    /// `2026-10-03T04:00:00.250Z`: the instant rounded to the nearest millisecond.
    ///
    /// Beat times need milliseconds (above 60 bpm two beats regularly share a second), and
    /// they are built from integer milliseconds rather than by asking a formatter for
    /// fractional seconds, which renders 0.9 s as ".899" when the Double sits just below it.
    static func timestamp(_ date: Date, formatter: ISO8601DateFormatter) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = Int64((Double(millis) / 1000).rounded(.down))
        let fraction = millis - seconds * 1000
        let whole = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        return String(whole.dropLast()) + String(format: ".%03lldZ", fraction)
    }

    /// One sync record per beat after the first: the interval in ms since the previous
    /// beat, stamped with the beat's own time.
    ///
    /// The first beat has no interval and gets no record; its time is still recoverable as
    /// the second beat's time minus its interval. An interval that spans a gap is kept
    /// and flagged `precededByGap`, so every beat time survives and an analysis decides
    /// what to exclude. A non-positive interval cannot be a beat and is dropped.
    static func records(
        seriesId: String,
        seriesStart: Date,
        beats: [Beat],
        source: [String: Any],
        zoneOffset: Any,
        formatter: ISO8601DateFormatter
    ) -> [[String: Any]] {
        guard beats.count >= 2 else { return [] }
        var records: [[String: Any]] = []
        records.reserveCapacity(beats.count - 1)
        for index in 1..<beats.count {
            let beat = beats[index]
            let intervalMs = (beat.timeSinceStart - beats[index - 1].timeSinceStart) * 1000
            guard intervalMs > 0 else { continue }
            let at = timestamp(seriesStart.addingTimeInterval(beat.timeSinceStart), formatter: formatter)
            records.append([
                "id": "\(seriesId):\(index)",
                "type": heartbeatTypeIdentifier,
                "startDate": at,
                "endDate": at,
                "zoneOffset": zoneOffset,
                "source": source,
                "value": (intervalMs * 1000).rounded() / 1000,
                "unit": "ms",
                "parentId": NSNull(),
                "metadata": [
                    "seriesId": seriesId,
                    "beatIndex": index,
                    "precededByGap": beat.precededByGap
                ] as [String: Any]
            ])
        }
        return records
    }

    /// Sorts and merges intervals that overlap or sit within `joiningGap` of each other.
    static func mergeIntervals(_ intervals: [DateInterval], joiningGap: TimeInterval) -> [DateInterval] {
        var merged: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end.addingTimeInterval(joiningGap) {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// Nights from HealthKit sleep samples (any stage, any source), padded either side.
    static func sleepWindows(from samples: [DateInterval], paddingMinutes: Int) -> [DateInterval] {
        let padding = TimeInterval(paddingMinutes * 60)
        let nights = mergeIntervals(samples, joiningGap: sleepJoiningGap)
        let padded = nights.map {
            DateInterval(start: $0.start.addingTimeInterval(-padding), end: $0.end.addingTimeInterval(padding))
        }
        return mergeIntervals(padded, joiningGap: 0)
    }

    /// Earliest instant the automatic modes reach back to.
    static func lookbackStart(config: BeatCaptureConfig, now: Date) -> Date {
        now.addingTimeInterval(-TimeInterval(config.lookbackDays) * 24 * 60 * 60)
    }

    /// The spans the participant's mode covers, not counting requested windows.
    static func automaticWindows(config: BeatCaptureConfig, now: Date, sleepSamples: [DateInterval]) -> [DateInterval] {
        let start = lookbackStart(config: config, now: now)
        switch config.mode {
        case .off:
            return []
        case .allDay:
            return [DateInterval(start: start, end: now)]
        case .sleep:
            return sleepWindows(from: sleepSamples, paddingMinutes: config.sleepPaddingMinutes)
                .filter { $0.end > start }
        }
    }

    /// Drops uploaded-series entries that ended before `cutoff`. Past it the automatic
    /// modes no longer look, so remembering them only costs storage.
    static func prune(_ uploaded: [String: Double], olderThan cutoff: Date) -> [String: Double] {
        let limit = cutoff.timeIntervalSince1970
        return uploaded.filter { $0.value >= limit }
    }
}

// MARK: - Beat pass

/// Collects the beats one `HKHeartbeatSeriesQuery` reports and finishes exactly once.
private final class BeatAccumulator {
    private let lock = NSLock()
    private var collected: [BeatCapture.Beat] = []
    private var finished = false

    func append(_ beat: BeatCapture.Beat) {
        lock.lock()
        collected.append(beat)
        lock.unlock()
    }

    /// Runs `body` with the beats on the first call only.
    func finish(_ body: ([BeatCapture.Beat]) -> Void) {
        lock.lock()
        let first = !finished
        finished = true
        let beats = collected
        lock.unlock()
        if first { body(beats) }
    }
}

/// State one beat pass carries through its callbacks.
private final class BeatPass {
    let generation: Int
    let isBackground: Bool
    let endpoint: URL
    let formatter = BeatCapture.secondFormatter()
    /// Series uuid -> end date (seconds since 1970) of every series already uploaded.
    var uploaded: [String: Double]
    var recordsSent = 0
    var seriesSent = 0

    init(generation: Int, isBackground: Bool, endpoint: URL, uploaded: [String: Double]) {
        self.generation = generation
        self.isBackground = isBackground
        self.endpoint = endpoint
        self.uploaded = uploaded
    }
}

extension OpenWearablesHealthSDK {

    // MARK: Endpoints

    internal var beatCaptureEndpoint: URL? {
        guard let userId = userId, let base = apiBaseUrl else { return nil }
        return URL(string: "\(base)/sdk/users/\(userId)/beat-capture")
    }

    internal func beatWindowFulfilledEndpoint(windowId: String) -> URL? {
        guard let userId = userId, let base = apiBaseUrl else { return nil }
        return URL(string: "\(base)/sdk/users/\(userId)/beat-capture/windows/\(windowId)/fulfilled")
    }

    /// Beat capture runs only for apps that asked for `.heartbeatSeries`.
    internal var isBeatCaptureTracked: Bool {
        trackedTypes.contains { $0.identifier == BeatCapture.heartbeatTypeIdentifier }
    }

    // MARK: Persisted state (per user)

    private func beatConfigKey() -> String { "beats.config.\(userKey())" }
    private func beatUploadedKey() -> String { "beats.uploaded.\(userKey())" }

    internal func loadCachedBeatConfig() -> BeatCaptureConfig {
        guard let stored = defaults.dictionary(forKey: beatConfigKey()),
              let config = BeatCaptureConfig(json: stored) else {
            return .inactive
        }
        return config.withoutWindows
    }

    internal func saveCachedBeatConfig(_ config: BeatCaptureConfig) {
        defaults.set([
            "mode": config.mode.rawValue,
            "lookback_days": config.lookbackDays,
            "sleep_padding_minutes": config.sleepPaddingMinutes
        ] as [String: Any], forKey: beatConfigKey())
    }

    internal func loadUploadedBeatSeries() -> [String: Double] {
        (defaults.dictionary(forKey: beatUploadedKey()) as? [String: Double]) ?? [:]
    }

    internal func saveUploadedBeatSeries(_ uploaded: [String: Double]) {
        defaults.set(uploaded, forKey: beatUploadedKey())
    }

    internal func clearBeatCaptureState() {
        defaults.removeObject(forKey: beatConfigKey())
        defaults.removeObject(forKey: beatUploadedKey())
    }

    // MARK: Backend calls

    /// Fetches the participant's instructions. Any failure falls back to the last known
    /// mode without windows, or to `inactive` when nothing was ever received.
    internal func fetchBeatCaptureConfig(completion: @escaping (BeatCaptureConfig) -> Void) {
        let cached = loadCachedBeatConfig()
        guard let url = beatCaptureEndpoint, let credential = authCredential else {
            completion(cached)
            return
        }
        let request = buildRequest(url: url, method: "GET", credential: credential, requestId: UUID().uuidString)
        foregroundSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { completion(cached); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, (200...299).contains(status), let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let config = BeatCaptureConfig(json: json) else {
                self.logMessage("Beat capture: instructions unavailable (HTTP \(status)) - using last known mode")
                completion(cached)
                return
            }
            self.saveCachedBeatConfig(config)
            completion(config)
        }.resume()
    }

    /// Tells the backend a requested window has been uploaded. `beats` counts the
    /// interval records sent, `series` the heartbeat series that overlapped the window.
    internal func reportBeatWindowFulfilled(
        windowId: String, beats: Int, series: Int, completion: @escaping (Bool) -> Void
    ) {
        guard let url = beatWindowFulfilledEndpoint(windowId: windowId),
              let credential = authCredential,
              let body = try? JSONSerialization.data(withJSONObject: ["beats": beats, "series": series]) else {
            completion(false)
            return
        }
        var request = buildRequest(url: url, credential: credential, requestId: UUID().uuidString)
        request.httpBody = body
        foregroundSession.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = error == nil && (200...299).contains(status)
            if !ok {
                self?.logDiagnostic("Beat capture: window \(windowId) report failed (HTTP \(status))")
            }
            completion(ok)
        }.resume()
    }

    // MARK: Pass

    /// Uploads the heartbeat series the backend asked for: requested windows first, then
    /// whatever the participant's mode covers. Runs inside a sync run, after the regular
    /// types are done, and always calls `completion` exactly once.
    ///
    /// Progress is per series: a series counts as uploaded only after the upload that
    /// carried its last beat returned 2xx, so an interrupted pass resumes where it was
    /// cut and re-sends at most one chunk (deduplicated server-side by beat time).
    internal func runBeatCapture(generation: Int, isBackground: Bool, completion: @escaping () -> Void) {
        guard isBeatCaptureTracked, let endpoint = syncEndpoint else {
            completion()
            return
        }
        fetchBeatCaptureConfig { [weak self] config in
            guard let self = self else { completion(); return }
            if self.isSyncCancelled(generation: generation) { completion(); return }
            if config.mode == .off && config.windows.isEmpty {
                self.logMessage("Beat capture: off, no windows requested")
                completion()
                return
            }

            let now = Date()
            let cutoff = BeatCapture.lookbackStart(config: config, now: now).addingTimeInterval(-2 * 24 * 60 * 60)
            let pass = BeatPass(
                generation: generation,
                isBackground: isBackground,
                endpoint: endpoint,
                uploaded: BeatCapture.prune(self.loadUploadedBeatSeries(), olderThan: cutoff)
            )
            let finish: () -> Void = {
                self.saveUploadedBeatSeries(pass.uploaded)
                if pass.recordsSent > 0 {
                    self.logMessage("Beat capture: sent \(pass.recordsSent) intervals from \(pass.seriesSent) series")
                }
                completion()
            }

            self.processRequestedBeatWindows(config.windows, index: 0, pass: pass) { ok in
                guard ok else { finish(); return }
                self.automaticBeatWindows(config: config, now: now) { windows in
                    guard !windows.isEmpty else { finish(); return }
                    self.collectHeartbeatSeries(windows: windows, index: 0, found: [:]) { series in
                        guard let series = series else { finish(); return }
                        let pending = series.filter { pass.uploaded[$0.uuid.uuidString] == nil }
                        self.uploadBeatSeries(pending, index: 0, buffer: [], bufferSeries: [], records: 0, pass: pass) { _, _ in
                            finish()
                        }
                    }
                }
            }
        }
    }

    /// Requested windows are re-sent whole even when some series went up before, so the
    /// counts reported back describe the window rather than what this pass happened to add.
    private func processRequestedBeatWindows(
        _ windows: [BeatCaptureConfig.Window], index: Int, pass: BeatPass, completion: @escaping (Bool) -> Void
    ) {
        guard index < windows.count else { completion(true); return }
        if isSyncCancelled(generation: pass.generation) { completion(false); return }
        let window = windows[index]
        heartbeatSeries(in: DateInterval(start: window.start, end: window.end)) { [weak self] series in
            guard let self = self, let series = series else { completion(false); return }
            self.uploadBeatSeries(series, index: 0, buffer: [], bufferSeries: [], records: 0, pass: pass) { ok, records in
                guard ok else { completion(false); return }
                self.reportBeatWindowFulfilled(windowId: window.id, beats: records, series: series.count) { _ in
                    // A lost report leaves the window pending; the next pass re-sends it
                    // (deduplicated server-side) and reports again.
                    self.processRequestedBeatWindows(windows, index: index + 1, pass: pass, completion: completion)
                }
            }
        }
    }

    private func automaticBeatWindows(
        config: BeatCaptureConfig, now: Date, completion: @escaping ([DateInterval]) -> Void
    ) {
        guard config.mode == .sleep else {
            completion(BeatCapture.automaticWindows(config: config, now: now, sleepSamples: []))
            return
        }
        // Reach back half a day further so a night that started before the lookback edge
        // is still recognised as one night.
        let from = BeatCapture.lookbackStart(config: config, now: now).addingTimeInterval(-12 * 60 * 60)
        sleepSampleIntervals(from: from, to: now) { samples in
            completion(BeatCapture.automaticWindows(config: config, now: now, sleepSamples: samples))
        }
    }

    // MARK: HealthKit reads

    private func sleepSampleIntervals(from start: Date, to end: Date, completion: @escaping ([DateInterval]) -> Void) {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            completion([])
            return
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let query = HKSampleQuery(
            sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil
        ) { [weak self] _, samples, error in
            if let error = error {
                self?.logMessage("Beat capture: sleep query failed - \(error.localizedDescription)")
                completion([])
                return
            }
            completion((samples ?? []).map { DateInterval(start: $0.startDate, end: max($0.startDate, $0.endDate)) })
        }
        healthStore.execute(query)
    }

    /// Heartbeat series overlapping `interval`, oldest first. Nil when HealthKit could not
    /// be read (e.g. the phone is locked), which stops the pass.
    private func heartbeatSeries(in interval: DateInterval, completion: @escaping ([HKHeartbeatSeriesSample]?) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(
            sampleType: HKSeriesType.heartbeat(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]
        ) { [weak self] _, samples, error in
            if let error = error {
                if self?.isProtectedDataError(error) == true {
                    self?.logMessage("Beat capture: protected data inaccessible - pausing")
                    self?.pendingSyncAfterUnlock = true
                } else {
                    self?.logMessage("Beat capture: series query failed - \(error.localizedDescription)")
                }
                completion(nil)
                return
            }
            completion((samples ?? []).compactMap { $0 as? HKHeartbeatSeriesSample })
        }
        healthStore.execute(query)
    }

    private func collectHeartbeatSeries(
        windows: [DateInterval],
        index: Int,
        found: [String: HKHeartbeatSeriesSample],
        completion: @escaping ([HKHeartbeatSeriesSample]?) -> Void
    ) {
        guard index < windows.count else {
            completion(found.values.sorted { $0.startDate < $1.startDate })
            return
        }
        heartbeatSeries(in: windows[index]) { [weak self] samples in
            guard let self = self, let samples = samples else { completion(nil); return }
            var next = found
            for sample in samples { next[sample.uuid.uuidString] = sample }
            self.collectHeartbeatSeries(windows: windows, index: index + 1, found: next, completion: completion)
        }
    }

    private func readBeats(
        of sample: HKHeartbeatSeriesSample, completion: @escaping ([BeatCapture.Beat]?, Error?) -> Void
    ) {
        let accumulator = BeatAccumulator()
        let query = HKHeartbeatSeriesQuery(heartbeatSeries: sample) { _, timeSinceSeriesStart, precededByGap, done, error in
            if let error = error {
                accumulator.finish { _ in completion(nil, error) }
                return
            }
            accumulator.append(BeatCapture.Beat(timeSinceStart: timeSinceSeriesStart, precededByGap: precededByGap))
            if done {
                accumulator.finish { beats in completion(beats, nil) }
            }
        }
        healthStore.execute(query)
    }

    // MARK: Upload

    private func beatChunkLimit(_ pass: BeatPass) -> Int {
        let inBackground = pass.isBackground || backgroundTimeRemainingIfInBackground() != nil
        return inBackground ? 800 : 4000
    }

    /// Reads `series[index...]` one at a time and uploads whole series in chunks.
    /// Completes with whether every series went up and how many interval records were sent.
    private func uploadBeatSeries(
        _ series: [HKHeartbeatSeriesSample],
        index: Int,
        buffer: [[String: Any]],
        bufferSeries: [HKHeartbeatSeriesSample],
        records: Int,
        pass: BeatPass,
        completion: @escaping (Bool, Int) -> Void
    ) {
        if isSyncCancelled(generation: pass.generation) { completion(false, records); return }

        let atEnd = index >= series.count
        if !buffer.isEmpty && (atEnd || buffer.count >= beatChunkLimit(pass)) {
            flushBeatRecords(buffer, series: bufferSeries, pass: pass) { [weak self] ok in
                guard let self = self, ok else { completion(false, records); return }
                self.uploadBeatSeries(
                    series, index: index, buffer: [], bufferSeries: [], records: records, pass: pass, completion: completion
                )
            }
            return
        }
        if atEnd { completion(true, records); return }

        let sample = series[index]
        readBeats(of: sample) { [weak self] beats, error in
            guard let self = self else { completion(false, records); return }
            if let error = error {
                if self.isProtectedDataError(error) {
                    self.logMessage("Beat capture: protected data inaccessible - pausing")
                    self.pendingSyncAfterUnlock = true
                    completion(false, records)
                    return
                }
                // One unreadable series must not hold up the rest; it is retried next pass.
                self.logMessage("Beat capture: series \(sample.uuid.uuidString) unreadable - \(error.localizedDescription)")
                self.uploadBeatSeries(
                    series, index: index + 1, buffer: buffer, bufferSeries: bufferSeries,
                    records: records, pass: pass, completion: completion
                )
                return
            }
            let made = BeatCapture.records(
                seriesId: sample.uuid.uuidString,
                seriesStart: sample.startDate,
                beats: beats ?? [],
                source: self._mapSource(sample.sourceRevision, device: sample.device),
                zoneOffset: self._zoneOffsetString(metadata: sample.metadata, date: sample.startDate),
                formatter: pass.formatter
            )
            self.uploadBeatSeries(
                series, index: index + 1, buffer: buffer + made, bufferSeries: bufferSeries + [sample],
                records: records + made.count, pass: pass, completion: completion
            )
        }
    }

    private func flushBeatRecords(
        _ records: [[String: Any]], series: [HKHeartbeatSeriesSample], pass: BeatPass, completion: @escaping (Bool) -> Void
    ) {
        guard let credential = authCredential else { completion(false); return }
        if let remaining = backgroundTimeRemainingIfInBackground(), remaining < 5 {
            logMessage("Beat capture: background time low - pausing")
            completion(false)
            return
        }
        let payload: [String: Any] = [
            "provider": "apple",
            "sdkVersion": OpenWearablesHealthSDK.sdkVersion,
            "syncTimestamp": BeatCapture.timestamp(Date(), formatter: pass.formatter),
            "data": ["records": records, "workouts": [Any](), "sleep": [Any]()] as [String: Any]
        ]
        uploadCombinedPayload(
            payload: payload, endpoint: pass.endpoint, credential: credential, generation: pass.generation
        ) { ok in
            if ok {
                for sample in series {
                    pass.uploaded[sample.uuid.uuidString] = sample.endDate.timeIntervalSince1970
                }
                pass.recordsSent += records.count
                pass.seriesSent += series.count
            }
            completion(ok)
        }
    }
}
