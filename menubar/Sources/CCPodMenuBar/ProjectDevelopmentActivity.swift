import Foundation

/// 从本地代码变更估算开发活跃度；不把打开目录、聊天、笔记同步算作开发。
struct ProjectDevelopmentActivity {
    let dates: [Date]
    let unavailable: Bool
    var latest: Date? { dates.max() }

    func score(at now: Date) -> Double {
        // 每个开发日只计一次，避免拆分提交或大量生成文件把排序刷高。
        let days = Set(dates.map { Calendar.current.startOfDay(for: $0) })
        return days.reduce(0) { result, day in
            let age = max(0, now.timeIntervalSince(day) / 86_400)
            return result + pow(0.5, age / 7)
        }
    }

    private static let extensions = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "py",
        "js", "jsx", "ts", "tsx", "vue", "svelte", "html", "css", "scss",
        "java", "kt", "kts", "rb", "php", "sh", "bash", "zsh", "fish", "sql",
        "dart", "ex", "exs", "cs", "fs", "lua", "r", "R", "ipynb"
    ]
    private static let buildFiles = ["Package.swift", "Package.resolved", "package.json",
        "Cargo.toml", "go.mod", "pyproject.toml", "Makefile", "CMakeLists.txt", "Dockerfile"]
    private static let excluded = [".git", ".local", ".claude", ".codex", "node_modules",
        "vendor", "build", "dist", ".build", "DerivedData", ".venv", "venv", "__pycache__",
        "raw-sources", "archive", "archives", "backups"]

    static func isDevelopmentFile(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains(where: { excluded.contains($0) }) else { return false }
        let file = (path as NSString).lastPathComponent
        return buildFiles.contains(file) || extensions.contains((file as NSString).pathExtension)
    }

    static func read(path: String) -> Self {
        // 只认项目自身的仓库，避免 Git 向父目录查找把别的项目算进来。
        guard FileManager.default.fileExists(atPath: path + "/.git") else {
            return Self(dates: [], unavailable: false)
        }
        let includes = extensions.map { "*." + $0 } + buildFiles
        let excludes = excluded.map { ":(exclude,glob)**/" + $0 + "/**" }
        let log = git(path, ["log", "-200", "--format=%ct", "--"] + includes + excludes)
        guard let status = git(path, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]) else {
            return Self(dates: [], unavailable: true)
        }
        var dates = String(decoding: log ?? Data(), as: UTF8.self).split(separator: "\n")
            .compactMap { TimeInterval($0).map(Date.init(timeIntervalSince1970:)) }
        let records = String(decoding: status, as: UTF8.self).split(separator: "\0")
        var index = 0
        while index < records.count {
            let record = String(records[index])
            index += 1
            guard record.count >= 4 else { continue }
            let code = String(record.prefix(2))
            let relative = String(record.dropFirst(3))
            // -z 的重命名/复制另有一个原路径字段。
            if code.contains("R") || code.contains("C") { index += 1 }
            guard isDevelopmentFile(relative),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path + "/" + relative),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let date = attrs[.modificationDate] as? Date else { continue }
            dates.append(date)
        }
        return Self(dates: dates, unavailable: false)
    }

    /// 仅后台调用。有超时且不用未消费的管道，防止 Git 卡住菜单栏或填满 stdout。
    private static func git(_ path: String, _ arguments: [String]) -> Data? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", path] + arguments
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + 3) == .timedOut {
            if process.isRunning { process.terminate() }
            if done.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 1)
            }
            return nil
        }
        guard process.terminationStatus == 0,
              let reader = try? FileHandle(forReadingFrom: output) else { return nil }
        defer { try? reader.close() }
        do {
            // 干净工作区的 git status 成功但 stdout 为空，EOF 不代表命令失败。
            return try reader.read(upToCount: 8 * 1_024 * 1_024) ?? Data()
        } catch { return nil }
    }
}
