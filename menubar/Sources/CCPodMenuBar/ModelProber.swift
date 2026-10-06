import Foundation

/// 逐模型可用性探测：对**线路自己的端点**（前门）打一发与 Claude Code 完全相同形态的
/// 最小请求（POST {base}/v1/messages, max_tokens:1），回答"这个模型名在前门能不能用"。
///
/// 与 LinePreflight 的关系：同一请求形态，但用途不同——LinePreflight 是添加线路时的
/// 单次准入检查（人话文案导向）；本模块是「获取可用模型」流程里的批量逐模型对照
/// （结构化状态导向），所以返回枚举而非成品文案。
///
/// 判定纪律（PITFALLS #5 与 aigocode 教训）：
/// - 「不可用」只在端点明确拒绝时判（400 模型错 / 404 没这个模型 / 403 余额不足）；
/// - 上游只接受真实 Claude Code 客户端（aigocode）时判「无法验证」而非「不可用」——
///   ccpod 的探测请求被拒不等于模型不存在；
/// - 限流/超时/5xx 一律「无法验证」，不妄判。
enum ModelProber {

    enum Status: Equatable {
        case usable                    // 前门实测可调
        case usableMapped(String)      // 可调，但端点实际路由到了另一个模型
        case rejected(String)          // 明确不可用（附原因）
        case unverifiable(String)      // 无法从 ccpod 判定（附原因）

        var isUsable: Bool {
            if case .usable = self { return true }
            if case .usableMapped = self { return true }
            return false
        }
    }

    /// completion 在后台队列回调（调用方自行回主线程），便于批量调度。
    static func probe(baseURL: String, apiKey: String, model: String,
                      completion: @escaping (Status) -> Void) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, !model.isEmpty,
              let url = URL(string: trimmed + "/v1/messages") else {
            completion(.unverifiable("地址或模型名为空"))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 1, "messages": [["role": "user", "content": "."]]
        ])
        session.dataTask(with: req) { data, resp, error in
            if let ns = error as NSError?, ns.domain == NSURLErrorDomain {
                let hint = ns.code == NSURLErrorTimedOut ? "15 秒无响应" : ns.localizedDescription
                completion(.unverifiable("网络：\(hint)"))
                return
            }
            guard let http = resp as? HTTPURLResponse else {
                completion(.unverifiable("没有得到 HTTP 响应"))
                return
            }
            let body = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            completion(classify(statusCode: http.statusCode, body: body, requestedModel: model))
        }.resume()
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    /// 纯函数判定（可独立单测）。body 原文只进枚举的 reason，不回显 key
    /// （key 不会出现在上游响应里；上游 body 截断展示由调用方决定）。
    static func classify(statusCode: Int, body: String, requestedModel: String) -> Status {
        let lower = body.lowercased()
        switch statusCode {
        case 200:
            guard let data = body.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let actual = obj["model"] as? String else {
                return .unverifiable("返回了 200 但不是 API 响应")
            }
            return actual == requestedModel ? .usable : .usableMapped(actual)
        case 400:
            return .rejected("端点不接受这个模型的调用（400）")
        case 401:
            return .unverifiable("key 被拒（401）——key 失效或与端点不配套")
        case 403:
            if lower.contains("claude code") {
                return .unverifiable("上游只接受真实 Claude Code 客户端，ccpod 无法代为验证")
            }
            if lower.contains("insufficient") || lower.contains("balance")
                || lower.contains("arrear") || lower.contains("quota") {
                return .rejected("账户余额/额度不足")
            }
            return .unverifiable("被拒（403）——可能是分组权限限制")
        case 404:
            return .rejected("端点没有这个模型（404）")
        case 429:
            return .unverifiable("限流（429），稍后再试")
        default:
            if statusCode >= 500 { return .unverifiable("上游异常（\(statusCode)）") }
            return .unverifiable("未预期的响应（\(statusCode)）")
        }
    }
}
