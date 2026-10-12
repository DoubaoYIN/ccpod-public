import AppKit

enum TerminalAdapterError: Error, CustomStringConvertible {
    case scriptFailed(String)
    case terminalNotRunning(String)

    var description: String {
        switch self {
        case .scriptFailed(let msg): return msg
        case .terminalNotRunning(let name): return "\(name) 未运行"
        }
    }
}

protocol TerminalAdapter {
    var name: String { get }
    var identifier: String { get }
    /// 终端 App 的 bundle id，用来判断它在不在运行。AppleScript `tell application` 会把没在跑的
    /// App 拉起来，所以"找窗口"这类只读动作之前必须先问 `isRunning`。
    var bundleIdentifier: String { get }
    func openNewWindow(command: String, title: String?) throws
    func sendCommand(toTTY tty: String, command: String) throws
    /// 把跑在 `tty` 上的那个分屏/标签页/窗口切到前台。
    /// 返回 false = 这个终端里没有这条 tty（会话可能在别的终端里）；抛错 = 脚本本身失败。
    func focusSession(tty: String, hint: SessionFocusHint) throws -> Bool
}

extension TerminalAdapter {
    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }
}

/// 定位分屏的辅助信息。iTerm2 / Terminal.app 的分屏有 `tty` 属性，按 tty 精确对；
/// Ghostty 的 terminal **没有 tty 属性**（2026-10-05 实测），只能按名字对——名字就是 session-hud hook
/// 用 OSC 2 写上去的那个标题（同时落在 `/tmp/claude-tab-state/<tty小名>.json` 的 `title`）；
/// 名字对不上时再按工作目录兜底，且只认唯一命中。
struct SessionFocusHint {
    var title: String?
    var projectPath: String?
}

/// 统一成 iTerm2 / Terminal.app 返回的全路径形态（登记表存 `/dev/ttys003`，发现层存 `ttys003`）。
func normalizedTTYPath(_ tty: String) -> String {
    tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
}

final class GhosttyAdapter: TerminalAdapter {
    let name = "Ghostty"
    let identifier = "ghostty"
    let bundleIdentifier = "com.mitchellh.ghostty"

    func openNewWindow(command: String, title: String? = nil) throws {
        var fullCommand = ""
        if let title = title {
            fullCommand += "\(terminalTitleCommand(title)); "
        }
        fullCommand += command
        let escapedFullCommand = appleScriptEscape(fullCommand)

        let script: String

        if isRunning {
            script = """
            tell application "Ghostty"
                activate
                set cfg to new surface configuration from {initial input:"\(escapedFullCommand)" & (ASCII character 13)}
                new window with configuration cfg
            end tell
            """
        } else {
            script = """
            tell application "Ghostty"
                activate
            end tell
            delay 1.5
            tell application "Ghostty"
                set term to focused terminal of selected tab of front window
                input text "\(escapedFullCommand)" & (ASCII character 13) to term
            end tell
            """
        }
        try runAppleScript(script)
    }

    func sendCommand(toTTY tty: String, command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        if tty != "unknown", FileManager.default.isWritableFile(atPath: tty) {
            // \r (carriage return) is what terminals interpret as Enter
            let data = (command + "\r").data(using: .utf8)!
            guard let fh = FileHandle(forWritingAtPath: tty) else {
                throw TerminalAdapterError.scriptFailed("无法写入 \(tty)")
            }
            fh.write(data)
            fh.closeFile()
        } else {
            let script = """
            tell application "Ghostty"
                set term to focused terminal of selected tab of front window
                set cmd to "\(escaped)" & (ASCII character 10)
                input text cmd to term
            end tell
            """
            try runAppleScript(script)
        }
    }

    /// 两步走（与 session-hud hook 同一套路）：先把所有分屏的 id/名字/工作目录倒出来在 Swift 里挑，
    /// 再按 `terminal id` 下 `focus`（sdef：Focus a terminal, bringing its window to the front）。
    /// 名字匹配区分大小写、要完全相等；目录匹配只认唯一命中——同一项目开两个分屏时宁可说"找不到"，
    /// 也不能把用户切到错的那个。
    func focusSession(tty: String, hint: SessionFocusHint) throws -> Bool {
        guard isRunning else { return false }
        let dump = """
        set TB to character id 9
        set out to ""
        tell application id "com.mitchellh.ghostty"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        repeat with s in terminals of t
                            set nm to ""
                            set wd to ""
                            try
                                set nm to (name of s as text)
                            end try
                            try
                                set wd to (working directory of s as text)
                            end try
                            set out to out & (id of s as text) & TB & nm & TB & wd & linefeed
                        end repeat
                    end try
                end repeat
            end repeat
        end tell
        return out
        """
        let rows = try runAppleScriptReturningString(dump)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count == 3 }
        var target: String?
        if let title = hint.title, !title.isEmpty,
           let byName = rows.first(where: { $0[1] == title }) {
            target = byName[0]
        } else if let project = hint.projectPath, !project.isEmpty {
            let want = Self.normalizedDirectory(project)
            let byDir = rows.filter { Self.normalizedDirectory($0[2]) == want }
            if byDir.count == 1 { target = byDir[0][0] }
        }
        guard let id = target else { return false }
        let focus = """
        tell application id "com.mitchellh.ghostty"
            focus (terminal id "\(appleScriptEscape(id))")
            activate
        end tell
        """
        try runAppleScript(focus)
        return true
    }

    /// `working directory` 可能是 POSIX 路径也可能是 file:// URL（未实测哪一种），两种都归一到无尾斜杠的 POSIX 路径。
    private static func normalizedDirectory(_ raw: String) -> String {
        var path = raw
        if let url = URL(string: raw), url.isFileURL { path = url.path }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

final class ITerm2Adapter: TerminalAdapter {
    let name = "iTerm2"
    let identifier = "iterm2"
    let bundleIdentifier = "com.googlecode.iterm2"

    func openNewWindow(command: String, title: String? = nil) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var script = """
        tell application "iTerm2"
            activate
            create window with default profile
            tell current session of current window
                write text "\(escaped)"
        """
        if let title = title {
            let t = title.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script += "\n            set name to \"\(t)\""
        }
        script += """

            end tell
        end tell
        """
        try runAppleScript(script)
    }

    func sendCommand(toTTY tty: String, command: String) throws {
        if tty != "unknown", FileManager.default.isWritableFile(atPath: tty) {
            let data = (command + "\r").data(using: .utf8)!
            guard let fh = FileHandle(forWritingAtPath: tty) else {
                throw TerminalAdapterError.scriptFailed("无法写入 \(tty)")
            }
            fh.write(data)
            fh.closeFile()
        } else {
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            tell application "iTerm2"
                tell current session of current window
                    write text "\(escaped)"
                end tell
            end tell
            """
            try runAppleScript(script)
        }
    }

    /// 按 tty 找分屏：`select` 分屏 → 标签页 → 窗口（先取消最小化），最后 `activate`。
    /// 已结束的分屏取 `tty` 会抛 -1700，不 try 整段脚本就中断（session-hud 10-04 实测），所以逐个 try。
    func focusSession(tty: String, hint: SessionFocusHint) throws -> Bool {
        guard isRunning else { return false }
        let want = appleScriptEscape(normalizedTTYPath(tty))
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set tt to ""
                        try
                            set tt to (tty of s as text)
                        end try
                        if tt is "\(want)" then
                            select s
                            select t
                            try
                                if miniaturized of w then set miniaturized of w to false
                            end try
                            select w
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "none"
        """
        return try runAppleScriptReturningString(script) == "ok"
    }
}

final class TerminalAppAdapter: TerminalAdapter {
    let name = "Terminal"
    let identifier = "terminal"
    let bundleIdentifier = "com.apple.Terminal"

    func openNewWindow(command: String, title: String? = nil) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        try runAppleScript(script)
    }

    func sendCommand(toTTY tty: String, command: String) throws {
        if tty != "unknown", FileManager.default.isWritableFile(atPath: tty) {
            let data = (command + "\r").data(using: .utf8)!
            guard let fh = FileHandle(forWritingAtPath: tty) else {
                throw TerminalAdapterError.scriptFailed("无法写入 \(tty)")
            }
            fh.write(data)
            fh.closeFile()
        } else {
            throw TerminalAdapterError.scriptFailed("无法向 Terminal.app 发送命令（TTY 未知）")
        }
    }

    /// Terminal.app 的 tab 有 `tty`，window 有可写的 `frontmost`。
    /// ⚠️ 本机不用 Terminal.app，这条分支未实机验证。
    func focusSession(tty: String, hint: SessionFocusHint) throws -> Bool {
        guard isRunning else { return false }
        let want = appleScriptEscape(normalizedTTYPath(tty))
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    set tt to ""
                    try
                        set tt to (tty of t as text)
                    end try
                    if tt is "\(want)" then
                        set selected of t to true
                        try
                            if miniaturized of w then set miniaturized of w to false
                        end try
                        set frontmost of w to true
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "none"
        """
        return try runAppleScriptReturningString(script) == "ok"
    }
}

final class TerminalRegistry {
    static let shared = TerminalRegistry()

    let adapters: [TerminalAdapter] = [
        GhosttyAdapter(),
        ITerm2Adapter(),
        TerminalAppAdapter(),
    ]

    /// 默认终端：iTerm2（用户指定）。改这一处即可切换默认，列表顺序保持不变。
    var defaultAdapter: TerminalAdapter {
        adapters.first { $0.identifier == "iterm2" } ?? adapters[0]
    }

    func adapter(for identifier: String) -> TerminalAdapter? {
        adapters.first { $0.identifier == identifier }
    }
}

private func runAppleScript(_ source: String) throws {
    _ = try runAppleScriptReturningString(source)
}

/// 执行并取回脚本的 `return` 文本（没有返回值时为空串）。
private func runAppleScriptReturningString(_ source: String) throws -> String {
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else {
        throw TerminalAdapterError.scriptFailed("无法创建 AppleScript")
    }
    let result = script.executeAndReturnError(&error)
    if let error = error {
        let msg = error[NSAppleScript.errorMessage] as? String ?? "未知错误"
        throw TerminalAdapterError.scriptFailed(msg)
    }
    return result.stringValue ?? ""
}

private func shellQuote(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}

private func terminalTitleCommand(_ title: String) -> String {
    "printf '\\033]2;%s\\007' \(shellQuote(title))"
}

private func appleScriptEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}
