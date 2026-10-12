import Foundation

/// 档位的中文显示名：启动表单和管线管理共用（管线管理在 max 后面自己加「（最慢、最费额度）」）。
func effortDisplayName(_ level: String) -> String {
    switch level {
    case "low": return "低 · low"
    case "medium": return "中 · medium"
    case "high": return "高 · high"
    case "xhigh": return "很高 · xhigh"
    case "max": return "最高 · max"
    default: return level
    }
}

/// 「启动新会话」表单里的模型 / 思考选择：只管这一次启动，不写任何文件，选了才带 ccgo 参数。
/// 设计：docs/superpowers/specs/2026-10-09-launch-model-effort-design.md。纯函数，scripts/tests/launch_options.swift 直接测。
struct LaunchOptions: Equatable {
    /// 可选模型（不带厂商前缀）；空 = 不可选（直连线路 / 读不到配置），选择框灰掉
    var models: [String]
    var defaultModelLabel: String
    var defaultEffortLabel: String

    static func make(config: [String: Any]?) -> LaunchOptions {
        guard let config else {
            return LaunchOptions(models: [], defaultModelLabel: "默认", defaultEffortLabel: "默认（跟随全局）")
        }
        let effortLabel: String
        if let effort = config["effort"] as? String, GatewayLineService.effortLevels.contains(effort) {
            effortLabel = "默认（\(effort)）"
        } else {
            effortLabel = "默认（跟随全局）"
        }
        if config["source"] as? String == "gateway",
           let models = config["gateway_models"] as? [String], !models.isEmpty {
            let current = config["gateway_model"] as? String ?? ""
            return LaunchOptions(models: models,
                                 defaultModelLabel: current.isEmpty ? "默认" : "默认（\(modelDisplayName(current))）",
                                 defaultEffortLabel: effortLabel)
        }
        // 直连线路（别名线路不进选单）：模型由线路文件决定，--model 参数优先于 env
        let args = config["claude_args"] as? [String] ?? []
        var model = (config["env"] as? [String: Any])?["ANTHROPIC_MODEL"] as? String ?? ""
        if let i = args.firstIndex(of: "--model"), i + 1 < args.count { model = args[i + 1] }
        return LaunchOptions(models: [],
                             defaultModelLabel: model.isEmpty ? "固定" : "固定（\(gatewayModelDisplayName(model))）",
                             defaultEffortLabel: effortLabel)
    }

    /// 菜单栏拼 ccgo 命令用的参数（未转义）。nil 或空串 = 不带，ccgo 按管线默认。
    static func ccgoArguments(ccgo: String, provider: String, project: String,
                              model: String?, effort: String?) -> [String] {
        var argv = [ccgo, provider, project]
        if let model, !model.isEmpty { argv += ["--model", model] }
        if let effort, !effort.isEmpty { argv += ["--effort", effort] }
        return argv
    }
}
