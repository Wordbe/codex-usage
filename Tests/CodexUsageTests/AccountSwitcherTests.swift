import Foundation
import XCTest
@testable import CodexUsage

final class AccountSwitcherTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func switcher(helper: String) throws -> AccountSwitcher {
        let bundled = root.appendingPathComponent("bundled-codex-account")
        try helper.write(to: bundled, atomically: true, encoding: .utf8)
        return AccountSwitcher(installedPath: root.appendingPathComponent("bin/codex-account").path, bundledPath: bundled.path)
    }

    func markInstalled(_ switcher: AccountSwitcher) throws {
        try FileManager.default.createDirectory(atPath: root.appendingPathComponent("bin").path, withIntermediateDirectories: true)
        try "old".write(toFile: switcher.installedPath, atomically: true, encoding: .utf8)
    }

    func testHelperIsOptInAndKeptInStepWithBundle() throws {
        let switcher = try switcher(helper: "print('v1')\n")
        switcher.updateInstalledCopy()
        XCTAssertFalse(switcher.isInstalled)

        try markInstalled(switcher)
        switcher.updateInstalledCopy()
        XCTAssertEqual(try String(contentsOfFile: switcher.installedPath, encoding: .utf8), "print('v1')\n")
        let mode = try FileManager.default.attributesOfItem(atPath: switcher.installedPath)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)

        try switcher.uninstall()
        XCTAssertFalse(switcher.isInstalled)
        XCTAssertThrowsError(try switcher.listAccounts())
    }

    func testListDecodesAccountsAndUsageKeys() throws {
        let claims = try JSONSerialization.data(withJSONObject: ["sub": "a", "email": "a@example.test"])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "=", with: "")
        let auth = root.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "x.\(payload).x", "account_id": "workspace"]]).write(to: auth)
        let accounts = [["name": "1", "label": "a@example.test", "current": true, "auth": auth.path],
                        ["name": "2", "label": "2 | missing", "current": false, "auth": root.appendingPathComponent("none").path]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: accounts), as: UTF8.self)
        let switcher = try switcher(helper: "print(r'''\(json)''')\n")
        try markInstalled(switcher)
        switcher.updateInstalledCopy()

        let listed: [SwitchableAccount]
        do {
            listed = try switcher.listAccounts()
        } catch AccountSwitchError.pythonNotFound {
            throw XCTSkip("Python 3.11 or later is not installed.")
        }
        XCTAssertEqual(listed.map(\.name), ["1", "2"])
        XCTAssertEqual(listed[0].usageKey, try AccountContext.decode(Data(contentsOf: auth)).key)
        XCTAssertNil(listed[1].usageKey)
    }

    func testStoreLockIsDetectedWithoutCreatingIt() throws {
        let lock = root.appendingPathComponent(".lock").path
        XCTAssertFalse(accountStoreIsBusy(lockPath: lock))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock))
        FileManager.default.createFile(atPath: lock, contents: nil)
        let holder = open(lock, O_RDONLY)
        defer { close(holder) }
        XCTAssertEqual(flock(holder, LOCK_EX), 0)
        XCTAssertTrue(accountStoreIsBusy(lockPath: lock))
        flock(holder, LOCK_UN)
        XCTAssertFalse(accountStoreIsBusy(lockPath: lock))
    }

    func testUsageSummaryMarksResetWindows() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = UsageSnapshot(
            source: "codex", planType: nil,
            primary: RateLimitWindow(usedPercent: 87, windowDurationMins: 300, resetsAt: 500),
            secondary: RateLimitWindow(usedPercent: 40.4, windowDurationMins: 10080, resetsAt: 5_000),
            credits: nil, rateLimitReachedType: nil, fetchedAt: now)
        XCTAssertEqual(accountUsageSummary(snapshot, now: now), "5h reset, weekly 40%")
        XCTAssertEqual(accountUsageSummary(snapshot, now: Date(timeIntervalSince1970: 100)), "5h 87%, weekly 40%")
        let empty = UsageSnapshot(source: "codex", planType: nil, primary: nil, secondary: nil,
                                  credits: nil, rateLimitReachedType: nil, fetchedAt: now)
        XCTAssertNil(accountUsageSummary(empty))
    }
}
