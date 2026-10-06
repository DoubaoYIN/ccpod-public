import Foundation

// 数据模型（QuotaWindow / QuotaPeriod / BalanceInfo / QuotaStatus）与纯函数解析器在 QuotaAdapters.swift。
//
// 凭证来源两条：
//   直连管线（deepseek.json / Dragoncode.json …）= provider json 的 env（SecretResolver 解析 $exec）
//   网关管线（gw-*）= CCR 管理 RPC getConfig 的 Providers[]（gw-* 文件本身只有 127.0.0.1，没有上游 key；
//     09-25 迁 CCR 后这里曾静默返回 nil，所有网关管线都查不到额度）。绝不直读 config.sqlite。
// 结果键（quota key）：网关管线 = CCR provider 名（glm/kimi/…，gw-* 经 gateway_provider 映射），直连 = 文件名。
// key 只在一次查询内存在于内存：不进 cache、不进 sidecar、不进日志或错误文案。

enum GatewayType: String, Codable {
    case sub2api
    case newapi
    case zenmux
    case unknown
}

final class BalanceService {
    static let shared = BalanceService()

    private static let minimumFetchInterval: TimeInterval = 60
    private static let shortFailureCooldown: TimeInterval = 60 * 60
    private static let longFailureCooldown: TimeInterval = 6 * 60 * 60
    /// YesCode 的 Cloudflare 对非浏览器 UA 直接 1010 拒绝（2026-10-02 实测）。
    private static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    /// (quota key, info)。quota key 见文件头。
    var onUpdate: ((String, BalanceInfo) -> Void)?

    private let providersDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/providers", isDirectory: true)
    }()

    private let quotaSidecarURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ccpod-quota.json")
    }()

    private let session = URLSession(configuration: {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        return c
    }())

    private let stateQueue = DispatchQueue(label: "ccpod.balance-service.state")
    /// 解析凭证（含同步的 getConfig RPC）放这条串行后台队列，绝不在主线程做。
    private let workQueue = DispatchQueue(label: "ccpod.balance-service.work", qos: .utility)
    private var detectedTypes: [String: GatewayType] = [:]
    private var probing: Set<String> = []
    private var cache: [String: BalanceInfo] = [:]
    private var lastFetchedAt: [String: Date] = [:]
    private var cooldownUntil: [String: Date] = [:]
    private var quotaKeys: [String: String] = [:]
    /// 同一 (主机, key) 的在途查询：dragoncode / dragon-grok 共用一个账户只查一次。
    private var inflight: [String: [(name: String, completion: (BalanceInfo?) -> Void)]] = [:]

    private struct Target {
        let config: ProviderConfig
        let kind: QuotaKind
    }

    // MARK: - Public

    /// gw-* → CCR provider 名；其他原样返回。
    func quotaKey(for provider: String) -> String {
        if let known = stateQueue.sync(execute: { quotaKeys[provider] }) { return known }
        var key = provider
        if providerFileExists(provider),
           let data = try? Data(contentsOf: providersDir.appendingPathComponent("\(provider).json")),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let gateway = json["gateway_provider"] as? String, !gateway.isEmpty {
            key = gateway
        }
        stateQueue.sync { quotaKeys[provider] = key }
        return key
    }

    func fetchBalance(provider: String, force: Bool = false, completion: @escaping (BalanceInfo?) -> Void) {
        let name = quotaKey(for: provider)
        if !force, let cached = cached(name) {
            completion(cached)
            return
        }
        workQueue.async { [weak self] in
            guard let self else { return }
            guard let target = self.resolveTarget(name) else {
                completion(self.cached(name))
                return
            }
            guard self.beginFetch(provider: name, respectCooldown: false) else {
                completion(self.cached(name))
                return
            }
            self.run(target: target, name: name, allowProbe: true, completion: completion)
        }
    }

    func cached(_ provider: String) -> BalanceInfo? {
        let name = quotaKey(for: provider)
        return stateQueue.sync { cache[name] }
    }

    func refreshAll() {
        for provider in allProviders() {
            fetchBalance(provider: provider, force: true) { _ in }
        }
    }

    /// 后台定时刷新：给定管线 + （可选）CCR 全部上游管线。尊重失败冷却；
    /// 三路盲探只在从未探测过时做一次，探不出就不再每小时重试。
    func refreshKnown(providers: [String], includeGatewayLines: Bool = false) {
        let names = Set(providers.map { quotaKey(for: $0) })
        workQueue.async { [weak self] in
            guard let self else { return }
            var all = names
            if includeGatewayLines {
                all.formUnion(self.gatewayLines().keys)
            }
            for name in all.sorted() {
                self.refreshKnown(name: name)
            }
        }
    }

    func resetDetection(provider: String) {
        let name = quotaKey(for: provider)
        stateQueue.sync { detectedTypes[name] = nil }
    }

    private func refreshKnown(name: String) {
        guard let target = resolveTarget(name) else { return }
        if case .probe = target.kind, cachedType(for: name) == .unknown { return }
        guard beginFetch(provider: name, respectCooldown: true) else { return }
        run(target: target, name: name, allowProbe: true, completion: { _ in })
    }

    // MARK: - Dispatch

    private func run(target: Target, name: String, allowProbe: Bool, completion: @escaping (BalanceInfo?) -> Void) {
        if case .fixed(let status) = target.kind {
            // 规则表已知"查不了"：一个请求都不发，只把原因存下来给 UI
            let info = BalanceInfo.status(status, provider: name)
            store(info)
            completion(info)
            return
        }
        guard !target.config.apiKey.isEmpty else {
            let info = BalanceInfo.status(.failed(reason: "没有找到这条管线的 key"), provider: name)
            storeFailure(info)
            completion(cached(name))
            return
        }

        // 同账户去重：签名只用 key 的进程内 hash，不落盘
        let signature = "\(target.kind)|\(target.config.baseURL.host ?? "")|\(target.config.apiKey.hashValue)"
        let isLeader: Bool = stateQueue.sync {
            if inflight[signature] != nil {
                inflight[signature]?.append((name, completion))
                return false
            }
            inflight[signature] = [(name, completion)]
            return true
        }
        guard isLeader else { return }

        let finish: (BalanceInfo?) -> Void = { [weak self] info in
            guard let self else { return }
            let waiters = self.stateQueue.sync { () -> [(name: String, completion: (BalanceInfo?) -> Void)] in
                let list = self.inflight[signature] ?? []
                self.inflight[signature] = nil
                return list
            }
            for waiter in waiters {
                if let info {
                    let renamed = self.renamed(info, to: waiter.name)
                    if renamed.status == .ok {
                        self.store(renamed)
                    } else {
                        self.storeFailure(renamed)
                    }
                }
                waiter.completion(self.cached(waiter.name))
            }
        }

        switch target.kind {
        case .glmPlan, .kimiCoding, .deepseekBalance, .minimaxPlan:
            fetchAdapter(kind: target.kind, name: name, config: target.config, completion: finish)
        case .aliyunTokenPlan:
            fetchAliyunTokenPlan(name: name, completion: finish)
        case .yescodePlan:
            fetchYescode(name: name, baseURL: target.config.baseURL, completion: finish)
        case .probe:
            if let type = cachedType(for: name), type != .unknown {
                fetchWith(type: type, provider: name, config: target.config, completion: finish)
            } else if allowProbe {
                probe(provider: name, config: target.config, completion: finish)
            } else {
                finish(nil)
            }
        case .fixed:
            finish(nil)
        }
    }

    // MARK: - Host-rule adapters (GLM / Kimi / DeepSeek / Aliyun / YesCode)

    /// YesCode：自研 API，模型 key 打不了余额接口（403 只认用户会话），
    /// 用账号密码登录换 JWT。凭证只在内存：密码不缓存、不落盘、不进错误文案。
    /// JWT 内存缓存（401 失效重登一次）：每次刷新都登录=一天 24+ 次送密码，
    /// 会放大暴露面且可能触发登录接口风控（2026-10-02 对抗性审查 🔴1）。
    private var yescodeToken: String?

    private func fetchYescode(name: String, baseURL: URL, completion: @escaping (BalanceInfo?) -> Void) {
        if let token = stateQueue.sync(execute: { yescodeToken }), !token.isEmpty {
            fetchYescodeBalance(token: token, allowRelogin: true, name: name, baseURL: baseURL, completion: completion)
            return
        }
        loginYescode(name: name, baseURL: baseURL, completion: completion)
    }

    private func loginYescode(name: String, baseURL: URL, completion: @escaping (BalanceInfo?) -> Void) {
        guard let username = SecretResolver.readKeychain(service: "ccpod-yescode-username"),
              let password = SecretResolver.readKeychain(service: "ccpod-yescode-password"),
              !username.isEmpty, !password.isEmpty else {
            let info = BalanceInfo.status(
                .notIntegrated(reason: "查余额要账号密码登录（API key 不行），还没配置"), provider: name)
            storeFailure(info)
            completion(info)
            return
        }
        var login = URLRequest(url: baseURL.appendingPathComponent("api/v1/auth/login"))
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        login.httpBody = try? JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        session.dataTask(with: login) { [weak self] data, resp, _ in
            guard let self else { return }
            guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let token = json["token"] as? String, !token.isEmpty else {
                self.storeFailure(BalanceInfo.status(.failed(reason: "YesCode 登录失败（账号或密码不对）"), provider: name))
                completion(self.cached(name))
                return
            }
            self.stateQueue.sync { self.yescodeToken = token }
            self.fetchYescodeBalance(token: token, allowRelogin: false, name: name, baseURL: baseURL, completion: completion)
        }.resume()
    }

    private func fetchYescodeBalance(token: String, allowRelogin: Bool,
                                     name: String, baseURL: URL,
                                     completion: @escaping (BalanceInfo?) -> Void) {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/v1/user/balance"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // YesCode 的 Cloudflare 按 UA 拦 bot（python-urllib 实测 1010）；带浏览器 UA
        req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            let http = resp as? HTTPURLResponse
            // 缓存 token 过期：清掉重登一次（allowRelogin 只在用缓存时为 true，防循环）
            if http?.statusCode == 401, allowRelogin {
                self.stateQueue.sync { self.yescodeToken = nil }
                self.loginYescode(name: name, baseURL: baseURL, completion: completion)
                return
            }
            guard let data, http?.statusCode == 200,
                  let info = QuotaAdapters.parseYescode(provider: name, data: data) else {
                let failed = BalanceInfo.status(.failed(reason: "余额查询失败（HTTP \(http?.statusCode ?? 0)）"), provider: name)
                self.storeFailure(failed)
                completion(failed)
                return
            }
            // parse 也可能返回 failed-info（结构变了等），失败不覆盖已有好数据
            if info.status == .ok { self.store(info) } else { self.storeFailure(info) }
            completion(info)
        }.resume()
    }


    /// 百炼 Token Plan：ModelStudio OpenAPI 要 RAM AK 签名（ACS3），模型 key 用不上。
    /// AK 存钥匙串（ccpod-aliyun-ak-id/-secret，只进内存）；没配就降级为「仅控制台」。
    private func fetchAliyunTokenPlan(name: String, completion: @escaping (BalanceInfo?) -> Void) {
        guard let akID = SecretResolver.readKeychain(service: "ccpod-aliyun-ak-id"),
              let secret = SecretResolver.readKeychain(service: "ccpod-aliyun-ak-secret"),
              !akID.isEmpty, !secret.isEmpty,
              let request = ACS3Signer.signedGetRequest(
                  url: URL(string: "https://modelstudio.cn-beijing.aliyuncs.com/tokenplan/subscription/stats")!,
                  action: "GetSubscriptionStats",
                  apiVersion: "2026-02-10",
                  accessKeyId: akID,
                  secret: secret) else {
            let info = BalanceInfo.status(.consoleOnly(url: QuotaAdapters.bailianConsole), provider: name)
            storeFailure(info)
            completion(info)
            return
        }
        session.dataTask(with: request) { [weak self] data, resp, _ in
            guard let self else { return }
            let http = resp as? HTTPURLResponse
            guard let data, http?.statusCode == 200 else {
                self.registerFailure(provider: name, statusCode: http?.statusCode, body: "")
                // 归因要正确（第一性支柱③）：401 可能是 key 错，也可能是本机时钟偏差 >15 分钟
                // （x-acs-date 容差）——读错误体 Code 精确区分，区分不了就双提示，别让用户白换 key。
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let errCode = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["Code"] as? String
                let reason: String
                switch http?.statusCode {
                case 403: reason = "RAM 子用户没挂百炼只读权限（403）"
                case 401:
                    switch errCode ?? "" {
                    case let c where c.contains("InvalidAccessKeyId"): reason = "AccessKey ID 不存在（401）"
                    case let c where c.contains("SignatureDoesNotMatch"): reason = "AccessKey Secret 不对（401）"
                    case let c where c.contains("Skew") || c.contains("TimeExpired"): reason = "本机时钟偏差超过 15 分钟（401）"
                    default: reason = "AccessKey 无效，或本机时钟偏差 >15 分钟（401）"
                    }
                case nil: reason = "阿里云 OpenAPI 连不上"
                default: reason = "额度查询失败（HTTP \(http?.statusCode ?? 0)）"
                }
                let info = BalanceInfo.status(.failed(reason: reason), provider: name)
                self.storeFailure(info)
                completion(info)
                return
            }
            // 200 但解析不出（个人版订阅无座席数据，GetSubscriptionStats 返 {"Success":true}）
            // → 不是失败：如实降级为「仅控制台」，别把"没数据"显示成"查询失败"
            guard let info = QuotaAdapters.parseAliyun(provider: name, data: data) else {
                let fallback = BalanceInfo.status(
                    .consoleOnly(url: QuotaAdapters.bailianConsole), provider: name)
                self.storeFailure(fallback)
                completion(fallback)
                return
            }
            completion(info)
        }.resume()
    }


    private func fetchAdapter(kind: QuotaKind, name: String, config: ProviderConfig, completion: @escaping (BalanceInfo?) -> Void) {
        let requests = QuotaAdapters.requests(for: kind, baseURL: config.baseURL, key: config.apiKey)
        guard !requests.isEmpty else { completion(nil); return }

        let group = DispatchGroup()
        var results = [(status: Int?, data: Data?)](repeating: (nil, nil), count: requests.count)
        let lock = NSLock()
        for (index, request) in requests.enumerated() {
            group.enter()
            session.dataTask(with: request) { data, resp, _ in
                lock.lock()
                results[index] = ((resp as? HTTPURLResponse)?.statusCode, data)
                lock.unlock()
                group.leave()
            }.resume()
        }

        group.notify(queue: workQueue) { [weak self] in
            guard let self else { return }
            let main = results[0]
            guard main.status == 200, let data = main.data else {
                let body = main.data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self.registerFailure(provider: name, statusCode: main.status, body: body)
                completion(BalanceInfo.status(.failed(reason: Self.failureText(kind: kind, status: main.status)),
                                              provider: name))
                return
            }
            let parsed: BalanceInfo?
            switch kind {
            case .glmPlan:
                let sub = results.count > 1 && results[1].status == 200 ? results[1].data : nil
                parsed = QuotaAdapters.parseGLM(provider: name, limit: data, subscription: sub)
            case .kimiCoding:
                let me = results.count > 1 && results[1].status == 200 ? results[1].data : nil
                parsed = QuotaAdapters.parseKimi(provider: name, data: data, me: me)
            case .deepseekBalance:
                parsed = QuotaAdapters.parseDeepSeek(provider: name, data: data)
            case .minimaxPlan:
                parsed = QuotaAdapters.parseMinimax(provider: name, data: data)
            default:
                parsed = nil
            }
            completion(parsed ?? BalanceInfo.status(.failed(reason: "返回结构变了，解析不出额度"), provider: name))
        }
    }

    /// 人话失败原因。不带响应体（可能回显 key 片段）。
    private static func failureText(kind: QuotaKind, status: Int?) -> String {
        switch status {
        case nil: return "额度接口连不上"
        case 401?, 403?: return "额度接口拒绝了这把 key（\(status!)）"
        case 404? where kind == .kimiCoding: return "未开通 Kimi Coding 套餐（404）"
        case 429?: return "额度接口限流，稍后再查（429）"
        default: return "额度查询失败（HTTP \(status!)）"
        }
    }

    // MARK: - Auto-detect (sub2api / new-api / ZenMux)

    private func probe(provider: String, config: ProviderConfig, completion: @escaping (BalanceInfo?) -> Void) {
        guard beginProbing(provider: provider) else {
            completion(nil)
            return
        }

        let group = DispatchGroup()
        var results: [GatewayType] = []
        let lock = NSLock()

        let checks: [(GatewayType, String)] = [
            (.sub2api, "/v1/usage"),
            (.newapi, "/v1/dashboard/billing/subscription"),
            (.zenmux, "/api/v1/management/subscription/detail"),
        ]

        for (type, path) in checks {
            group.enter()
            let url = config.baseURL.appendingPathComponent(path)
            var req = URLRequest(url: url)
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            if let mgmt = config.managementKey, !mgmt.isEmpty {
                req.setValue("Bearer \(mgmt)", forHTTPHeaderField: "Authorization")
            }
            session.dataTask(with: req) { _, resp, _ in
                defer { group.leave() }
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
                lock.lock()
                results.append(type)
                lock.unlock()
            }.resume()
        }

        group.notify(queue: .global()) { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            let detected = results.first ?? .unknown
            self.finishProbing(provider: provider, detected: detected)
            self.saveDetectedType(provider: provider, type: detected)

            if detected != .unknown {
                self.fetchWith(type: detected, provider: provider, config: config, completion: completion)
            } else {
                completion(BalanceInfo.status(.notIntegrated(reason: "未识别额度接口"), provider: provider))
            }
        }
    }

    // MARK: - Fetch by type

    private func fetchWith(type: GatewayType, provider: String, config: ProviderConfig, completion: @escaping (BalanceInfo?) -> Void) {
        switch type {
        case .sub2api:
            fetchSub2api(provider: provider, baseURL: config.baseURL, key: config.apiKey, completion: completion)
        case .newapi:
            fetchNewapi(provider: provider, baseURL: config.baseURL, key: config.apiKey, completion: completion)
        case .zenmux:
            let key = config.managementKey ?? config.apiKey
            fetchZenmux(provider: provider, baseURL: config.baseURL, key: key, completion: completion)
        case .unknown:
            completion(nil)
        }
    }

    // MARK: - sub2api: /v1/usage

    private func fetchSub2api(provider: String, baseURL: URL, key: String, completion: @escaping (BalanceInfo?) -> Void) {
        let url = baseURL.appendingPathComponent("/v1/usage")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: req) { data, resp, _ in
            let http = resp as? HTTPURLResponse
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard let data, let http, http.statusCode == 200,
                  let info = QuotaAdapters.parseSub2api(provider: provider, data: data) else {
                self.registerFailure(provider: provider, statusCode: http?.statusCode, body: body)
                completion(nil); return
            }
            completion(info)
        }.resume()
    }

    // MARK: - new-api: /v1/dashboard/billing/*

    private func fetchNewapi(provider: String, baseURL: URL, key: String, completion: @escaping (BalanceInfo?) -> Void) {
        let subURL = baseURL.appendingPathComponent("/v1/dashboard/billing/subscription")
        var subReq = URLRequest(url: subURL)
        subReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: subReq) { [weak self] data, resp, _ in
            let http = resp as? HTTPURLResponse
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard let self,
                  let data,
                  let http, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self?.registerFailure(provider: provider, statusCode: http?.statusCode, body: body)
                completion(nil); return
            }
            let hardLimit = self.doubleValue(json["hard_limit_usd"]) ?? 0
            let resetAt = self.extractDate(from: json, keys: ["reset_at", "resets_at", "next_reset_at"])
            let expiresAt = self.extractDate(from: json, keys: ["access_until", "expires_at", "expire_at", "expired_at"])
            let planName = json["plan_name"] as? String ?? ""
            self.fetchNewapiUsage(
                provider: provider,
                baseURL: baseURL,
                key: key,
                hardLimit: hardLimit,
                resetAt: resetAt,
                expiresAt: expiresAt,
                planName: planName,
                completion: completion
            )
        }.resume()
    }

    private func fetchNewapiUsage(provider: String, baseURL: URL, key: String, hardLimit: Double, resetAt: Date?, expiresAt: Date?, planName: String, completion: @escaping (BalanceInfo?) -> Void) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let today = fmt.string(from: Date())
        let start = fmt.string(from: Date(timeIntervalSinceNow: -90 * 86400))

        let url = baseURL.appendingPathComponent("/v1/dashboard/billing/usage")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "start_date", value: start), .init(name: "end_date", value: today)]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: req) { data, resp, _ in
            let http = resp as? HTTPURLResponse
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard let data,
                  let http, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.registerFailure(provider: provider, statusCode: http?.statusCode, body: body)
                completion(nil); return
            }
            let usageCents = self.doubleValue(json["total_usage"]) ?? 0
            let used = max(usageCents / 100.0, 0)
            let remaining = max(hardLimit - used, 0)
            let period: QuotaPeriod = resetAt == nil ? .unknown : .month
            let label = resetAt == nil ? (planName.isEmpty ? QuotaPeriod.unknown.shortLabel : planName) : QuotaPeriod.month.shortLabel
            let windows = hardLimit > 0 ? [
                QuotaWindow(
                    period: period,
                    label: label,
                    remaining: remaining,
                    total: hardLimit,
                    used: used,
                    resetAt: resetAt,
                    expiresAt: expiresAt
                )
            ] : []
            completion(
                QuotaAdapters.normalize(
                    provider: provider,
                    planName: planName,
                    windows: windows,
                    fallbackRemaining: remaining,
                    fallbackTotal: hardLimit,
                    fallbackUsed: used
                )
            )
        }.resume()
    }

    // MARK: - ZenMux: /api/v1/management/*

    private func fetchZenmux(provider: String, baseURL: URL, key: String, completion: @escaping (BalanceInfo?) -> Void) {
        let url = baseURL.appendingPathComponent("/api/v1/management/subscription/detail")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: req) { data, resp, _ in
            let http = resp as? HTTPURLResponse
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard let data,
                  let http, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.registerFailure(provider: provider, statusCode: http?.statusCode, body: body)
                completion(nil); return
            }
            var remaining = 0.0
            var total = 0.0
            var used = 0.0
            var planName = ""
            var resetAt: Date?
            var expiresAt: Date?
            if let plan = json["plan"] as? [String: Any] {
                planName = plan["tier"] as? String ?? ""
                total = self.doubleValue(plan["monthly_usd"]) ?? 0
                resetAt = self.extractDate(from: plan, keys: ["reset_at", "resets_at", "renew_at", "next_reset_at"])
                expiresAt = self.extractDate(from: plan, keys: ["expires_at", "expire_at", "expired_at", "access_until"])
            }
            if let monthly = json["quota_monthly"] as? [String: Any] {
                used = self.doubleValue(monthly["used_usd"]) ?? 0
                let limit = self.doubleValue(monthly["limit_usd"]) ?? total
                remaining = max(limit - used, 0)
                if limit > 0 { total = limit }
                resetAt = self.extractDate(from: monthly, keys: ["reset_at", "resets_at", "next_reset_at"]) ?? resetAt
                expiresAt = self.extractDate(from: monthly, keys: ["expires_at", "expire_at", "expired_at", "access_until"]) ?? expiresAt
            }
            let windows = total > 0 ? [
                QuotaWindow(
                    period: .month,
                    label: QuotaPeriod.month.shortLabel,
                    remaining: remaining,
                    total: total,
                    used: used,
                    resetAt: resetAt,
                    expiresAt: expiresAt
                )
            ] : []
            completion(
                QuotaAdapters.normalize(
                    provider: provider,
                    planName: planName,
                    windows: windows,
                    fallbackRemaining: remaining,
                    fallbackTotal: total,
                    fallbackUsed: used
                )
            )
        }.resume()
    }

    // MARK: - Cache & sidecar

    private func store(_ info: BalanceInfo) {
        let snapshot = stateQueue.sync { () -> [String: BalanceInfo] in
            cache[info.provider] = info
            if info.status == .ok && info.remaining <= 0 {
                // 透支是一种**状态**，不是请求失败：用户随时可能充值。原来按 longFailureCooldown
                // 冻结 6 小时，充值后界面还显示旧的透支值、且没有任何"已暂停刷新"的提示，
                // 看起来就像钱没到账。改成短冷却（仍可 force 立即刷新）。
                cooldownUntil[info.provider] = Date().addingTimeInterval(Self.shortFailureCooldown)
            } else if info.status == .ok {
                cooldownUntil[info.provider] = nil
            }
            return cache
        }
        writeSidecar(snapshot)
        onUpdate?(info.provider, info)
    }

    /// 查询失败：已有成功数据就保留（UI 有更新时间可判断新旧），没有才存失败原因。
    private func storeFailure(_ info: BalanceInfo) {
        let hasGood = stateQueue.sync { cache[info.provider]?.status == .ok }
        guard !hasGood else { return }
        store(info)
    }

    private func renamed(_ info: BalanceInfo, to name: String) -> BalanceInfo {
        guard info.provider != name else { return info }
        var copy = BalanceInfo(provider: name, remaining: info.remaining, total: info.total, used: info.used,
                               planName: info.planName, windows: info.windows, status: info.status)
        copy.renewAt = info.renewAt
        copy.autoRenew = info.autoRenew
        copy.planDetail = info.planDetail
        copy.updatedAt = info.updatedAt
        return copy
    }

    private func registerFailure(provider: String, statusCode: Int?, body: String) {
        let cooldown = failureCooldown(statusCode: statusCode, body: body)
        stateQueue.sync {
            cooldownUntil[provider] = Date().addingTimeInterval(cooldown)
        }
    }

    private func failureCooldown(statusCode: Int?, body: String) -> TimeInterval {
        let lower = body.lowercased()
        if lower.contains("insufficient_balance") ||
            lower.contains("余额不足") ||
            lower.contains("quota") ||
            lower.contains("rate_limit") ||
            lower.contains("rate limit") {
            return Self.longFailureCooldown
        }
        switch statusCode {
        case 401?, 403?, 429?:
            return Self.longFailureCooldown
        default:
            return Self.shortFailureCooldown
        }
    }

    private func writeSidecar(_ snapshot: [String: BalanceInfo]) {
        func windowObject(_ window: QuotaWindow) -> [String: Any] {
            var object: [String: Any] = [
                "period": window.period.rawValue,
                "label": window.label,
                "remaining": window.remaining,
                "used": window.used,
                "total": window.total,
                "unit": window.unit.rawValue,
            ]
            if let resetAt = window.resetAt {
                object["resetAt"] = Int(resetAt.timeIntervalSince1970)
            }
            if let expiresAt = window.expiresAt {
                object["expiresAt"] = Int(expiresAt.timeIntervalSince1970)
            }
            return object
        }
        let jsonObject: [String: Any] = snapshot.reduce(into: [:]) { partial, entry in
            let balance = entry.value
            var object: [String: Any] = [
                "updatedAt": Int(balance.updatedAt.timeIntervalSince1970),
                "planName": balance.planName,
                "status": balance.status.rawName,
                "windows": balance.windows.map(windowObject),
            ]
            if let tightest = balance.tightestWindow {
                object["tightest"] = windowObject(tightest)
            }
            if let renewAt = balance.renewAt {
                object["renewAt"] = Int(renewAt.timeIntervalSince1970)
            }
            if let planDetail = balance.planDetail {
                object["planDetail"] = planDetail
            }
            partial[entry.key] = object
        }

        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        // .atomic 会按 umask 落成 644，写完显式收紧到 600（项目约定：可能含账户信息的文件一律 600）
        try? data.write(to: quotaSidecarURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: quotaSidecarURL.path)
    }

    // MARK: - Config

    /// CCR 上游管线优先，其次直连 provider json。
    /// 顺序不能反：APFS 默认不区分大小写，CCR 的 "dragoncode" 会读到旧直连文件 Dragoncode.json，
    /// 查成另一把 key 的账户。
    private func resolveTarget(_ name: String) -> Target? {
        if let line = gatewayLines(includeKeys: true)[name] {
            guard let kind = QuotaAdapters.kind(for: line.baseURL) else { return nil }
            return Target(config: ProviderConfig(baseURL: line.baseURL, apiKey: line.apiKey, managementKey: nil),
                          kind: kind)
        }
        guard let config = readProviderConfig(name), let kind = QuotaAdapters.kind(for: config.baseURL) else {
            return nil
        }
        return Target(config: config, kind: kind)
    }

    private struct GatewayLine {
        let baseURL: URL
        let apiKey: String
    }

    /// CCR 上游管线（name → base_url[, key]）。经管理 RPC getConfig，与官方 Web 控制台同一条路。
    /// includeKeys=false 时不解析 key（列表用途）。需在 workQueue 上调用（同步 RPC）。
    private func gatewayLines(includeKeys: Bool = false) -> [String: GatewayLine] {
        guard let state = CCRConfigService.serviceState(),
              let config = try? CCRConfigService.fetchConfig(state: state),
              let providers = config["Providers"] as? [[String: Any]] else { return [:] }
        var lines: [String: GatewayLine] = [:]
        for provider in providers {
            guard let name = provider["name"] as? String, !name.isEmpty,
                  let base = provider["api_base_url"] as? String,
                  let url = URL(string: base) else { continue }
            // api_key 可能是明文或 {"$exec": …}：一律经 SecretResolver（PITFALLS #16）
            let key = includeKeys ? (SecretResolver.value(from: provider["api_key"]) ?? "") : ""
            lines[name] = GatewayLine(baseURL: url, apiKey: key)
        }
        return lines
    }

    private func readProviderConfig(_ name: String) -> ProviderConfig? {
        guard providerFileExists(name) else { return nil }
        let file = providersDir.appendingPathComponent("\(name).json")
        // env 必须按 [String: Any] 读：值可能是 `{"$exec": "…"}`（密钥放钥匙串、json 不留明文）。
        // 原来强转 [String: String]，只要有一个 $exec 整个转换就失败 → 那条线路静默没有余额
        // （ccr-dear 一直就是这样，没人发现）。
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any],
              let urlStr = SecretResolver.value(from: env["ANTHROPIC_BASE_URL"]), !urlStr.isEmpty,
              let url = URL(string: urlStr) else { return nil }
        let key = SecretResolver.value(from: env["ANTHROPIC_API_KEY"])
            ?? SecretResolver.value(from: env["ANTHROPIC_AUTH_TOKEN"])
            ?? SecretResolver.value(from: env["ANTHROPIC_API_TOKEN"]) ?? ""
        let mgmt = SecretResolver.value(from: env["MANAGEMENT_API_KEY"])

        if let gw = json["gateway"] as? String, let type = GatewayType(rawValue: gw) {
            setCachedType(type, for: name)
        }
        return ProviderConfig(baseURL: url, apiKey: key, managementKey: mgmt)
    }

    private func saveDetectedType(provider: String, type: GatewayType) {
        // 只写名字**完全一致**的文件：CCR 管线 "yescode" 不能写进直连的 Yescode.json
        guard providerFileExists(provider) else { return }
        let file = providersDir.appendingPathComponent("\(provider).json")
        guard let data = try? Data(contentsOf: file),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["gateway"] = type.rawValue
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            // provider json 可能含明文 key；.atomic 是新建文件+rename，会按 umask 落成 644，必须收回 600
            try? out.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private func cachedType(for provider: String) -> GatewayType? {
        stateQueue.sync { detectedTypes[provider] }
    }

    private func setCachedType(_ type: GatewayType, for provider: String) {
        stateQueue.sync { detectedTypes[provider] = type }
    }

    private func beginProbing(provider: String) -> Bool {
        stateQueue.sync {
            guard !probing.contains(provider) else { return false }
            probing.insert(provider)
            return true
        }
    }

    private func finishProbing(provider: String, detected: GatewayType) {
        stateQueue.sync {
            probing.remove(provider)
            detectedTypes[provider] = detected
        }
    }

    private func beginFetch(provider: String, respectCooldown: Bool) -> Bool {
        stateQueue.sync {
            if let last = lastFetchedAt[provider],
               Date().timeIntervalSince(last) < Self.minimumFetchInterval {
                return false
            }
            if respectCooldown,
               let until = cooldownUntil[provider],
               until > Date() {
                return false
            }
            lastFetchedAt[provider] = Date()
            return true
        }
    }

    /// 大小写精确匹配（APFS 默认不区分大小写，Data(contentsOf:) 会把 dragoncode 读成 Dragoncode.json）。
    private func providerFileExists(_ name: String) -> Bool {
        isValidProviderID(name) && allProviders().contains(name)
    }

    private func allProviders() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: providersDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !$0.contains(".example") }
            .filter { isValidProviderID($0) }
            .sorted()
    }

    private func doubleValue(_ raw: Any?) -> Double? {
        QuotaAdapters.doubleValue(raw)
    }

    private func extractDate(from dict: [String: Any], keys: [String]) -> Date? {
        QuotaAdapters.extractDate(from: dict, keys: keys)
    }

    struct ProviderConfig {
        let baseURL: URL
        let apiKey: String
        let managementKey: String?
    }
}
