import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Everything HKDevice says about the hardware that recorded a sample reaches the payload.
///
/// Open Wearables keeps each distinct description per data source, dated by the records
/// that carried it (`data_source_observation`), so a firmware update partway through a
/// study is visible beside the data it affects. A field the SDK never sends can never be
/// recovered for data already synced, because the anchor has moved past it.
final class SourceDeviceFieldsTests: XCTestCase {

    private func source(device: HKDevice?) -> [String: Any]? {
        let sample = HKQuantitySample(
            type: HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: 128),
            start: Date(),
            end: Date(),
            device: device,
            metadata: nil
        )
        let payload = OpenWearablesHealthSDK.shared.buildCombinedPayload(samples: [sample])
        let data = payload["data"] as? [String: Any]
        let record = (data?["records"] as? [[String: Any]])?.first
        return record?["source"] as? [String: Any]
    }

    func testEveryHKDeviceFieldIsSent() {
        let strap = HKDevice(
            name: "Polar H10 8E1F2C3A",
            manufacturer: "Polar Electro Oy",
            model: "H10",
            hardwareVersion: "39044024.10",
            firmwareVersion: "5.0.0",
            softwareVersion: "5.0.0",
            localIdentifier: "6B2E0F0C-1D2A-4F5B-9A3C-7E8D9F0A1B2C",
            udiDeviceIdentifier: "00812345678901"
        )
        let s = source(device: strap)

        XCTAssertEqual(s?["deviceName"] as? String, "Polar H10 8E1F2C3A")
        XCTAssertEqual(s?["deviceManufacturer"] as? String, "Polar Electro Oy")
        XCTAssertEqual(s?["deviceModel"] as? String, "H10")
        XCTAssertEqual(s?["deviceHardwareVersion"] as? String, "39044024.10")
        XCTAssertEqual(s?["deviceFirmwareVersion"] as? String, "5.0.0")
        XCTAssertEqual(s?["deviceSoftwareVersion"] as? String, "5.0.0")
        XCTAssertEqual(s?["deviceLocalIdentifier"] as? String, "6B2E0F0C-1D2A-4F5B-9A3C-7E8D9F0A1B2C")
        XCTAssertEqual(s?["deviceUdiDeviceIdentifier"] as? String, "00812345678901")
        // Never an identity: HealthKit has no stable per-device id.
        XCTAssertTrue(s?["deviceId"] is NSNull)
    }

    /// Null is "not said". A sample without a device carries no device keys at all, rather
    /// than empty strings the backend would store as values.
    func testNoDeviceSendsNoDeviceFields() {
        let s = source(device: nil)
        for key in ["deviceFirmwareVersion", "deviceLocalIdentifier", "deviceUdiDeviceIdentifier",
                    "deviceHardwareVersion", "deviceSoftwareVersion"] {
            XCTAssertNil(s?[key], key)
        }
    }

    /// The writing app's version, from HKSourceRevision, whenever HealthKit has one.
    func testTheWriterVersionIsSentWhenHealthKitHasOne() {
        let sample = HKQuantitySample(
            type: HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: 60),
            start: Date(),
            end: Date()
        )
        let s = OpenWearablesHealthSDK.shared._mapSource(sample.sourceRevision, device: nil)
        XCTAssertEqual(s["version"] as? String, sample.sourceRevision.version)
    }
}
