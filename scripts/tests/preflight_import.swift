import Foundation

// ProviderImportPreflight.plan 单测：导入旧线路前，从候选配置里取实测输入。
// 不发任何网络请求；$exec 用 echo 代替钥匙串，验证密钥走 SecretResolver 而不是 as? [String: String]。

@main
struct PreflightImportTests {
    static var failures = 0
    static func expect(_ cond: Bool, _ name: String, _ detail: String) {
        if !cond { failures += 1; print("✗ \(name)：\(detail)") }
    }

    static func main() {
        typealias P = ProviderImportPreflight

        // 1. claude_args 的 --model 优先于 env.ANTHROPIC_MODEL
        let a = P.plan(for: ["env": ["ANTHROPIC_BASE_URL": "https://api.example.com/anthropic",
                                     "ANTHROPIC_AUTH_TOKEN": "sk-unit-a", "ANTHROPIC_MODEL": "env-model"],
                             "claude_args": ["--model", "args-model"]])
        expect(a == .probe(baseURL: "https://api.example.com/anthropic", apiKey: "sk-unit-a", model: "args-model"),
               "--model 优先", "实际：\(a)")

        // 2. 没有 claude_args 时取 env.ANTHROPIC_MODEL
        let b = P.plan(for: ["env": ["ANTHROPIC_BASE_URL": "https://api.example.com",
                                     "ANTHROPIC_API_KEY": "sk-unit-b", "ANTHROPIC_MODEL": "env-model"]])
        expect(b == .probe(baseURL: "https://api.example.com", apiKey: "sk-unit-b", model: "env-model"),
               "env 模型", "实际：\(b)")

        // 3. $exec 形式的 key：混合类型 env（[String: Any]）必须照常解析
        let c = P.plan(for: ["env": ["ANTHROPIC_BASE_URL": "https://api.example.com",
                                     "ANTHROPIC_AUTH_TOKEN": ["$exec": "echo sk-unit-exec"],
                                     "ANTHROPIC_MODEL": "m"]])
        expect(c == .probe(baseURL: "https://api.example.com", apiKey: "sk-unit-exec", model: "m"),
               "$exec key", "实际：\(c)")

        // 4. 缺模型名 → 无法实测
        let d = P.plan(for: ["env": ["ANTHROPIC_BASE_URL": "https://api.example.com", "ANTHROPIC_AUTH_TOKEN": "sk-unit-d"]])
        if case .incomplete(let why) = d { expect(why.contains("没有模型名"), "缺模型文案", "实际：\(why)") }
        else { expect(false, "缺模型名", "实际：\(d)") }

        // 5. $exec 取不到 key（命令失败）→ 无法实测，而不是拿空 key 去打
        let e = P.plan(for: ["env": ["ANTHROPIC_BASE_URL": "https://api.example.com",
                                     "ANTHROPIC_AUTH_TOKEN": ["$exec": "exit 1"], "ANTHROPIC_MODEL": "m"]])
        if case .incomplete(let why) = e { expect(why.contains("取不到 key"), "缺 key 文案", "实际：\(why)") }
        else { expect(false, "缺 key", "实际：\(e)") }

        // 6. 缺地址
        let f = P.plan(for: ["env": ["ANTHROPIC_AUTH_TOKEN": "sk-unit-f", "ANTHROPIC_MODEL": "m"]])
        if case .incomplete(let why) = f { expect(why.contains("没有地址"), "缺地址文案", "实际：\(why)") }
        else { expect(false, "缺地址", "实际：\(f)") }

        // 7. 本机网关：不实测（不打进 CCR 账本），且不要求 key/模型
        for base in ["http://127.0.0.1:3456", "http://localhost:3456/v1", "http://[::1]:3456"] {
            let g = P.plan(for: ["env": ["ANTHROPIC_BASE_URL": base]])
            expect(g == .localGateway, "本机网关 \(base)", "实际：\(g)")
        }
        expect(P.localGatewayNote == "本机网关线路不实测", "本机网关文案", "实际：\(P.localGatewayNote)")

        // 8. 端口不通的远端地址仍应实测（反向用例的前提：会被 LinePreflight 拦下而不是跳过）
        let h = P.plan(for: ["env": ["ANTHROPIC_BASE_URL": "http://10.255.255.1:9",
                                     "ANTHROPIC_AUTH_TOKEN": "sk-unit-h", "ANTHROPIC_MODEL": "m"]])
        if case .probe = h {} else { expect(false, "远端必实测", "实际：\(h)") }

        if failures == 0 {
            print("全部通过：ProviderImportPreflight.plan 11 组")
        } else {
            print("失败 \(failures) 项"); exit(1)
        }
    }
}
