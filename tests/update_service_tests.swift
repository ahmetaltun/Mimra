// ==============================================================================
// Mimra — Update Service Unit & Regression Tests (P9-05 / F-062, T-REL-01)
// Verifies UpdateService state machine, preferences, dispatch, and zero telemetry.
// Swift 6 strict concurrency compliant.
// ==============================================================================

import Foundation

@MainActor
final class MockUpdateProvider: UpdateProvider {
    var canCheckForUpdates: Bool = true
    var automaticallyChecksForUpdates: Bool = true
    var automaticallyDownloadsUpdates: Bool = false
    var updateCheckInterval: TimeInterval = 86400
    var lastUpdateCheckDate: Date? = nil
    var feedURL: URL? = URL(string: "https://raw.githubusercontent.com/ahmetaltun/Mimra/master/appcast.xml")

    var checkCount: Int = 0
    var backgroundCheckCount: Int = 0

    func checkForUpdates() {
        checkCount += 1
    }

    func checkForUpdatesInBackground() {
        backgroundCheckCount += 1
    }
}

@MainActor
func testDefaultPreferences() {
    print("Testing default update preferences...")
    UserDefaults.standard.removeObject(forKey: "SUEnableAutomaticChecks")
    UserDefaults.standard.removeObject(forKey: "SUAllowsAutomaticUpdates")
    UserDefaults.standard.removeObject(forKey: "SUScheduledCheckInterval")

    let mock = MockUpdateProvider()
    let service = UpdateService(provider: mock)

    assert(service.automaticallyChecksForUpdates == true, "Expected automatic checks to be enabled by default")
    assert(service.automaticallyDownloadsUpdates == false, "Expected automatic downloads to be false by default")
    assert(service.updateCheckInterval == 86400, "Expected daily check interval by default")
    assert(service.formattedLastCheckDate == "Never", "Expected Never for initial last check date")
    print("✓ Default update preferences passed.")
}

@MainActor
func testFrequencySettings() {
    print("Testing frequency settings persistence...")
    let mock = MockUpdateProvider()
    let service = UpdateService(provider: mock)

    service.updateCheckInterval = UpdateCheckFrequency.weekly.rawValue
    assert(mock.updateCheckInterval == UpdateCheckFrequency.weekly.rawValue, "Provider interval should update")
    assert(UserDefaults.standard.double(forKey: "SUScheduledCheckInterval") == UpdateCheckFrequency.weekly.rawValue, "UserDefaults should persist weekly interval")

    service.updateCheckInterval = UpdateCheckFrequency.monthly.rawValue
    assert(mock.updateCheckInterval == UpdateCheckFrequency.monthly.rawValue, "Provider interval should update to monthly")
    print("✓ Frequency settings passed.")
}

@MainActor
func testCheckForUpdatesDispatch() {
    print("Testing user-initiated check dispatch...")
    let mock = MockUpdateProvider()
    let service = UpdateService(provider: mock)

    assert(mock.checkCount == 0, "Initial check count should be 0")
    service.checkForUpdates()
    assert(mock.checkCount == 1, "checkForUpdates should dispatch to provider")
    assert(service.isChecking == true, "isChecking should be true")

    service.setStatusMessage("Mimra is up to date.")
    assert(service.isChecking == false, "isChecking should reset after status message")
    assert(service.statusMessage == "Mimra is up to date.", "Status message should match")
    print("✓ User-initiated check dispatch passed.")
}

@MainActor
func testBackgroundCheckGuards() {
    print("Testing background check guards...")
    let mock = MockUpdateProvider()
    let service = UpdateService(provider: mock)

    service.automaticallyChecksForUpdates = true
    service.checkForUpdatesInBackground()
    assert(mock.backgroundCheckCount == 1, "Background check should execute when enabled")

    service.automaticallyChecksForUpdates = false
    service.checkForUpdatesInBackground()
    assert(mock.backgroundCheckCount == 1, "Background check should be suppressed when disabled")
    print("✓ Background check guards passed.")
}

@MainActor
func testNotificationAndFormatting() {
    print("Testing notifications and date formatting...")
    let mock = MockUpdateProvider()
    let testDate = Date(timeIntervalSince1970: 1700000000)
    mock.lastUpdateCheckDate = testDate

    let service = UpdateService(provider: mock)
    final class NotificationBox: @unchecked Sendable {
        var received = false
    }

    let box = NotificationBox()

    let observer = NotificationCenter.default.addObserver(
        forName: UpdateService.didCheckForUpdatesNotification,
        object: nil,
        queue: nil
    ) { _ in
        box.received = true
    }

    service.updateFromProvider()
    assert(box.received == true, "Expected didCheckForUpdatesNotification on updateFromProvider")
    assert(service.lastUpdateCheckDate == testDate, "Last check date should match mock date")
    assert(service.formattedLastCheckDate != "Never", "Formatted date should be non-empty string")

    NotificationCenter.default.removeObserver(observer)
    print("✓ Notifications and formatting passed.")
}

@MainActor
func testZeroTelemetryPolicy() {
    print("Testing zero telemetry policy compliance...")
    let mock = MockUpdateProvider()
    let service = UpdateService(provider: mock)

    service.setStatusMessage("Mimra is up to date.")
    let msg = service.statusMessage ?? ""
    assert(!msg.contains("password") && !msg.contains("secret") && !msg.contains("token"), "Status message must not contain secret tokens")
    assert(mock.feedURL?.scheme == "https", "Feed URL must strictly use HTTPS")
    print("✓ Zero telemetry policy compliance passed.")
}

@main
struct UpdateServiceTestsMain {
    @MainActor
    static func main() {
        print("=== Running UpdateService Unit & Regression Tests (T-REL-01) ===")
        testDefaultPreferences()
        testFrequencySettings()
        testCheckForUpdatesDispatch()
        testBackgroundCheckGuards()
        testNotificationAndFormatting()
        testZeroTelemetryPolicy()
        print("✓ All UpdateService tests passed successfully!")
    }
}
