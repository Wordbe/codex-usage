import CryptoKit
import Foundation

struct UsageAccount: Codable, Equatable, Sendable {
    let key: String
    let email: String?
    let planType: String?
}

struct AccountContext: Equatable, Sendable {
    let key: String
    let email: String?

    static var codexHome: String { "\(userHomeDirectory())/.codex" }

    static func current() throws -> AccountContext {
        let path = URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: path) else {
            throw UsageError.rpc("Sign in to ChatGPT with file-based Codex authentication first.")
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> AccountContext {
        guard let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              auth["OPENAI_API_KEY"] as? String == nil,
              let tokens = auth["tokens"] as? [String: Any],
              let workspace = tokens["account_id"] as? String, !workspace.isEmpty else {
            throw UsageError.rpc("ChatGPT account authentication is required to read quota.")
        }
        // Decode identity only. Tokens never leave this function or enter the cache.
        for field in ["id_token", "access_token"] {
            guard let token = tokens[field] as? String else { continue }
            let segments = token.split(separator: ".", omittingEmptySubsequences: false)
            guard segments.count >= 2 else { continue }
            var encoded = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let payload = Data(base64Encoded: encoded),
                  let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let user = claims["sub"] as? String, !user.isEmpty else { continue }
            let identity = try JSONSerialization.data(withJSONObject: [user, workspace])
            let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            let profile = claims["https://api.openai.com/profile"] as? [String: Any]
            return AccountContext(key: key, email: claims["email"] as? String ?? profile?["email"] as? String)
        }
        throw UsageError.rpc("Unable to identify the ChatGPT account in ~/.codex/auth.json.")
    }

    func requireCurrent() throws {
        guard try Self.current().key == key else { throw UsageError.accountChanged }
    }
}
