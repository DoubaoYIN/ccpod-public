import Foundation

// 只测纯函数：不碰网络、钥匙串和真实线路目录（桩同 gateway_lines.swift）
enum SecretResolver {
    static var secrets: [String: String] = [:]
    static func value(from value: Any?) -> String? { value as? String }
    static func keychainCommand(service: String) -> String { "security find-generic-password -s \(service) -w 2>/dev/null" }
    static func storeKeychain(service: String, secret: String) throws { secrets[service] = secret }
    static func readKeychain(service: String) -> String? { secrets[service] }
    static func invalidateCache() {}
}
enum SecretRedactor { static func redact(_ text: String) -> String { text } }
enum CCRConfigService {
    struct State { let origin: String }
    static func serviceState() -> State? { nil }
    static func fetchConfig(state: State) throws -> [String: Any] { [:] }
}

@main struct LaunchOptionsTests {
    static func check(_ value: Bool, _ message: String = "assertion failed") { precondition(value, message) }
    static func main() {
        let gateway: [String: Any] = ["source": "gateway", "gateway_model": "claude-opus-5-5",
                                      "gateway_models": ["claude-fable-5-1", "claude-opus-5-5"], "effort": "max"]
        let options = LaunchOptions.make(config: gateway)
        check(options.models == ["claude-fable-5-1", "claude-opus-5-5"])
        check(options.defaultModelLabel == "默认（\(modelDisplayName("claude-opus-5-5"))）")
        check(options.defaultEffortLabel == "默认（max）")
        var noEffort = gateway
        noEffort.removeValue(forKey: "effort")
        check(LaunchOptions.make(config: noEffort).defaultEffortLabel == "默认（跟随全局）")
        var badEffort = gateway
        badEffort["effort"] = "ultra"
        check(LaunchOptions.make(config: badEffort).defaultEffortLabel == "默认（跟随全局）")
        check(LaunchOptions.make(config: ["source": "gateway", "gateway_models": [String]()]).models.isEmpty)
        let direct: [String: Any] = ["env": ["ANTHROPIC_MODEL": "env-model"], "claude_args": ["--model", "arg-model"]]
        let fixed = LaunchOptions.make(config: direct)
        check(fixed.models.isEmpty)
        check(fixed.defaultModelLabel == "固定（\(gatewayModelDisplayName("arg-model"))）")
        check(LaunchOptions.make(config: ["env": ["ANTHROPIC_MODEL": "env-model"]]).defaultModelLabel
              == "固定（\(gatewayModelDisplayName("env-model"))）")
        check(LaunchOptions.make(config: ["source": "gateway-alias", "gateway_models": ["x"]]).models.isEmpty)
        check(LaunchOptions.make(config: nil) == LaunchOptions(models: [], defaultModelLabel: "默认",
                                                               defaultEffortLabel: "默认（跟随全局）"))
        print("PASS: options for gateway pipeline / direct line / alias / missing config")

        let base = ["/x/ccgo", "gw-a", "/p"]
        check(LaunchOptions.ccgoArguments(ccgo: "/x/ccgo", provider: "gw-a", project: "/p", model: nil, effort: nil) == base)
        check(LaunchOptions.ccgoArguments(ccgo: "/x/ccgo", provider: "gw-a", project: "/p", model: "", effort: "") == base)
        check(LaunchOptions.ccgoArguments(ccgo: "/x/ccgo", provider: "gw-a", project: "/p", model: "m", effort: nil)
              == base + ["--model", "m"])
        check(LaunchOptions.ccgoArguments(ccgo: "/x/ccgo", provider: "gw-a", project: "/p", model: nil, effort: "max")
              == base + ["--effort", "max"])
        check(LaunchOptions.ccgoArguments(ccgo: "/x/ccgo", provider: "gw-a", project: "/p", model: "m", effort: "low")
              == base + ["--model", "m", "--effort", "low"])
        print("PASS: ccgo arguments carry only what was chosen")
        check(effortDisplayName("max") == "最高 · max" && effortDisplayName("weird") == "weird")
        print("PASS: effort display names")
    }
}
