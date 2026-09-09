import Foundation
import XCTest
@testable import CodexUsage

final class AccountTests: XCTestCase {
    func auth(_ user: String, workspace: String = "workspace", token: String = "token") throws -> Data {
        let claims = try JSONSerialization.data(withJSONObject: ["sub": user, "email": "\(user)@example.test"])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "x.\(payload).x", "access_token": token, "account_id": workspace]])
    }

    func testIdentityIncludesUserAndWorkspaceButNotRefreshedToken() throws {
        let a = try AccountContext.decode(auth("a"))
        XCTAssertEqual(a, try AccountContext.decode(auth("a", token: "refreshed")))
        XCTAssertNotEqual(a.key, try AccountContext.decode(auth("b")).key)
        XCTAssertNotEqual(a.key, try AccountContext.decode(auth("a", workspace: "other")).key)
        XCTAssertEqual(a.key.count, 64)
        XCTAssertFalse(a.key.contains("example"))
    }

    func testUnknownAndAPIKeyIdentitiesAreRejected() throws {
        for data in [Data("{}".utf8), Data("not json".utf8), Data(#"{"OPENAI_API_KEY":"fake"}"#.utf8)] {
            XCTAssertThrowsError(try AccountContext.decode(data))
        }
    }

    func testCachesAreIsolatedAndRejectMismatchedContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = UsageCache(directory: root.path)
        let a = try AccountContext.decode(auth("a"))
        let b = try AccountContext.decode(auth("b"))
        var snapshot = UsageSnapshot(source: "codex", planType: "pro", primary: nil, secondary: nil, credits: nil, rateLimitReachedType: nil, fetchedAt: Date())
        snapshot.account = UsageAccount(key: a.key, email: a.email, planType: "pro")
        try cache.save(snapshot)
        XCTAssertNotNil(cache.load(context: a))
        XCTAssertNil(cache.load(context: b))
        try FileManager.default.copyItem(atPath: cache.path(for: a.key), toPath: cache.path(for: b.key))
        XCTAssertNil(cache.load(context: b))
        let mode = try FileManager.default.attributesOfItem(atPath: cache.path(for: a.key))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testFiveHourQuotaIsNotInferredFromPrimaryPosition() {
        let weekly = RateLimitWindow(usedPercent: 42, windowDurationMins: 10080, resetsAt: nil)
        let fiveHour = RateLimitWindow(usedPercent: 23, windowDurationMins: 300, resetsAt: nil)
        var snapshot = UsageSnapshot(source: "codex", planType: nil, primary: weekly, secondary: nil, credits: nil, rateLimitReachedType: nil, fetchedAt: Date())
        XCTAssertNil(snapshot.fiveHourWindow)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 42)
        XCTAssertTrue(statusLineText(snapshot).contains("unavailable"))
        snapshot = UsageSnapshot(source: "codex", planType: nil, primary: weekly, secondary: fiveHour, credits: nil, rateLimitReachedType: nil, fetchedAt: Date())
        XCTAssertEqual(snapshot.fiveHourWindow?.usedPercent, 23)
    }
}
