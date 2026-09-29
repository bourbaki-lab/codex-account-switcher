import AppKit
import Foundation

public struct OfficialAppInfo: Codable, Equatable, Sendable {
    public var path: String
    public var bundleIdentifier: String
    public var shortVersion: String?
    public var buildVersion: String?
    public var bundledCodexPath: String?

    public init(path: String, bundleIdentifier: String, shortVersion: String?, buildVersion: String?, bundledCodexPath: String?) {
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.bundledCodexPath = bundledCodexPath
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

public enum OfficialAppAuthenticationMode: String, Codable, Equatable, Sendable {
    case notRunning
    case hostManaged
    case standardOrUnknown
}

public struct EnvironmentReport: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var macOSVersion: String
    public var architecture: String
    public var codexCLIPath: String?
    public var codexCLIVersion: String?
    public var codexHome: String
    public var codexHomeExists: Bool
    public var configExists: Bool
    public var authFileExists: Bool
    public var authFilePermissions: String?
    public var loginStatus: String?
    public var credentialsStoreSetting: String?
    public var officialApp: OfficialAppInfo?
    public var officialAppAuthenticationMode: OfficialAppAuthenticationMode
    public var protectedStatePaths: [String]
    public var runningProcessSummaries: [String]

    public init(
        generatedAt: Date = Date(),
        macOSVersion: String,
        architecture: String,
        codexCLIPath: String?,
        codexCLIVersion: String?,
        codexHome: String,
        codexHomeExists: Bool,
        configExists: Bool,
        authFileExists: Bool,
        authFilePermissions: String?,
        loginStatus: String?,
        credentialsStoreSetting: String?,
        officialApp: OfficialAppInfo?,
        officialAppAuthenticationMode: OfficialAppAuthenticationMode = .notRunning,
        protectedStatePaths: [String],
        runningProcessSummaries: [String]
    ) {
        self.generatedAt = generatedAt
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.codexCLIPath = codexCLIPath
        self.codexCLIVersion = codexCLIVersion
        self.codexHome = codexHome
        self.codexHomeExists = codexHomeExists
        self.configExists = configExists
        self.authFileExists = authFileExists
        self.authFilePermissions = authFilePermissions
        self.loginStatus = loginStatus
        self.credentialsStoreSetting = credentialsStoreSetting
        self.officialApp = officialApp
        self.officialAppAuthenticationMode = officialAppAuthenticationMode
        self.protectedStatePaths = protectedStatePaths
        self.runningProcessSummaries = runningProcessSummaries
    }
}

public struct OfficialAppLocator: Sendable {
    public let searchRoots: [URL]

    public init(searchRoots: [URL]? = nil) {
        if let searchRoots {
            self.searchRoots = searchRoots
        } else {
            self.searchRoots = [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
            ]
        }
    }

    public func locate() -> OfficialAppInfo? {
        candidates()
            .compactMap(inspect(appURL:))
            .sorted(by: preferred(lhs:rhs:))
            .first
    }

    public func inspect(appURL: URL) -> OfficialAppInfo? {
        let plist = appURL.appending(path: "Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let bundleID = info["CFBundleIdentifier"] as? String
        else { return nil }

        let looksOfficial = bundleID.lowercased().hasPrefix("com.openai.")
        // New desktop releases package the native CLI in its own app bundle.
        // Prefer it over the shell launcher, while retaining older app layouts.
        let bundledCodexPaths = [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex-cli/bin/codex",
            "Contents/Resources/codex"
        ]
        guard looksOfficial,
              let bundledCodex = bundledCodexPaths
                .map({ appURL.appending(path: $0) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { return nil }

        return OfficialAppInfo(
            path: appURL.path,
            bundleIdentifier: bundleID,
            shortVersion: info["CFBundleShortVersionString"] as? String,
            buildVersion: info["CFBundleVersion"] as? String,
            bundledCodexPath: bundledCodex.path
        )
    }

    private func candidates() -> [URL] {
        var output: [URL] = []
        for root in searchRoots where FileManager.default.fileExists(atPath: root.path) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            output.append(contentsOf: entries.filter { $0.pathExtension.lowercased() == "app" })
        }
        return output
    }

    private func preferred(lhs: OfficialAppInfo, rhs: OfficialAppInfo) -> Bool {
        let lhsCodex = lhs.bundleIdentifier == "com.openai.codex"
        let rhsCodex = rhs.bundleIdentifier == "com.openai.codex"
        if lhsCodex != rhsCodex { return lhsCodex }
        let lhsSystem = lhs.path.hasPrefix("/Applications/")
        let rhsSystem = rhs.path.hasPrefix("/Applications/")
        if lhsSystem != rhsSystem { return lhsSystem }
        return lhs.path < rhs.path
    }
}

public struct ProcessSummary: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var executable: String
    public var isOfficialAppProcess: Bool
    public var blocksSwitch: Bool
    public var usesHostManagedAuthentication: Bool

    public init(
        pid: Int32,
        parentPID: Int32,
        executable: String,
        isOfficialAppProcess: Bool,
        blocksSwitch: Bool,
        usesHostManagedAuthentication: Bool = false
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.executable = executable
        self.isOfficialAppProcess = isOfficialAppProcess
        self.blocksSwitch = blocksSwitch
        self.usesHostManagedAuthentication = usesHostManagedAuthentication
    }

    public var safeDescription: String {
        "pid=\(pid) \(URL(fileURLWithPath: executable).lastPathComponent)"
    }
}

public struct CodexProcessScanner: Sendable {
    private struct ParsedProcess: Sendable {
        var pid: Int32
        var parentPID: Int32
        var command: String
    }

    private let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func scan(officialAppPath: String?) throws -> [ProcessSummary] {
        let result = try runner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-Ao", "pid=,ppid=,command="],
            redactOutput: true
        )
        guard result.exitCode == 0 else {
            throw SwitcherError.fileOperation("실행 중인 Codex 프로세스를 확인하지 못했습니다")
        }
        return parse(output: result.output, officialAppPath: officialAppPath)
    }

    public func parse(output: String, officialAppPath: String?) -> [ProcessSummary] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let processes: [ParsedProcess] = output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]), pid != currentPID else {
                return nil
            }
            return ParsedProcess(pid: pid, parentPID: ppid, command: String(fields[2]))
        }

        let processesByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let officialPIDs = Set(processes.compactMap { process -> Int32? in
            isOfficialProcess(command: process.command, officialAppPath: officialAppPath) ? process.pid : nil
        })
        let standalonePIDs = Set(processes.compactMap { process -> Int32? in
            let lower = process.command.lowercased()
            guard !lower.contains("codexaccountswitcher"),
                  !isTrustedCodexHelper(command: process.command),
                  !officialPIDs.contains(process.pid),
                  codexCLIExecutable(in: process.command) != nil
            else {
                return nil
            }
            return process.pid
        })
        let blockerPIDs = Set(standalonePIDs.filter { pid in
            guard let process = processesByPID[pid] else { return false }
            return !hasAncestor(
                startingAt: process.parentPID,
                in: standalonePIDs,
                processesByPID: processesByPID
            )
        })

        return processes.compactMap { process in
            let official = officialPIDs.contains(process.pid)
            let blocksSwitch = blockerPIDs.contains(process.pid)
            guard official || blocksSwitch else { return nil }
            let executable = codexCLIExecutable(in: process.command)
                ?? String(process.command.split(whereSeparator: \.isWhitespace).first ?? "unknown")
            return ProcessSummary(
                pid: process.pid,
                parentPID: process.parentPID,
                executable: executable,
                isOfficialAppProcess: official,
                blocksSwitch: blocksSwitch,
                usesHostManagedAuthentication: official && isHostManagedAppServer(command: process.command)
            )
        }
    }

    public func officialAppAuthenticationMode(in processes: [ProcessSummary]) -> OfficialAppAuthenticationMode {
        let officialProcesses = processes.filter(\.isOfficialAppProcess)
        guard !officialProcesses.isEmpty else { return .notRunning }
        return officialProcesses.contains(where: \.usesHostManagedAuthentication)
            ? .hostManaged
            : .standardOrUnknown
    }

    private func isOfficialProcess(command: String, officialAppPath: String?) -> Bool {
        officialAppPath.map { command.hasPrefix($0 + "/") || command == $0 } ?? false
    }

    private func isTrustedCodexHelper(command: String) -> Bool {
        let lower = command.lowercased()
        return lower.contains("/.codex/computer-use/codex computer use.app/")
            || lower.contains("/codex computer use.app/contents/")
    }

    private func isHostManagedAppServer(command: String) -> Bool {
        let lower = command.lowercased()
        guard lower.contains("app-server") else { return false }
        return lower.contains("features.code_mode_host=true")
            || lower.contains("--enable code_mode_host")
    }

    private func codexCLIExecutable(in command: String) -> String? {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first else { return nil }
        if executableName(first) == "codex" {
            return unquoted(first)
        }

        let wrapper = executableName(first).lowercased()
        guard ["node", "bun", "deno", "env"].contains(wrapper) else { return nil }
        for token in tokens.dropFirst().prefix(4) {
            let name = executableName(token)
            if name == "codex" || (name == "codex.js" && token.contains("@openai/codex")) {
                return unquoted(token)
            }
        }
        return nil
    }

    private func executableName(_ token: String) -> String {
        URL(fileURLWithPath: unquoted(token)).lastPathComponent
    }

    private func unquoted(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private func hasAncestor(
        startingAt parentPID: Int32,
        in candidates: Set<Int32>,
        processesByPID: [Int32: ParsedProcess]
    ) -> Bool {
        var pid = parentPID
        var visited = Set<Int32>()
        while pid > 0, visited.insert(pid).inserted {
            if candidates.contains(pid) { return true }
            guard let parent = processesByPID[pid] else { return false }
            pid = parent.parentPID
        }
        return false
    }
}

public struct EnvironmentInspector: Sendable {
    private let paths: SwitcherPaths
    private let locator: OfficialAppLocator
    private let runner: ProcessRunner
    private let scanner: CodexProcessScanner

    public init(
        paths: SwitcherPaths = SwitcherPaths(),
        locator: OfficialAppLocator = OfficialAppLocator(),
        runner: ProcessRunner = ProcessRunner(),
        scanner: CodexProcessScanner = CodexProcessScanner()
    ) {
        self.paths = paths
        self.locator = locator
        self.runner = runner
        self.scanner = scanner
    }

    public func inspect() -> EnvironmentReport {
        let official = locator.locate()
        let codexPath = official?.bundledCodexPath ?? shellCodexPath()
        let codexVersion = codexPath.flatMap { path in
            try? runner.run(executable: URL(fileURLWithPath: path), arguments: ["--version"]).output
                .split(separator: "\n")
                .last.map(String.init)
        }
        let loginStatus = codexPath.flatMap { path in
            try? runner.run(executable: URL(fileURLWithPath: path), arguments: ["login", "status"]).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let protected = protectedStatePaths()
        let processes = (try? scanner.scan(officialAppPath: official?.path)) ?? []
        let officialAppAuthenticationMode = scanner.officialAppAuthenticationMode(in: processes)
        let config = paths.codexHome.appending(path: "config.toml")
        return EnvironmentReport(
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture(),
            codexCLIPath: codexPath,
            codexCLIVersion: codexVersion.map(Redactor.redact),
            codexHome: paths.codexHome.path,
            codexHomeExists: FileManager.default.fileExists(atPath: paths.codexHome.path),
            configExists: FileManager.default.fileExists(atPath: config.path),
            authFileExists: FileManager.default.fileExists(atPath: paths.authFile.path),
            authFilePermissions: permissions(paths.authFile),
            loginStatus: loginStatus.map(Redactor.redact),
            credentialsStoreSetting: credentialsStoreSetting(config),
            officialApp: official,
            officialAppAuthenticationMode: officialAppAuthenticationMode,
            protectedStatePaths: protected,
            runningProcessSummaries: processes.map(\.safeDescription)
        )
    }

    private func shellCodexPath() -> String? {
        let result = try? runner.run(executable: URL(fileURLWithPath: "/usr/bin/which"), arguments: ["codex"])
        guard result?.exitCode == 0 else { return nil }
        return result?.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func credentialsStoreSetting(_ config: URL) -> String? {
        CodexCredentialsStoreMode.configuredValue(at: config)
    }

    private func protectedStatePaths() -> [String] {
        let policy = SessionProtectionPolicy()
        return (policy.singleHashedPaths + policy.recursivelyHashedPaths + policy.existenceOnlyPaths)
            .filter { FileManager.default.fileExists(atPath: paths.codexHome.appending(path: $0).path) }
            .sorted()
    }

    private func permissions(_ url: URL) -> String? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let mode = attributes[.posixPermissions] as? NSNumber
        else { return nil }
        return String(format: "%04o", mode.intValue)
    }

    private func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
