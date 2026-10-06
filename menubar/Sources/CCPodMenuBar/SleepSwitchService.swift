import AppKit

/// 「合盖保持唤醒」开关。真源在系统（pmset 的 SleepDisabled），App 不落本地状态。
/// 三态：off / on / unavailable（helper 或 sudoers 未安装）。
final class SleepSwitchService: ObservableObject {
    static let shared = SleepSwitchService()

    enum State: Equatable {
        case off, on, unavailable
    }

    @Published private(set) var state: State = .unavailable
    /// 授权安装/开关操作进行中（UI 防连点）
    @Published private(set) var busy = false
    /// 状态变化回调（StatusController 用来刷菜单栏徽章），主线程调用
    var onChange: (() -> Void)?

    private let helperPath = "/usr/local/libexec/ccpod-sleep-switch"
    // 仓库路径假设固定在 ~/Projects/ccpod（本机事实）。若仓库搬家需同步改这里，
    // ccdoctor 的「保持唤醒」节会发现 helper/plist 对不上并报警。
    private let provisionerPath = NSHomeDirectory() + "/Projects/ccpod/scripts/sleep-switch/provision-sleep-switch.sh"

    /// 用户手动安装命令（复制到剪贴板用）
    var manualInstallCommand: String { "sudo \(provisionerPath) install" }

    private init() {}

    // MARK: - 状态查询

    /// 后台读系统真源，完成后主线程发布。App 启动、弹窗打开、操作后各调一次。
    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard FileManager.default.isExecutableFile(atPath: self.helperPath) else {
                self.publish(.unavailable)
                return
            }
            guard let (rc, out) = Self.run("/usr/bin/sudo", ["-n", self.helperPath, "status"], timeout: 5),
                  rc == 0 else {
                // sudo -n 失败 = sudoers 未装/被拆；绝不阻塞等密码
                self.publish(.unavailable)
                return
            }
            let next: State
            switch out.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "1": next = .on
            case "0": next = .off
            default:  next = .unavailable
            }
            self.publish(next)
        }
    }

    // MARK: - 开关

    func setOn(_ on: Bool) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = Self.run("/usr/bin/sudo", ["-n", self.helperPath, on ? "on" : "off"], timeout: 5)
            DispatchQueue.main.async { self.busy = false }
            // 不猜结果：重读系统状态，让 pmset 的值自己说话（验证纪律 #1）
            self.refresh()
        }
    }

    // MARK: - 一次性授权

    /// App 内弹系统密码框执行 provisioner install。completion 在主线程，true=授权成功。
    func provision(completion: @escaping (Bool) -> Void) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let src = "do shell script \"\(self.provisionerPath) install\" with administrator privileges"
            var err: NSDictionary?
            let ok = NSAppleScript(source: src)?.executeAndReturnError(&err) != nil
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                completion(ok)
            }
        }
    }

    /// 复制手动安装命令到剪贴板（AppKit 在 service 层，view 不用 import AppKit）
    func copyManualCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(manualInstallCommand, forType: .string)
    }

    private func publish(_ next: State) {
        DispatchQueue.main.async {
            guard next != self.state else { return }
            self.state = next
            self.onChange?()
        }
    }

    /// 与 ProjectDevelopmentActivity.git 同款：临时文件收输出 + semaphore 超时 + 强杀。
    /// 后台线程调用。返回 (退出码, stdout) 或 nil（启动失败/超时）。
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> (Int32, String)? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if done.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 1)
            }
            return nil
        }
        let data = (try? Data(contentsOf: output)) ?? Data()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
