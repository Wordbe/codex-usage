import Foundation

struct SwitchableAccount: Decodable, Sendable {
    let name: String
    let label: String
    let current: Bool
    let auth: String
    var usageKey: String?

    enum CodingKeys: String, CodingKey {
        case name, label, current, auth
    }
}

enum AccountSwitchError: Error, CustomStringConvertible {
    case helperMissing
    case notInstalled
    case pythonNotFound
    case failed(String)

    var description: String {
        switch self {
        case .helperMissing:
            return "This build does not include the codex-account helper."
        case .notInstalled:
            return "Account switching is not enabled."
        case .pythonNotFound:
            return "Account switching requires Python 3.11 or later (for example: brew install python)."
        case .failed(let message):
            return message
        }
    }
}

/// Runs the optional codex-account helper, which owns all account storage in ~/.codex-accounts.
final class AccountSwitcher: @unchecked Sendable {
    let installedPath: String
    let bundledPath: String?
    /// Only touched from the controller's serial switcher queue.
    private var python: String?

    init(installedPath: String = "\(codexUsageRootDirectory())/bin/codex-account",
         bundledPath: String? = Bundle.main.url(forResource: "codex-account", withExtension: nil)?.path) {
        self.installedPath = installedPath
        self.bundledPath = bundledPath
    }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: installedPath) }

    func install() throws {
        _ = try pythonExecutable()
        try copyBundledHelper()
    }

    func uninstall() throws {
        guard isInstalled else { return }
        try FileManager.default.removeItem(atPath: installedPath)
    }

    /// Keeps an enabled helper in step with the running app version.
    func updateInstalledCopy() {
        if isInstalled { try? copyBundledHelper() }
    }

    func listAccounts() throws -> [SwitchableAccount] {
        // A CLI or Terminal switch can hold the store lock for over a minute.
        let output = try run(["list", "--json"], timeout: 120)
        guard let accounts = try? JSONDecoder().decode([SwitchableAccount].self, from: Data(output.utf8)) else {
            throw AccountSwitchError.failed("codex-account returned an unexpected account list.")
        }
        return accounts.map { account in
            var account = account
            account.usageKey = (try? Data(contentsOf: URL(fileURLWithPath: account.auth)))
                .flatMap { try? AccountContext.decode($0).key }
            return account
        }
    }

    func switchAccount(to name: String) throws {
        _ = try run(["switch", name], timeout: 180)
    }

    /// Writes a Terminal script for the interactive device-code login.
    func addAccountCommand() throws -> URL {
        guard isInstalled else { throw AccountSwitchError.notInstalled }
        let python = try pythonExecutable()
        let url = URL(fileURLWithPath: "\(codexUsageRootDirectory())/add-codex-account.command")
        let script = """
        #!/bin/sh
        PATH="$PATH:/Applications/ChatGPT.app/Contents/Resources"
        exec \(shellQuote(python)) \(shellQuote(installedPath)) add

        """
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func copyBundledHelper() throws {
        guard let bundledPath, let data = FileManager.default.contents(atPath: bundledPath) else {
            throw AccountSwitchError.helperMissing
        }
        let fm = FileManager.default
        if fm.contents(atPath: installedPath) == data { return }
        let directory = URL(fileURLWithPath: installedPath).deletingLastPathComponent().path
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try data.write(to: URL(fileURLWithPath: installedPath), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installedPath)
    }

    private func run(_ args: [String], timeout: TimeInterval) throws -> String {
        guard isInstalled else { throw AccountSwitchError.notInstalled }
        guard let result = runCommand(try pythonExecutable(), args: [installedPath] + args, timeout: timeout) else {
            throw AccountSwitchError.failed("codex-account did not finish.")
        }
        guard result.status == 0 else {
            // The helper reports errors on one line; keep only the last line of a traceback.
            let message = result.stderr.split(whereSeparator: \.isNewline).last.map(String.init)
            throw AccountSwitchError.failed(message ?? "codex-account exited with status \(result.status).")
        }
        return result.stdout
    }

    private func pythonExecutable() throws -> String {
        if let python { return python }
        // Apple's /usr/bin/python3 is 3.9 and may open the developer tools installer.
        let candidates = [ProcessInfo.processInfo.environment["CODEXUSAGE_PYTHON"]].compactMap { $0 }
            + (mergedEnvironment()["PATH"] ?? "").split(separator: ":").map { "\($0)/python3" }.filter { $0 != "/usr/bin/python3" }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if runCommand(candidate, args: ["-c", "import tomllib"], timeout: 5)?.status == 0 {
                python = candidate
                return candidate
            }
        }
        throw AccountSwitchError.pythonNotFound
    }
}

/// True while codex-account holds its store lock, e.g. during a switch from the menu, Terminal, or CLI.
func accountStoreIsBusy(lockPath: String = "\(userHomeDirectory())/.codex-accounts/.lock") -> Bool {
    let fd = open(lockPath, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    return flock(fd, LOCK_SH | LOCK_NB) != 0 && errno == EWOULDBLOCK
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func accountUsageSummary(_ snapshot: UsageSnapshot, now: Date = Date()) -> String? {
    let parts = [("5h", snapshot.fiveHourWindow), ("weekly", snapshot.weeklyWindow)].compactMap { name, window in
        window.map { window in
            let isReset = window.resetsAt.map { Date(timeIntervalSince1970: $0) <= now } ?? false
            return "\(name) \(isReset ? "reset" : formatPercent(window.usedPercent))"
        }
    }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
}
