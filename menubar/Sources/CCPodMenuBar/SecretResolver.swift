import Foundation

/// 解析配置里的密钥取值。约定与 `scripts/lib/common.sh` 的 `get_provider_env` **完全一致**：
/// 值可以是明文字符串，也可以是 `{"$exec": "命令"}` —— 后者在运行时执行命令取 stdout。
///
/// 为什么要支持 `$exec`：这样密钥只存在钥匙串里，磁盘上的 json 一个字节的明文都不留。
/// 发布给别人用时这点很关键——明文 json 一旦被备份、同步、截图或误提交，密钥就出去了。
///
/// ⚠️ 取不到值一律返回 nil（**不静默回退**到别的来源），让调用方按"没有 key"处理并如实显示。
/// 静默回退正是历史上"claude 以无 key 启动、悄悄用掉无限额 key"那个事故的形状。
enum SecretResolver {
    /// 解析结果的缓存。余额查询（主 RunLoop 定时器）与健康检查（按钮动作）都会从
    /// **主线程**同步调进来，每次都 spawn `/bin/sh` + `security` 会造成周期性卡顿，
    /// 所以同一条命令 10 分钟内只跑一次。失败结果只缓存 30 秒（钥匙串可能只是暂时被锁，
    /// 缓存太久会让线路长时间显示成"没有 key"）。
    private static let lock = NSLock()
    private static var cache: [String: (value: String?, at: Date)] = [:]
    private static let successTTL: TimeInterval = 600
    /// 失败缓存 3 分钟：钥匙串被锁不会自己好，30 秒过期会让「线路测速」每半分钟
    /// 就把 N 条线路各卡 3 秒重来一遍（4 条 = 12 秒冻结）。用户解锁后由 invalidateCache 立即恢复。
    private static let failureTTL: TimeInterval = 180
    /// `waitUntilExit()` 会无限等：钥匙串被锁、或 security 需要授权弹窗时会把调用线程
    /// （可能是主线程）永久挂住 → 菜单栏 beachball 且无法退出。必须有界等待。
    private static let runTimeout: TimeInterval = 3

    static func value(from raw: Any?) -> String? {
        if let text = raw as? String { return text.isEmpty ? nil : text }
        guard let dict = raw as? [String: Any],
              let command = dict["$exec"] as? String, !command.isEmpty else { return nil }
        lock.lock()
        if let hit = cache[command] {
            let ttl = hit.value == nil ? failureTTL : successTTL
            if Date().timeIntervalSince(hit.at) < ttl {
                lock.unlock()
                return hit.value
            }
        }
        lock.unlock()
        let resolved = run(command)
        lock.lock()
        if resolved != nil { lastFailureReason = nil }
        cache[command] = (resolved, Date())
        lock.unlock()
        return resolved
    }

    /// 密钥换了（ccpod-key set/use 之后）调用，避免最长 10 分钟读到旧值
    static func invalidateCache() {
        lock.lock(); cache.removeAll(); lastFailureReason = nil; lock.unlock()
    }

    /// 最近一次 $exec 失败的原因。**只用于拼给用户看的提示**（诊断信息，不参与控制流）：
    /// "没配 key" 和 "key 在钥匙串但取不到" 的处置动作完全不同——前者要去配线路，
    /// 后者要解锁钥匙串；混成一句「无配置或缺少 key」用户根本不知道该干什么。
    private(set) static var lastFailureReason: String?

    /// 执行 `$exec` 里的命令取 stdout。这会执行配置文件写明的命令——信任模型与 shell 侧一致：
    /// 配置文件属用户自己、权限 600，能改它的人本来就能改你的 shell 配置。
    /// 失败（非零退出 / 空输出）返回 nil，由调用方决定怎么如实呈现。
    static func run(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // 有界等待 + 超时杀进程，绝不无限等（见 runTimeout 注释）。
        // security -w 只输出一行，pipe 缓冲不会被写满，所以先等后读不会死锁。
        let deadline = Date().addingTimeInterval(runTimeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            NSLog("ccpod: $exec 取密钥超时（>\(runTimeout)s），已中止: \(command)")
            setFailure("命令超时 >\(Int(runTimeout))s，可能是钥匙串被锁定")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            // 不把 stderr 也丢掉：静默失败正是本项目反复踩的坑，至少留一条日志可查
            NSLog("ccpod: $exec 取密钥失败（退出码 \(process.terminationStatus)）: \(command)")
            setFailure("命令退出码 \(process.terminationStatus)（钥匙串条目不存在或被锁定）")
            return nil
        }
        guard let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            NSLog("ccpod: $exec 取密钥返回空: \(command)")
            setFailure("命令返回空值")
            return nil
        }
        return out
    }

    private static func setFailure(_ reason: String) {
        lock.lock(); lastFailureReason = reason; lock.unlock()
    }

    /// 写入钥匙串。`-T /usr/bin/security` 让之后用 security 读取时不弹授权框；
    /// `-U` 表示同名条目直接更新（换 key 的场景）。
    static func storeKeychain(service: String, secret: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["add-generic-password", "-a", NSUserName(), "-s", service,
                             "-w", secret, "-U", "-T", "/usr/bin/security"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "keychain", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "写钥匙串失败（退出码 \(process.terminationStatus)）"])
        }
    }

    /// 回读校验：写进去和读出来必须一致，否则宁可报错也不要把引用写进配置文件
    /// （那会留下一条"看起来配好了、其实取不到 key"的线路）
    static func readKeychain(service: String) -> String? {
        run("security find-generic-password -s \(service) -w 2>/dev/null")
    }

    /// 钥匙串取密钥的标准命令。`-T /usr/bin/security` 让 security 工具免弹窗读取。
    /// 不带 `-a "$USER"`：GUI/launchd 启动的进程环境里 USER 可能不存在，会静默取不到。
    static func keychainCommand(service: String) -> String {
        "security find-generic-password -s \(service) -w 2>/dev/null"
    }
}

/// 落盘 / 回显前的密钥脱敏。与 python 侧 `scripts/claude-rename` 用的是同一套模式。
/// 保留前 6 位便于用户辨认是哪把钥匙，但不足以复原。
enum SecretRedactor {
    private static let patterns = [
        "(?<![A-Za-z0-9])((?:yes)?sk-[A-Za-z0-9_\\-.]{6})[A-Za-z0-9_\\-.]{4,}",
        "(ark-[a-f0-9\\-]{6})[a-f0-9\\-]{4,}",
        "\\b(c?cr[_\\-][A-Za-z0-9_\\-]{6})(?=[A-Za-z0-9_\\-]*[0-9])[A-Za-z0-9_\\-]{8,}",
        "\\b([0-9a-f]{6})[0-9a-f]{26}\\.[A-Za-z0-9]{16}\\b",
        "(Bearer\\s+)[A-Za-z0-9_\\-.]{12,}",
    ]

    static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: "$1***REDACTED***")
        }
        return out
    }
}
