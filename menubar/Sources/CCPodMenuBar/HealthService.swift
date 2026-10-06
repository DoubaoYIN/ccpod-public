import Foundation

enum ProviderHealth {
    case unknown
    case ok
    case slow
    case exhausted
    case down
}

enum ProviderAvailabilityReason {
    case none
    case quotaExhaustedDaily
    case insufficientBalance
    case authRejected
    case rateLimited
    case unknownFailure

    var badgeText: String? {
        switch self {
        case .quotaExhaustedDaily: return "⛔ 已用尽"
        default: return nil
        }
    }

    var detailText: String? {
        switch self {
        case .quotaExhaustedDaily: return "今日订阅额度已用尽，次日恢复"
        case .insufficientBalance: return "余额不足，请充值"
        case .authRejected: return "Key 被拒绝或已失效"
        case .rateLimited: return "请求频率超限"
        case .unknownFailure: return "线路暂时不可用"
        case .none: return nil
        }
    }
}

struct HealthInfo {
    let provider: String
    let status: ProviderHealth
    let availabilityReason: ProviderAvailabilityReason
    let detail: String?
    let modelLatencies: [String: Int?]
    let checkedAt: Date

    var speedTooltip: String {
        if modelLatencies.isEmpty { return detail ?? "" }
        let order = modelLatencies.keys.sorted()
        var lines: [String] = []
        for key in order {
            guard let entry = modelLatencies[key] else { continue }
            let display = gatewayModelDisplayName(key)
            if let ms = entry {
                lines.append("\(display): \(ms)ms")
            } else {
                lines.append("\(display): 不可用")
            }
        }
        if let detail, !detail.isEmpty { lines.append(detail) }
        return lines.joined(separator: "\n")
    }
}

final class HealthService {
    static let shared = HealthService()

    private static let minimumCheckInterval: TimeInterval = 60

    var onUpdate: ((String, HealthInfo) -> Void)?
    private var observers: [UUID: (String, HealthInfo) -> Void] = [:]

    private let providersDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/providers", isDirectory: true)
    }()

    private let debugStateURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ccpod-health-debug.txt")
    }()

    private let session = URLSession(configuration: {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 20
        return c
    }())

    private let stateQueue = DispatchQueue(label: "ccpod.health-service.state")
    private var cache: [String: HealthInfo] = [:]
    private var inflight: Set<String> = []
    private var lastCheckedAt: [String: Date] = [:]
    private var debugResponses: [String: String] = [:]

    private let balanceEndpoints: [(GatewayType, String)] = [
        (.sub2api, "/v1/usage"),
        (.newapi, "/v1/dashboard/billing/subscription"),
        (.zenmux, "/api/v1/management/subscription/detail"),
    ]

    func probeModels(for provider: String) -> [String] {
        if let env = providerConfiguration(provider)?["env"] as? [String: Any],
           let model = env["ANTHROPIC_MODEL"] as? String, !model.isEmpty { return [model] }
        if let config = providerConfiguration(provider), isLocalGatewayConfiguration(config),
           let model = CCRGatewayService.readEffectiveDefaultModel() { return [model] }
        return ["claude-opus-4-6"]
    }

    func cached(_ provider: String) -> HealthInfo? {
        stateQueue.sync { cache[provider] }
    }

    @discardableResult
    func addObserver(_ handler: @escaping (String, HealthInfo) -> Void) -> UUID {
        let id = UUID()
        stateQueue.sync { observers[id] = handler }
        return id
    }

    func removeObserver(_ id: UUID?) {
        guard let id else { return }
        stateQueue.sync { _ = observers.removeValue(forKey: id) }
    }

    func refreshAll() { runAllChecks() }

    // MARK: - Check

    func check(_ provider: String, force: Bool = false) {
        if !force, let cached = cached(provider) {
            notify(provider, cached)
            return
        }
        if let config = providerConfiguration(provider), isLocalGatewayConfiguration(config) {
            // Local gateway liveness does not prove that an upstream model can answer.
            let info = HealthInfo(provider: provider, status: .unknown, availabilityReason: .none,
                                  detail: "经网关；上游状态见「线路检查」，模型可在「线路测速」验证",
                                  modelLatencies: [:], checkedAt: Date())
            store(info); notify(provider, info); return
        }
        guard let cfg = readConfig(provider) else {
            // 文案必须区分两种情况，否则用户不知道该去配线路还是去解锁钥匙串
            let info = HealthInfo(provider: provider, status: .unknown, availabilityReason: .none,
                                  detail: missingConfigDetail(provider), modelLatencies: [:], checkedAt: Date())
            store(info); notify(provider, info); return
        }
        guard beginCheck(provider, force: force) else { return }

        checkBalance(provider: provider, cfg: cfg) { [weak self] balanceOk, balanceReason, balanceDetail in
            guard let self else { return }
            let reasonDetail = balanceReason.detailText
            let info: HealthInfo
            if balanceReason == .quotaExhaustedDaily {
                info = HealthInfo(provider: provider, status: .exhausted, availabilityReason: balanceReason, detail: reasonDetail, modelLatencies: [:], checkedAt: Date())
            } else if balanceReason != .none {
                info = HealthInfo(provider: provider, status: .down, availabilityReason: balanceReason, detail: reasonDetail ?? balanceDetail ?? "线路不可用", modelLatencies: [:], checkedAt: Date())
            } else if balanceOk {
                info = HealthInfo(provider: provider, status: .ok, availabilityReason: .none, detail: balanceDetail, modelLatencies: [:], checkedAt: Date())
            } else {
                info = HealthInfo(provider: provider, status: .unknown, availabilityReason: .none, detail: balanceDetail ?? "未执行模型测速", modelLatencies: [:], checkedAt: Date())
            }
            self.store(info); self.endCheck(provider); self.notify(provider, info)
        }
    }

    // MARK: - Layer 1: Balance

    private func checkBalance(provider: String, cfg: Config, completion: @escaping (Bool, ProviderAvailabilityReason, String?) -> Void) {
        let paths: [String]
        if let gw = cfg.gateway, let path = balanceEndpoints.first(where: { $0.0 == gw })?.1 {
            paths = [path]
        } else {
            paths = balanceEndpoints.map { $0.1 }
        }
        let group = DispatchGroup()
        var success = false
        var reason: ProviderAvailabilityReason = .none
        var detail: String? = nil
        let lock = NSLock()

        for path in paths {
            group.enter()
            let url = cfg.url.appendingPathComponent(path)
            var req = URLRequest(url: url)
            req.setValue("Bearer \(cfg.key)", forHTTPHeaderField: "Authorization")
            session.dataTask(with: req) { data, resp, error in
                defer { group.leave() }
                if let error {
                    lock.lock()
                    if detail == nil {
                        let ns = error as NSError
                        switch ns.code {
                        case NSURLErrorTimedOut: detail = "[NSURLError -1001] 连接超时"
                        case NSURLErrorCannotFindHost: detail = "[NSURLError -1003] 域名解析失败"
                        case NSURLErrorCannotConnectToHost: detail = "[NSURLError -1004] 无法连接服务器"
                        case NSURLErrorNotConnectedToInternet: detail = "[NSURLError -1009] 无网络"
                        default: detail = "[NSURLError \(ns.code)] \(ns.localizedDescription)"
                        }
                    }
                    if reason == .none { reason = .unknownFailure }
                    lock.unlock()
                    return
                }
                guard let http = resp as? HTTPURLResponse else { return }
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let classified = self.classifyResponse(provider: provider, cfg: cfg, statusCode: http.statusCode, body: body)
                self.recordDebugResponse(key: "\(provider):balance", statusCode: http.statusCode, classified: classified, body: body)
                lock.lock()
                if http.statusCode == 200 {
                    success = true
                    if classified == .insufficientBalance {
                        reason = classified
                        detail = classified.detailText
                    }
                } else if classified == .insufficientBalance {
                    success = true
                    reason = classified
                    detail = classified.detailText
                } else if (cfg.gateway == nil || cfg.gateway == .unknown) && http.statusCode == 404 {
                    // Unknown gateway: balance endpoint mismatch isn't a fault.
                } else if detail == nil {
                    reason = classified == .none ? .unknownFailure : classified
                    detail = self.displayDetail(for: reason, fallback: "[\(http.statusCode)] Key 无效或已过期")
                }
                lock.unlock()
            }.resume()
        }
        group.notify(queue: .global()) { completion(success, reason, detail) }
    }

    // MARK: - Layer 2: Parallel model speed test

    private func probeAllModels(provider: String, cfg: Config, completion: @escaping ([String: Int?], ProviderAvailabilityReason, String?) -> Void) {
        let group = DispatchGroup()
        var results: [String: Int?] = [:]
        var lastError: String? = nil
        var reason: ProviderAvailabilityReason = .none
        let lock = NSLock()

        for model in probeModels(for: provider) {
            group.enter()
            let fullModel = model
            var req = URLRequest(url: cfg.url.appendingPathComponent("/v1/messages"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue(cfg.key, forHTTPHeaderField: "x-api-key")
            var body: [String: Any] = ["model": fullModel, "max_tokens": 1, "messages": [["role": "user", "content": "."]]]
            if needsSessionMetadata(provider: provider, cfg: cfg) {
                body["metadata"] = ["session_id": "ccpod-health-\(provider)"]
            }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let start = Date()
            session.dataTask(with: req) { [weak self] data, resp, error in
                defer { group.leave() }
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                lock.lock()
                if error != nil {
                    results[model] = Int?.none
                    let ns = (error! as NSError)
                    lastError = "[NSURLError \(ns.code)] \(ns.localizedDescription)"
                    if reason == .none { reason = .unknownFailure }
                } else if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    results[model] = elapsed
                } else if let http = resp as? HTTPURLResponse {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let lower = body.lowercased()
                    if lower.contains("model_not_allowed") || lower.contains("is not allowed for this api key") {
                        results[model] = Int?.none
                        self?.recordDebugResponse(key: "\(provider):probe:\(model)", statusCode: http.statusCode, classified: .none, body: body)
                    } else {
                        results[model] = Int?.none
                        let classified = self?.classifyResponse(provider: provider, cfg: cfg, statusCode: http.statusCode, body: body) ?? .unknownFailure
                        self?.recordDebugResponse(key: "\(provider):probe:\(model)", statusCode: http.statusCode, classified: classified, body: body)
                        if reason == .none || reason == .unknownFailure || classified == .quotaExhaustedDaily {
                            reason = classified
                        }
                        lastError = self?.translateError(provider: provider, cfg: cfg, data: data, statusCode: http.statusCode)
                    }
                }
                lock.unlock()
            }.resume()
        }
        group.notify(queue: .global()) { completion(results, reason, lastError) }
    }

    private func classifyResponse(provider: String, cfg: Config, statusCode: Int, body: String) -> ProviderAvailabilityReason {
        let lower = body.lowercased()
        if (statusCode == 403 || statusCode == 400) && lower.contains("error code: 1010") {
            return .quotaExhaustedDaily
        }
        if statusCode == 401,
           cfg.gateway == .newapi,
           cfg.url.host?.contains("easyclaude.com") == true,
           provider.hasPrefix("easycc_"),
           (lower.contains("无效的令牌") || lower.contains("invalid token")) {
            return .quotaExhaustedDaily
        }
        if lower.contains("invalid_api_key") || lower.contains("invalid api key") || lower.contains("unauthorized") || lower.contains("key 无效") {
            return .authRejected
        }
        if lower.contains("user agent not allowed") || lower.contains("only for use in claude code") {
            return .unknownFailure
        }
        if lower.contains("insufficient_balance") || lower.contains("余额不足") {
            return .insufficientBalance
        }
        if lower.contains("rate_limit") || lower.contains("rate limit") || statusCode == 429 {
            return .rateLimited
        }
        if statusCode == 401 || statusCode == 403 {
            return .authRejected
        }
        if statusCode >= 400 {
            return .unknownFailure
        }
        return .none
    }

    private func displayDetail(for reason: ProviderAvailabilityReason, fallback: String? = nil) -> String? {
        reason.detailText ?? fallback
    }

    private func translateError(provider: String, cfg: Config, data: Data?, statusCode: Int) -> String {
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let reason = classifyResponse(provider: provider, cfg: cfg, statusCode: statusCode, body: body)
        if let detail = reason.detailText { return "[\(statusCode)] \(detail)" }
        let lower = body.lowercased()
        if lower.contains("user agent not allowed") { return "[\(statusCode)] 客户端不被允许" }
        if lower.contains("only for use in claude code") { return "[\(statusCode)] 仅允许 Claude Code 客户端" }
        if lower.contains("no available accounts") || lower.contains("no available") { return "[\(statusCode)] 上游无可用账号" }
        if lower.contains("model_not_found") || lower.contains("not found") { return "[\(statusCode)] 网关不支持此模型" }
        if lower.contains("overloaded") { return "[\(statusCode)] 服务过载" }
        switch statusCode {
        case 401: return "[401] Key 未授权"
        case 403: return "[403] Key 被拒绝"
        case 429: return "[429] 频率超限"
        case 500: return "[500] 服务器内部错误"
        case 502: return "[502] 网关错误"
        case 503: return "[503] 服务不可用"
        case 504: return "[504] 网关超时"
        default: return "[HTTP \(statusCode)] 请求失败"
        }
    }

    // MARK: - Public speed test

    func runSpeedTest(provider: String, completion: @escaping ([String: Int?], String?) -> Void) {
        // Resolving keychain/apiKeyHelper can block; keep it off the UI thread.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cfg = self.readConfig(provider) else {
                completion([:], self.missingConfigDetail(provider))
                return
            }
            guard self.beginCheck(provider, force: true) else {
                completion([:], "测速正在进行，请稍后再试")
                return
            }
            self.probeAllModels(provider: provider, cfg: cfg) { results, _, detail in
                self.endCheck(provider)
                completion(results, detail)
            }
        }
    }

    func allProviderNames() -> [String] { listProviderNames() }

    // MARK: - Infra

    private func runAllChecks() { for name in listProviderNames() { check(name, force: true) } }

    private func listProviderNames() -> [String] { ProviderService().availableProviders() }

    private struct Config { let url: URL; let key: String; let gateway: GatewayType? }

    /// 拿不到配置的真实原因。密钥在钥匙串（$exec）却取不到时，明确说出来并给出动作，
    /// 不要和"这条线路没配 key"混成一句话——那是本项目被投诉过多次的"误导性反馈"。
    private func missingConfigDetail(_ name: String) -> String {
        let file = providersDir.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any] else { return "无配置文件" }
        let keyIsSecretRef = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_TOKEN"]
            .contains { env[$0] is [String: Any] }
        if keyIsSecretRef {
            let reason = SecretResolver.lastFailureReason ?? "原因未知"
            return "密钥读取失败（\(reason)）；若钥匙串被锁定，解锁后点「重新检测」"
        }
        if isLocalGatewayConfiguration(json) { return "网关鉴权不可用，请检查网关登录或钥匙串" }
        if env["ANTHROPIC_BASE_URL"] == nil { return "缺少 BASE_URL" }
        return "无配置或缺少 key"
    }

    private func readConfig(_ name: String) -> Config? {
        guard isValidProviderID(name) else { return nil }
        let file = providersDir.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any],
              let urlStr = SecretResolver.value(from: env["ANTHROPIC_BASE_URL"]), !urlStr.isEmpty,
              let url = URL(string: urlStr) else { return nil }
        // 原来强转 [String: String]：一遇到 $exec 就整体失败 → readConfig 恒 nil →
        // 健康检查/测速对这些线路永远显示"无配置或缺少 key"，线路真的挂了也检测不到
        let hasOwnKey = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_TOKEN"].contains { env[$0] != nil }
        let key = SecretResolver.value(from: env["ANTHROPIC_API_KEY"])
            ?? SecretResolver.value(from: env["ANTHROPIC_AUTH_TOKEN"])
            ?? SecretResolver.value(from: env["ANTHROPIC_API_TOKEN"])
            ?? (!hasOwnKey && isLocalGatewayConfiguration(json) ? gatewayKey() : nil) ?? ""
        guard !key.isEmpty else { return nil }
        let gw: GatewayType? = (json["gateway"] as? String).flatMap { GatewayType(rawValue: $0) }
        return Config(url: url, key: key, gateway: gw)
    }

    private func gatewayKey() -> String? {
        // Same settings precedence as the launch path. Never persist helper output.
        var settings: [String: Any] = [:]
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        for name in ["settings.json", "settings.local.json"] {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name)),
                  let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            settings.merge(item) { _, next in next }
        }
        guard let command = settings["apiKeyHelper"] as? String, !command.isEmpty else { return nil }
        return SecretResolver.run(command)
    }

    private func needsSessionMetadata(provider: String, cfg: Config) -> Bool {
        provider.lowercased() == "yescode" || (cfg.url.host?.lowercased().contains("co.yes.vg") ?? false)
    }

    private func store(_ info: HealthInfo) {
        stateQueue.sync {
            cache[info.provider] = info
            writeDebugSnapshot()
        }
    }
    private func notify(_ p: String, _ i: HealthInfo) {
        let callbacks = stateQueue.sync { Array(observers.values) }
        onUpdate?(p, i)
        callbacks.forEach { $0(p, i) }
    }
    private func beginCheck(_ p: String, force: Bool) -> Bool {
        stateQueue.sync {
            guard !inflight.contains(p) else { return false }
            // force 必须真的跳过节流：这个参数原来声明了却从未被使用，
            // 于是 60 秒内点「重新检测」既没反应也没提示（用户投诉过"点按不动"这一类）
            if !force, let last = lastCheckedAt[p],
               Date().timeIntervalSince(last) < Self.minimumCheckInterval {
                return false
            }
            lastCheckedAt[p] = Date()
            inflight.insert(p)
            return true
        }
    }
    private func endCheck(_ p: String) { stateQueue.sync { _ = inflight.remove(p) } }

    private func recordDebugResponse(key: String, statusCode: Int, classified: ProviderAvailabilityReason, body: String) {
        let trimmed = body.replacingOccurrences(of: "\n", with: " ").prefix(160)
        stateQueue.sync {
            debugResponses[key] = "status=\(statusCode) classified=\(classified) body=\(trimmed)"
            writeDebugSnapshot()
        }
    }

    private func writeDebugSnapshot() {
        let stateLines = cache.keys.sorted().compactMap { key -> String? in
            guard let info = cache[key] else { return nil }
            let detail = info.detail ?? ""
            return "STATE\t\(key)\tstatus=\(info.status)\treason=\(info.availabilityReason)\tdetail=\(detail)"
        }
        let responseLines = debugResponses.keys.sorted().compactMap { key -> String? in
            guard let value = debugResponses[key] else { return nil }
            return "RESP\t\(key)\t\(value)"
        }
        try? (stateLines + responseLines).joined(separator: "\n").write(to: debugStateURL, atomically: true, encoding: String.Encoding.utf8)
    }
}
