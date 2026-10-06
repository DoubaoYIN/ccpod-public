import AppKit
import Foundation
import os

// CCRGatewayService — CCR 网关状态轮询（B 路线①，只读）。
// 数据源仅限：GET /health + ~/.claude/settings(.local).json 的生效默认模型。
// 硬约束：绝不写 ~/.claude-code-router/config.sqlite（见 model-gateway/docs/architecture.md）。
final class CCRGatewayService: ObservableObject {
    private static let logger = Logger(subsystem: "com.ccpod.menubar", category: "ccr-gateway")
    static let gatewayURL = URL(string: "http://127.0.0.1:3456")!

    enum Status {
        case unknown
        case running
        case down
    }

    @Published var status: Status = .unknown
    @Published var latencyMs: Int?
    @Published var defaultModel: String?
    @Published var checkedAt: Date?
    @Published var consoleURL: URL?
    @Published var lastError: String?

    private var timer: Timer?
    private let interval: TimeInterval = 30

    func start() {
        guard timer == nil else { return }
        Self.logger.info("gateway service started")
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 数据获取（只读）

    func refresh() {
        probeHealth()
        defaultModel = Self.readEffectiveDefaultModel()
        consoleURL = Self.readConsoleURL()
        GatewayLineService.shared.refresh()
    }

    private func probeHealth() {
        var request = URLRequest(url: Self.gatewayURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        let started = Date()
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            // 网关 200 即健康：响应体措辞随 CCR 版本变过（"ok"/"running"），不要对 body 挑措辞
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let errorMessage = error.map { "\($0.localizedDescription) (code \(($0 as? URLError)?.errorCode ?? -1))" }
                ?? (ok ? nil : "HTTP \(statusCode)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.status = ok ? .running : .down
                self.latencyMs = ok ? Int(Date().timeIntervalSince(started) * 1000) : nil
                self.checkedAt = Date()
                self.lastError = errorMessage
                if ok {
                    Self.logger.info("health probe: 200, \(self.latencyMs ?? 0)ms")
                } else {
                    Self.logger.error("health probe FAILED: \(errorMessage ?? "unknown", privacy: .public)")
                }
            }
        }.resume()
    }

    /// 生效默认模型：settings.local.json 覆盖 settings.json（与 Claude Code 实际读取优先级一致）。
    static func readEffectiveDefaultModel() -> String? {
        for path in ["~/.claude/settings.local.json", "~/.claude/settings.json"] {
            if let model = envValue(key: "ANTHROPIC_MODEL", in: path) { return model }
        }
        return nil
    }

    /// CCR 控制台 URL（service.json 由网关自身写入，token 随启动轮换）。
    static func readConsoleURL() -> URL? {
        let path = NSString(string: "~/.claude-code-router/service.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let url = obj["url"] as? String else { return nil }
        return URL(string: url)
    }

    static func openConsole() {
        guard let url = readConsoleURL() else { return }
        NSWorkspace.shared.open(url)
    }

    private static func envValue(key: String, in path: String) -> String? {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let env = obj["env"] as? [String: Any],
              let value = env[key] as? String, !value.isEmpty else { return nil }
        return value
    }
}
