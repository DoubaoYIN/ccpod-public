import Foundation

/// 导入旧线路前的实测计划：从候选配置里取出 LinePreflight 需要的地址、key、模型名。
///
/// 与手动新增（AddProviderView 调 LinePreflight）同一道闸：导入的判据也应是「线路实测能通」，
/// 而不是「文件写入成功」。区别是导入不硬拦——实测没过的条目默认先不导入，
/// 但用户可以明确选择「仍然导入」（aigocode/yescode 这类只认 Claude Code 客户端的网关，
/// 实测必然 403，系统不能替用户判死刑）。
///
/// 纯函数、只依赖 SecretResolver，scripts/tests/test_preflight_import.sh 脱离 App 单测。
enum ProviderImportPreflight {

    enum Plan: Equatable {
        /// 可以实测：交给 LinePreflight.check
        case probe(baseURL: String, apiKey: String, model: String)
        /// 本机网关（127.0.0.1/localhost）：实测会打进 CCR 账本，且网关有自己的体检，不实测、照常可导入
        case localGateway
        /// 缺必要信息，无法实测；按「未通过」处理（用户仍可选择导入）
        case incomplete(String)
    }

    static let localGatewayNote = "本机网关线路不实测"

    /// key 字段的读取顺序与 ProviderImportService.scan() 的比对逻辑一致。
    /// env 一律按 [String: Any] 读、值一律经 SecretResolver：写成 [String: String] 会在遇到 $exec 时整体失败。
    static func plan(for json: [String: Any]) -> Plan {
        let env = json["env"] as? [String: Any] ?? [:]
        let baseURL = (SecretResolver.value(from: env["ANTHROPIC_BASE_URL"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else { return .incomplete("没有地址，无法实测") }
        if let host = URL(string: baseURL)?.host?.lowercased(),
           ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) {
            return .localGateway
        }
        let apiKey = SecretResolver.value(from: env["ANTHROPIC_AUTH_TOKEN"])
            ?? SecretResolver.value(from: env["ANTHROPIC_API_KEY"])
            ?? SecretResolver.value(from: env["ANTHROPIC_API_TOKEN"])
        guard let apiKey, !apiKey.isEmpty else { return .incomplete("取不到 key，无法实测") }
        guard let model = model(in: json, env: env) else {
            return .incomplete("没有模型名，无法实测：不填的话 Claude Code 会拿 claude 系默认名去请求")
        }
        return .probe(baseURL: baseURL, apiKey: apiKey, model: model)
    }

    /// claude_args 里的 --model 优先（它才是 ccgo 启动时真正生效的参数），其次 env.ANTHROPIC_MODEL。
    private static func model(in json: [String: Any], env: [String: Any]) -> String? {
        let args = json["claude_args"] as? [String] ?? []
        if let index = args.firstIndex(of: "--model"), index + 1 < args.count {
            let value = args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        let value = (env["ANTHROPIC_MODEL"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
