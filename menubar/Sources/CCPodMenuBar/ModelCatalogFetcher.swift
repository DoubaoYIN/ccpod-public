import Foundation

/// 从上游拉取模型列表：GET {base}/v1/models，解析 OpenAI/Anthropic 同形的 {"data":[{"id":…}]}。
///
/// 实测地形（2026-10-02，盲测状态码 + body + gh search code 佐证）：
/// - zenmux 无 key 也返回真列表；glm/dragoncode/yescode/kimi/dragon-grok 带 key 可拉；
/// - ⚠️ glm 无 key 时返回 **HTTP 200 但 body 是鉴权错误 JSON**——不能只信状态码，
///   必须解析出 data[].id 才算成功（parseIDs 是拦截点）；
/// - 百炼的 Anthropic 入口（/apps/anthropic）没有目录接口，但同域名的 OpenAI 兼容入口
///   `/compatible-mode/v1/models` 用同一把 key 可拉（16 个）——candidateURLs 已内置该候补；
/// - aigocode 403 是余额不足（官方文档证实目录接口公开），充值/换分组后可拉。
///
/// 边界：⚠️ 拉到 ≠ 能调用（docs/lessons 上游坑：列表是平台目录，可用性取决于 key 的分组）。
/// 本模块只回答"上游目录里有哪些 id"，可用性探测留在实验室 line-check --probe。
enum ModelCatalogFetcher {

    struct Outcome {
        let models: [String]?   // 成功：去重、保序的裸 id；失败为 nil
        let message: String     // 失败原因（已脱敏）；成功时为空
        var ok: Bool { models != nil }
    }

    /// 纯函数：{base}/v1/models 直接拼接（实测 glm 带 /api/anthropic 路径直接拼可行）。
    /// base 已以 "/v1" 结尾时只补 "/models"，防拼出 /v1/v1。
    static func modelsURL(forBase baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        let path = base.hasSuffix("/v1") ? "/models" : "/v1/models"
        return URL(string: base + path)
    }

    /// 候选拉取地址：主地址 + 知名同胞路径。
    /// 教训（2026-10-02 百炼翻案）：同一域名往往同时挂着协议专用入口（/apps/anthropic）
    /// 和 OpenAI 兼容入口（/compatible-mode/v1）——后者才有模型目录。
    /// qwen-code / cc-switch 等上游项目全都用 compatible-mode 路径（gh search code 实证）。
    static func candidateURLs(forBase baseURL: String) -> [URL] {
        guard let primary = modelsURL(forBase: baseURL) else { return [] }
        var candidates = [primary]
        if let comps = URLComponents(url: primary, resolvingAgainstBaseURL: false),
           !comps.path.contains("/compatible-mode/") {
            var sibling = URLComponents()
            sibling.scheme = comps.scheme
            sibling.host = comps.host
            sibling.port = comps.port
            sibling.path = "/compatible-mode/v1/models"
            if let url = sibling.url { candidates.append(url) }
        }
        return candidates
    }

    /// 纯函数：从响应体解析模型 id 列表。解析不出（含 glm 那种 200+鉴权错误体）返回 nil。
    static func parseIDs(from data: Data) -> [String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["data"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        var ids: [String] = []
        for item in items {
            guard let id = item["id"] as? String, !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            ids.append(id)
        }
        return ids
    }

    /// 保守归一：仅剥离结尾 [1M]/[2M] 形上下文窗口后缀（CCR 路由会剥掉它再匹配，存裸名）。
    /// 注意：不动 x-ai/ 这类命名空间前缀——那是合法模型名的一部分。
    /// （"[nM] 后缀要剥"是实测得出的工作假设，未见诸上游书面约定。）
    static func normalize(_ id: String) -> String {
        guard let range = id.range(of: #"\[\d+M\]$"#, options: .regularExpression) else { return id }
        return String(id[..<range.lowerBound])
    }

    static func fetch(baseURL: String, apiKey: String,
                      completion: @escaping (Outcome) -> Void) {
        let candidates = candidateURLs(forBase: baseURL)
        guard !candidates.isEmpty else {
            completion(Outcome(models: nil, message: "地址为空或不是合法 URL，没法拼出模型列表接口"))
            return
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // 依次试候选地址：第一个能解析出模型列表的胜出；全部失败时报主地址的诊断。
        tryFetch(candidates, key: key, index: 0, primaryOutcome: nil, completion: completion)
    }

    private static func tryFetch(_ candidates: [URL], key: String, index: Int,
                                 primaryOutcome: Outcome?,
                                 completion: @escaping (Outcome) -> Void) {
        guard index < candidates.count else {
            // 全部失败：报主地址的诊断（它与用户配置的线路地址直接相关，最可行动）
            completion(primaryOutcome ?? Outcome(models: nil, message: "拉取失败"))
            return
        }
        var req = URLRequest(url: candidates[index])
        req.httpMethod = "GET"
        if !key.isEmpty {
            // 与 LinePreflight 同款：两种鉴权头都带，Bearer 是 OpenAI 形惯例、x-api-key 是 Anthropic 形惯例。
            // 硬约束：key 只进 header，不进日志、不进错误文案。
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        session.dataTask(with: req) { data, resp, error in
            let outcome = diagnose(error: error, response: resp, data: data, apiKey: key)
            if outcome.ok {
                DispatchQueue.main.async { completion(outcome) }
            } else {
                tryFetch(candidates, key: key, index: index + 1,
                         primaryOutcome: primaryOutcome ?? outcome, completion: completion)
            }
        }.resume()
    }

    /// 长期持有（与 LinePreflight/HealthService 的做法一致，防御性实践）。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    /// 纯函数分诊（仿 LinePreflight.translate，可独立验证）。
    /// 文案原则：如实说明哪个事实不成立 + 下一步做什么；绝不假装成功。
    static func diagnose(error: Error?, response: URLResponse?, data: Data?, apiKey: String) -> Outcome {
        if let ns = error as NSError?, ns.domain == NSURLErrorDomain {
            let hint: String
            switch ns.code {
            case NSURLErrorTimedOut: hint = "15 秒内没有响应"
            case NSURLErrorCannotFindHost: hint = "域名不存在"
            case NSURLErrorCannotConnectToHost: hint = "服务没开或拒绝连接"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                hint = "HTTPS 握手失败"
            default: hint = ns.localizedDescription
            }
            return Outcome(models: nil, message: "连不上这个地址：\(hint)。核对地址后重试，或手动维护模型列表")
        }
        guard let http = response as? HTTPURLResponse else {
            return Outcome(models: nil, message: "没有得到 HTTP 响应，请手动维护模型列表")
        }
        let body = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = Self.detail(body, apiKey: apiKey)

        switch http.statusCode {
        case 200:
            guard let raw = data, let ids = parseIDs(from: raw) else {
                // glm 陷阱：200 但 body 是鉴权错误 JSON；也可能是回网页的假端点。
                return Outcome(models: nil,
                               message: "返回了 200 但不是模型列表（多半要求鉴权或地址不对）\(detail)")
            }
            guard !ids.isEmpty else {
                return Outcome(models: nil, message: "上游返回了空的模型列表，请手动维护")
            }
            return Outcome(models: ids.map(normalize), message: "")
        case 404:
            return Outcome(models: nil,
                           message: "这家不提供模型列表接口（404），请手动维护模型列表（模型名以官方文档为准）")
        case 401:
            return Outcome(models: nil,
                           message: "上游拒绝了这把 key（401）。key 可能失效、复制不完整，或与该端点不配套\(detail)")
        case 403:
            // 403 的三类真实原因（aigocode 官方文档口径）：分组调用权限 / 余额 / 套餐额度。
            // 曾笼统归因"只接受真实 Claude Code 客户端"——那条限制的是模型**调用**接口，
            // /v1/models 目录接口是公开的（2026-10-02 翻案，实测 403 body 为 INSUFFICIENT_BALANCE）。
            let lower = body.lowercased()
            let noBalance = lower.contains("insufficient") || lower.contains("balance")
                || lower.contains("arrear") || lower.contains("quota")
            if noBalance {
                return Outcome(models: nil,
                               message: "key 是有效的，但账户余额/额度不足，充值或换分组后再拉\(detail)")
            }
            return Outcome(models: nil,
                           message: "上游拒绝了列表请求（403）。可能是分组权限不足（部分分组仅限特定客户端），可换分组 key 或手动维护\(detail)")
        default:
            return Outcome(models: nil, message: "拉取失败（HTTP \(http.statusCode)）\(detail)")
        }
    }

    /// 错误摘要：截断并脱敏——绝不回显 key 本身（照抄 LinePreflight.detail）。
    private static func detail(_ body: String, apiKey: String) -> String {
        var text = String(body.prefix(120))
        if apiKey.count >= 8 {
            text = text.replacingOccurrences(of: apiKey, with: "***")
        }
        return text.isEmpty ? "" : "：\(text)"
    }
}
