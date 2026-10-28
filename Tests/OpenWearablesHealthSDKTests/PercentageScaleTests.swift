import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// `HKUnit.percent()` is a 0-1 fraction, but the payload labels it "%", which the backend
/// reads as 0-100 (the same scale the Android SDK sends).
final class PercentageScaleTests: XCTestCase {

    private func record(_ identifier: HKQuantityTypeIdentifier, fraction: Double) -> [String: Any]? {
        let sample = HKQuantitySample(
            type: HKQuantityType.quantityType(forIdentifier: identifier)!,
            quantity: HKQuantity(unit: .percent(), doubleValue: fraction),
            start: Date(),
            end: Date()
        )
        let payload = OpenWearablesHealthSDK.shared.buildCombinedPayload(samples: [sample])
        let data = payload["data"] as? [String: Any]
        return (data?["records"] as? [[String: Any]])?.first
    }

    func testPercentTypesAreSentOnA0To100Scale() {
        let cases: [(HKQuantityTypeIdentifier, Double, Double)] = [
            (.bodyFatPercentage, 0.304, 30.4),
            (.walkingAsymmetryPercentage, 0.12, 12),
            (.walkingDoubleSupportPercentage, 0.285, 28.5),
            (.oxygenSaturation, 0.97, 97),
        ]

        for (identifier, fraction, expected) in cases {
            let r = record(identifier, fraction: fraction)
            XCTAssertEqual(r?["unit"] as? String, "%", identifier.rawValue)
            XCTAssertEqual(r?["value"] as? Double ?? .nan, expected, accuracy: 1e-9, identifier.rawValue)
        }
    }

    /// Open Wearables scales Apple percentages x100 again for any SDK below 0.17.0
    /// (the-momentum/open-wearables#1986), so the 0-100 scale above must ship with a
    /// reported version of at least 0.17.0, or body fat 30.4 is stored as 3040.
    func testSDKVersionIsAtLeastTheBackendPercentScaleCutoff() {
        let parts = OpenWearablesHealthSDK.sdkVersion.split(separator: ".").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 3, OpenWearablesHealthSDK.sdkVersion)
        XCTAssertFalse(parts.lexicographicallyPrecedes([0, 17, 0]), OpenWearablesHealthSDK.sdkVersion)
    }
}
