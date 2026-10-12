import Foundation

/// 添加线路前的闭环实测：用与 Claude Code 完全相同的请求形态（POST {base}/v1/messages）
/// 打一次真实最小请求，一次性验证四个物理事实：端点存在、协议匹配、key 有效、模型名可用。
///
/// 背景（2026-09-29 DeepSeek/百炼线路事故）：录入链路只传递字符串、从不查询物理现实，
/// 错误潜伏到使用时才爆发，且 Claude Code 会把协议错配的 404 翻译成"模型不存在"误导排查方向。
/// 此模块把"现实验证"前移到录入点——添加成功的判据从"文件写入成功"变成"线路实测能通"。
enum LinePreflight {

    struct Outcome {
        let ok: Bool
        let message: String
        let actualModel: String?
    }

    /// 实测地址与真实使用完全相同，因此"地址前缀少写/多写"（如 …/v1）会当场暴露为 404，
    /// 而不是等 Claude Code 使用时报出误导性的"模型不存在"。
    static func check(baseURL: String, apiKey: String, model: String,
                      completion: @escaping (Outcome) -> Void) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, !apiKey.isEmpty, !model.isEmpty,
              let url = URL(string: trimmed + "/v1/messages") else {
            completion(Outcome(ok: false, message: "地址、key、模型名都要填完整才能实测", actualModel: nil))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Claude Code 用 AUTH_TOKEN 时发 Authorization: Bearer，部分网关只认 x-api-key，两个都带。
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 1, "messages": [["role": "user", "content": "."]]
        ])
        session.dataTask(with: req) { data, resp, error in
            let outcome = translate(error: error, response: resp, data: data,
                                    model: model, apiKey: apiKey)
            DispatchQueue.main.async { completion(outcome) }
        }.resume()
    }

    /// 长期持有（与 HealthService 的做法一致）。
    /// 注：A/B 隔离实验（2026-09-30，唯一变量为是否长期持有）证明局部 session 的回调
    /// 同样会到达——此前"局部 session 任务悬空"的归因是 E2E harness 阻塞主线程所致；
    /// 长期持有仍是防御性实践，保留。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    /// 纯函数：把上游响应翻译成用户能行动的人话（可独立单测）。
    /// 文案原则：说明"哪个事实不成立 + 下一步做什么"，不照抄上游错误码。
    static func translate(error: Error?, response: URLResponse?, data: Data?,
                          model: String, apiKey: String) -> Outcome {
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
            return Outcome(ok: false, message: "连不上这个地址：\(hint)。核对地址拼写和网络后重试", actualModel: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            return Outcome(ok: false, message: "没有得到 HTTP 响应", actualModel: nil)
        }
        let body = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = body.lowercased()
        let detail = Self.detail(body, apiKey: apiKey)
        let modelRejected = lower.contains("model") &&
            (lower.contains("not exist") || lower.contains("not found") || lower.contains("invalid"))
        // 火山 ModelNotOpen（404）："Your account … has not activated the model X"——key 和端点都对，是账号没开通
        let modelNotOpen = lower.contains("modelnotopen") || lower.contains("not activated") || body.contains("未开通")
        let noBalance = lower.contains("insufficient") || lower.contains("balance")
            || lower.contains("arrear") || lower.contains("quota")

        switch http.statusCode {
        case 200:
            guard let actual = jsonModel(from: body) else {
                // 对任何路径都回网页的假端点：HTTP 200 但不是 API 响应。
                return Outcome(ok: false,
                               message: "这个地址返回的不是 API 响应（像网页）。多半不是 Anthropic 端点，核对地址前缀（如 /anthropic）",
                               actualModel: nil)
            }
            var message = "实测通过"
            if actual != model { message += "；注意：端点把「\(model)」实际路由到了「\(actual)」" }
            return Outcome(ok: true, message: message, actualModel: actual)
        case _ where modelNotOpen:
            return Outcome(ok: false,
                           message: "key 和地址都对，但账号还没开通模型「\(model)」。去厂商控制台开通该模型（火山：方舟控制台 → 开通管理），或换一个已开通的模型名\(detail)",
                           actualModel: nil)
        case 404:
            if modelRejected {
                return Outcome(ok: false, message: "端点不认识模型「\(model)」（404）。换官方文档里的模型名\(detail)", actualModel: nil)
            }
            if upstreamMessage(body) != nil {
                // 有结构化错误体 = 端点存在且在说话，不是"路径不存在"；如实转述上游原因
                return Outcome(ok: false, message: "端点拒绝了这次请求（404）\(detail)", actualModel: nil)
            }
            return Outcome(ok: false,
                           message: "这个地址不说 Anthropic 协议（404：/v1/messages 不存在）。常见原因是地址前缀少写或多写（如 /anthropic、/api/coding），去官方文档核对端点",
                           actualModel: nil)
        case 401, 403:
            if noBalance {
                return Outcome(ok: false, message: "key 是对的，但账户余额/额度不足，先充值再添加\(detail)", actualModel: nil)
            }
            return Outcome(ok: false,
                           message: "端点拒绝了这把 key（\(http.statusCode)）。key 可能失效、复制不完整，或 key 和端点不配套（例如百炼国内 key 配国际站端点）\(detail)",
                           actualModel: nil)
        default:
            if modelRejected {
                return Outcome(ok: false, message: "端点不认识模型「\(model)」（\(http.statusCode)）。换官方文档里的模型名\(detail)", actualModel: nil)
            }
            if noBalance {
                return Outcome(ok: false, message: "key 是对的，但账户余额/额度不足\(detail)", actualModel: nil)
            }
            return Outcome(ok: false, message: "实测未通过（HTTP \(http.statusCode)）\(detail)", actualModel: nil)
        }
    }

    /// 错误摘要：截断并脱敏——绝不回显 key 本身。
    /// 优先取上游 JSON 里的 error.message（人能读的那句），取不到才用原始 body；上限 400 字，界面可滚动复制。
    private static func detail(_ body: String, apiKey: String) -> String {
        var text = String((upstreamMessage(body) ?? body).prefix(400))
        if apiKey.count >= 8 {
            text = text.replacingOccurrences(of: apiKey, with: "***")
        }
        return text.isEmpty ? "" : "：\(text)"
    }

    /// 兼容 {"error":{"code","message"}}、{"error":"…"}、{"message":"…"}；带上 code 便于搜索
    static func upstreamMessage(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? ""
            let code = (err["code"] as? String) ?? (err["type"] as? String) ?? ""
            let joined = [code, msg].filter { !$0.isEmpty }.joined(separator: " · ")
            return joined.isEmpty ? nil : joined
        }
        if let err = obj["error"] as? String, !err.isEmpty { return err }
        if let msg = obj["message"] as? String, !msg.isEmpty { return msg }
        return nil
    }

    private static func jsonModel(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["model"] as? String
    }
}
