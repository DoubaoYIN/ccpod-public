import Foundation

// CCRConfigService — CCR 管理 RPC 客户端（B 路线④）。
// 走 daemon 自己的 /api/ccr/rpc（与官方 Web 控制台同一条路），daemon 写自己的库，
// 绝不直写 ~/.claude-code-router/config.sqlite（单一写入方约束）。
// 凭证：service.json url 里的 ccr_web_token，鉴权头 x-ccr-web-auth（源码 management-server.ts:126）。
enum CCRConfigService {
    struct State {
        let origin: String
        let token: String
    }

    static func serviceState() -> State? {
        let path = NSString(string: "~/.claude-code-router/service.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let urlString = obj["url"] as? String,
              let url = URL(string: urlString),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name == "ccr_web_token" })?.value, !token.isEmpty
        else { return nil }
        var comps = URLComponents()
        comps.scheme = url.scheme
        comps.host = url.host
        comps.port = url.port
        guard let origin = comps.string else { return nil }
        return State(origin: origin, token: token)
    }

    static func rpc(method: String, args: [Any], state: State) throws -> Any? {
        guard let body = try? JSONSerialization.data(withJSONObject: ["method": method, "args": args]) else {
            throw NSError(domain: "ccr-config", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请求体序列化失败"])
        }
        var request = URLRequest(url: URL(string: state.origin + "/api/ccr/rpc")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(state.token, forHTTPHeaderField: "x-ccr-web-auth")
        request.timeoutInterval = 30
        let semaphore = DispatchSemaphore(value: 0)
        var payload: [String: Any]?
        var transportError: Error?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                transportError = error
            } else if let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                payload = obj
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let transportError { throw transportError }
        guard let payload else {
            throw NSError(domain: "ccr-config", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "管理 RPC 响应不可解析"])
        }
        if (payload["ok"] as? Bool) != true {
            let message = (payload["error"] as? [String: Any])?["message"] as? String ?? "未知错误"
            throw NSError(domain: "ccr-config", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        return payload["value"]
    }

    static func fetchConfig(state: State) throws -> [String: Any] {
        let value = try rpc(method: "getConfig", args: [], state: state)
        guard let config = value as? [String: Any] else {
            throw NSError(domain: "ccr-config", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "getConfig 返回结构异常"])
        }
        return config
    }

    /// 保存配置并让 takeover 重写 settings.json（与官方控制台保存按钮等价）。
    static func saveAndApply(config: [String: Any], state: State) throws {
        _ = try rpc(method: "saveConfig", args: [config], state: state)
        _ = try rpc(method: "applyProfile", args: [], state: state)
    }

    /// 今日用量（经网关统计，按 provider 过滤）→ 多行摘要文本。
    static func usageToday(provider: String, state: State) throws -> String {
        let raw = try rpc(method: "getUsageStats", args: ["today", ["provider": provider]], state: state)
        guard let value = raw as? [String: Any],
              let models = value["models"] as? [[String: Any]] else {
            return "今日无用量记录"
        }
        let rows = models.compactMap { entry -> String? in
            guard let model = entry["model"] as? String else { return nil }
            let requests = (entry["requestCount"] as? Int) ?? 0
            let tokens = (entry["totalTokens"] as? Double) ?? 0
            let cost = (entry["costUsd"] as? Double) ?? 0
            let tokenText = tokens >= 10_000 ? String(format: "%.0f万", tokens / 10_000) : String(format: "%.0f", tokens)
            return String(format: "%@ · %d 次 · %@ tok · $%.2f", model, requests, tokenText, cost)
        }
        return rows.isEmpty ? "今日无用量记录" : rows.joined(separator: "\n")
    }
}
