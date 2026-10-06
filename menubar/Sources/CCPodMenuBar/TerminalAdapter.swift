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
    func openNewWindow(command: String, title: String?) throws
    func sendCommand(toTTY tty: String, command: String) throws
}

final class GhosttyAdapter: TerminalAdapter {
    let name = "Ghostty"
    let identifier = "ghostty"

    func openNewWindow(command: String, title: String? = nil) throws {
        var fullCommand = ""
        if let title = title {
            fullCommand += "\(terminalTitleCommand(title)); "
        }
        fullCommand += command
        let escapedFullCommand = appleScriptEscape(fullCommand)

        let script: String
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }

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
}

final class ITerm2Adapter: TerminalAdapter {
    let name = "iTerm2"
    let identifier = "iterm2"

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
}

final class TerminalAppAdapter: TerminalAdapter {
    let name = "Terminal"
    let identifier = "terminal"

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
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else {
        throw TerminalAdapterError.scriptFailed("无法创建 AppleScript")
    }
    script.executeAndReturnError(&error)
    if let error = error {
        let msg = error[NSAppleScript.errorMessage] as? String ?? "未知错误"
        throw TerminalAdapterError.scriptFailed(msg)
    }
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
