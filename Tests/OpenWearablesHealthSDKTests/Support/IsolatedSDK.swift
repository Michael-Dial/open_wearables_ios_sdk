import XCTest
@testable import OpenWearablesHealthSDK

extension XCTestCase {

    /// Runs `body` against a signed-in SDK whose on-disk state points at a fresh
    /// temporary directory, whose credentials live in memory, and whose foreground
    /// session is backed by `StubURLProtocol`.
    ///
    /// The SDK is a singleton shared by the whole suite, so everything this touches is
    /// captured up front and put back afterwards. The two overrides are what make a test
    /// run hermetic: without them it would read and delete the Application Support
    /// contents of whatever app hosts it, and it could not hold a credential at all,
    /// because `xctest` has no keychain access group.
    func withIsolatedSDK(
        userId: String = "test-user",
        accessToken: String? = "access-1",
        refreshToken: String? = "refresh-1",
        host: String = "https://sync.example.test",
        _ body: (OpenWearablesHealthSDK, URL) -> Void
    ) {
        let sdk = OpenWearablesHealthSDK.shared

        let previousStateDirectory = sdk.stateDirectoryOverride
        let previousSession: URLSession? = sdk.foregroundSession
        let previousHost = sdk.host
        let previousAuthErrorHandler = sdk.onAuthError
        let previousCredentials = OpenWearablesHealthSdkKeychain.volatileStore
        let previousPersistedHost = OpenWearablesHealthSdkKeychain.getHost()
        let previousRefreshUrl = OpenWearablesHealthSdkKeychain.getCustomRefreshUrl()
        let previousAssertions = sdk.backgroundAssertions

        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-sdk-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]

        defer {
            StubURLProtocol.reset()
            sdk.backgroundAssertions = previousAssertions
            sdk.onAuthError = previousAuthErrorHandler
            sdk.foregroundSession = previousSession
            sdk.stateDirectoryOverride = previousStateDirectory
            sdk.host = previousHost
            OpenWearablesHealthSdkKeychain.volatileStore = previousCredentials
            OpenWearablesHealthSdkKeychain.saveHost(previousPersistedHost)
            OpenWearablesHealthSdkKeychain.saveCustomRefreshUrl(previousRefreshUrl)
            try? FileManager.default.removeItem(at: stateDirectory)
        }

        sdk.stateDirectoryOverride = stateDirectory
        // The test bundle has no host app, so there is no `UIApplication` to ask for time.
        sdk.backgroundAssertions = FakeBackgroundAssertions()
        sdk.foregroundSession = URLSession(
            configuration: configuration, delegate: nil, delegateQueue: .main
        )
        OpenWearablesHealthSdkKeychain.volatileStore = [:]
        OpenWearablesHealthSdkKeychain.saveCredentials(
            userId: userId, accessToken: accessToken, refreshToken: refreshToken
        )
        // Set directly rather than through `configure`, which has side effects (session
        // restore, observer registration) that are not part of what these tests exercise.
        sdk.host = host
        OpenWearablesHealthSdkKeychain.saveHost(host)
        OpenWearablesHealthSdkKeychain.saveCustomRefreshUrl(nil)

        body(sdk, stateDirectory)
    }

    /// Spins the main run loop until `condition` holds or `timeout` elapses, so the
    /// SDK's main-queue completion handlers can run while a test waits on them.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
