import Foundation
import Combine

struct ProjectInfo {
    let path: String
    let name: String
    let lastUsed: Date
    let source: ProjectSource
}

enum ProjectSource {
    case manual
    case scanned
    case claudeCode
}

private struct ProjectsConfig: Codable {
    var scan_dirs: [String]
    var manual: [ManualEntry]
    var names: [String: String]?
    var usage: [String: UsageEntry]?

    struct UsageEntry: Codable {
        var count: Int
        var lastOpened: Date
    }

    struct ManualEntry: Codable {
        let path: String
        let name: String
    }
}

final class ProjectManager: ObservableObject {
    @Published private(set) var development: [String: ProjectDevelopmentActivity] = [:]
    private var developmentScanInFlight = false
    private var developmentScannedAt = Date.distantPast
    private let developmentQueue = DispatchQueue(label: "ccpod.project-development", qos: .utility)
    var onChange: (() -> Void)?

    private let claudeProjectsDir: URL
    private let configURL: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.claudeProjectsDir = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        self.configURL = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("ccpod-projects.json")
        ensureConfig()
    }

    func start() {
        watchConfig()
    }

    func stop() {
        fileSource?.cancel()
        fileSource = nil
        fd = -1
    }

    // MARK: - Public API

    func recentProjects(limit: Int = .max) -> [ProjectInfo] {
        var seen = Set<String>()
        var result: [ProjectInfo] = []

        let config = loadConfig()
        let configMTime = modificationDate(atPath: configURL.path)

        for entry in config.manual {
            let expanded = expandTilde(entry.path)
            if !isPrivacySensitivePath(expanded) {
                guard FileManager.default.fileExists(atPath: expanded) else { continue }
            }
            guard seen.insert(expanded).inserted else { continue }
            let mtime = isPrivacySensitivePath(expanded) ? configMTime : modificationDate(atPath: expanded)
            let name = entry.name.isEmpty ? (expanded as NSString).lastPathComponent : entry.name
            result.append(ProjectInfo(path: expanded, name: name, lastUsed: mtime, source: .manual))
        }

        for dir in config.scan_dirs {
            let expanded = expandTilde(dir)
            for proj in scanDirectory(expanded) {
                guard seen.insert(proj.path).inserted else { continue }
                result.append(proj)
            }
        }

        for proj in claudeCodeProjects() {
            guard seen.insert(proj.path).inserted else { continue }
            result.append(proj)
        }

        let eligible = result.filter { $0.source == .manual || !isTemporaryPath($0.path) }
        refreshDevelopment(eligible.map(\.path))
        let now = Date()
        let scores = development.mapValues { $0.score(at: now) }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        return eligible
            .sorted {
                // 主目录是固定入口，其余项目继续按开发活跃度排序。
                let leftIsHome = $0.path == homePath
                let rightIsHome = $1.path == homePath
                if leftIsHome != rightIsHome { return leftIsHome }
                let left = development[$0.path]
                let right = development[$1.path]
                let leftScore = scores[$0.path] ?? 0
                let rightScore = scores[$1.path] ?? 0
                if leftScore != rightScore { return leftScore > rightScore }
                let leftDate = left?.latest ?? .distantPast
                let rightDate = right?.latest ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
                return $0.path < $1.path
            }
            .prefix(limit)
            .map { project in
                let defaultName = project.path == FileManager.default.homeDirectoryForCurrentUser.path
                    ? "主目录" : project.name
                return ProjectInfo(path: project.path, name: config.names?[project.path] ?? defaultName,
                                   lastUsed: project.lastUsed, source: project.source)
            }
    }

    private func refreshDevelopment(_ paths: [String]) {
        guard !developmentScanInFlight,
              Date().timeIntervalSince(developmentScannedAt) > 60
                || paths.contains(where: { development[$0] == nil }) else { return }
        developmentScanInFlight = true
        // 隐私目录仍沿用原有策略：不自动扫描 Documents/Desktop 等目录。
        let readable = paths.filter { !isPrivacySensitivePath($0) }
        developmentQueue.async { [weak self] in
            var snapshot = Dictionary(uniqueKeysWithValues: paths.map {
                ($0, ProjectDevelopmentActivity(dates: [], unavailable: true))
            })
            for path in readable { snapshot[path] = ProjectDevelopmentActivity.read(path: path) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.developmentScannedAt = Date()
                self.developmentScanInFlight = false
                self.development = snapshot
                self.onChange?()
            }
        }
    }

    /// 显示名按完整路径保存，不改变目录或启动路径。空名称恢复原名称。
    func renameProject(path: String, name: String) throws {
        try renameProjects([path: name])
    }

    func renameProjects(_ changes: [String: String]) throws {
        // 修改前严格读取：配置损坏时拒绝覆盖用户原数据。
        let data = try Data(contentsOf: configURL)
        var config = try JSONDecoder().decode(ProjectsConfig.self, from: data)
        var names = config.names ?? [:]
        for (path, name) in changes {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            names[expandTilde(path)] = trimmed.isEmpty ? nil : trimmed
        }
        config.names = names
        try saveConfig(config)
        onChange?()
    }

    func addManualProject(path: String) {
        var config = loadConfig()
        let expanded = expandTilde(path)
        if !isPrivacySensitivePath(expanded) {
            guard FileManager.default.fileExists(atPath: expanded) else { return }
        }
        if config.manual.contains(where: { expandTilde($0.path) == expanded }) { return }
        let name = (expanded as NSString).lastPathComponent
        config.manual.append(ProjectsConfig.ManualEntry(path: expanded, name: name))
        try? saveConfig(config)
    }

    func removeManualProject(path: String) {
        var config = loadConfig()
        let expanded = expandTilde(path)
        config.manual.removeAll { expandTilde($0.path) == expanded }
        try? saveConfig(config)
    }

    // MARK: - Scan

    private func scanDirectory(_ dir: String) -> [ProjectInfo] {
        guard !isPrivacySensitivePath(dir) else { return [] }

        let fm = FileManager.default
        let url = URL(fileURLWithPath: dir)
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { entry -> ProjectInfo? in
            let p = entry.path
            guard !isPrivacySensitivePath(p) else { return nil }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let hasClaude = fm.fileExists(atPath: (p as NSString).appendingPathComponent("CLAUDE.md"))
            let hasGit = fm.fileExists(atPath: (p as NSString).appendingPathComponent(".git"))
            guard hasClaude || hasGit else { return nil }
            let mtime = modificationDate(atPath: p)
            let name = entry.lastPathComponent
            return ProjectInfo(path: p, name: name, lastUsed: mtime, source: .scanned)
        }
    }

    // MARK: - Claude Code projects (original logic)

    private func claudeCodeProjects() -> [ProjectInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: claudeProjectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url -> ProjectInfo? in
            let encoded = url.lastPathComponent
            let decoded = decodeCCProjectPath(encoded)
            if !isPrivacySensitivePath(decoded) {
                guard fm.fileExists(atPath: decoded) else { return nil }
            }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let name = (decoded as NSString).lastPathComponent
            return ProjectInfo(path: decoded, name: name, lastUsed: mtime, source: .claudeCode)
        }
    }

    private func decodeCCProjectPath(_ encoded: String) -> String {
        var s = encoded
        if s.hasPrefix("-") {
            s = "/" + String(s.dropFirst())
        }
        s = s.replacingOccurrences(of: "-", with: "/")
        return s
    }

    // MARK: - Config I/O

    private func loadConfig() -> ProjectsConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(ProjectsConfig.self, from: data) else {
            return ProjectsConfig(scan_dirs: ["~/Projects"], manual: [])
        }
        return config
    }

    private func saveConfig(_ config: ProjectsConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: configURL, options: .atomic)
    }

    private func ensureConfig() {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        let config = ProjectsConfig(scan_dirs: ["~/Projects"], manual: [])
        try? saveConfig(config)
    }

    // MARK: - File Watcher

    private func watchConfig() {
        stop()
        let path = configURL.path
        if !FileManager.default.fileExists(atPath: path) {
            watchParentDir()
            return
        }
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedFD,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self = self, let source = source else { return }
            self.onChange?()
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self.watchConfig()
            }
        }
        source.setCancelHandler { close(watchedFD) }
        source.resume()
        fileSource = source
    }

    private func watchParentDir() {
        let dirPath = configURL.deletingLastPathComponent().path
        let dirFD = open(dirPath, O_EVTONLY)
        guard dirFD >= 0 else { return }
        fd = dirFD
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            if FileManager.default.fileExists(atPath: self.configURL.path) {
                self.watchConfig()
                self.onChange?()
            }
        }
        source.setCancelHandler { close(dirFD) }
        source.resume()
        fileSource = source
    }

    // MARK: - Helpers

    private func isTemporaryPath(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let roots = ["/private/tmp", "/private/var/tmp",
                     FileManager.default.temporaryDirectory.path]
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        return roots.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
    }

    private func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
        }
        return path
    }

    private func isPrivacySensitivePath(_ path: String) -> Bool {
        let normalized = (expandTilde(path) as NSString).standardizingPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sensitiveRoots = [
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
            "\(home)/Library/Mobile Documents",
        ]
        return sensitiveRoots.contains { root in
            normalized == root || normalized.hasPrefix(root + "/")
        }
    }

    private func modificationDate(atPath path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }
}
