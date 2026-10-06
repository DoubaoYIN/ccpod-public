import Foundation

/// 模型族归并 + 超代清理建议（纯函数，可独立验证）。
///
/// 规则（用户拍板 2026-10-02）：每个模型族只保留最近两代，更老的标 🟡「建议清理」。
/// 族统计口径 = 本地列表 ∪ 新拉取列表（新拉取到的新一代要参与"谁超代"的判定），
/// 但建议标记只打在本地已有的行上。
///
/// 族归并样例（实测数据）：
///   qwen3.8-max / qwen3.7-max      → 族 "qwen-max"
///   glm-5.2 / glm-5.3              → 族 "glm"
///   glm-5.3-flash                  → 族 "glm-flash"
///   claude-opus-5-5 / claude-opus-4-8 → 族 "claude-opus"
///   x-ai/grok-4.7 / x-ai/grok-4.6     → 族 "x-ai-grok"（分隔符归一，分组不受影响）
enum ModelPruneAdvisor {

    /// 族键：小写 → 删除数字段（含小数点）→ 折叠 "-./_" 分隔并去首尾。
    /// 只作分组键用，不展示给用户，所以分隔符（含命名空间的 /）归一成 "-" 无所谓。
    static func familyKey(_ model: String) -> String {
        var key = model.lowercased()
        key = key.replacingOccurrences(of: #"[0-9]+(\.[0-9]+)*"#,
                                       with: "", options: .regularExpression)
        key = key.replacingOccurrences(of: #"[-./_]+"#,
                                       with: "-", options: .regularExpression)
        return key.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// 版本序：所有数字段展平成 [Int]（"qwen3.8-max" → [3,8]，"claude-opus-5-5" → [5,5]）。
    /// GatewayLineService.suggestedModel 里有同款实现，但那是嵌套函数外部不可见，此处自带。
    static func versionRank(_ model: String) -> [Int] {
        let regex = try! NSRegularExpression(pattern: #"[0-9]+(\.[0-9]+)*"#)
        let nsRange = NSRange(model.startIndex..., in: model)
        return regex.matches(in: model, range: nsRange).flatMap { match -> [Int] in
            guard let range = Range(match.range, in: model) else { return [] }
            return model[range].split(separator: ".").compactMap { Int($0) }
        }
    }

    /// 版本标量：取版本序前两段合成（[3,8]→3008、[5]→5000、[4,6]→4006）。
    /// 千问/claude 的"连字符数字段"语义上就是点分版本（opus-5-5 = 5.5），前两段足够分代。
    private static func generationScalar(_ rank: [Int]) -> Int? {
        guard let major = rank.first else { return nil }
        return major * 1000 + (rank.count > 1 ? rank[1] : 0)
    }

    /// 以族内最新版本为锚（口径 = 本地 ∪ 新拉取），落后 keepGenerations 代及以上的
    /// 本地模型进建议集合。keepGenerations=2 即用户拍板的"3.8 出了最多留到 3.7"：
    /// 族里有 3.8 时，3.6（落后 2 代）标 🟡，3.7/3.8 保留。
    /// 无数字段的模型（如 kimi-for-coding）没有版本序，永不建议。
    static func staleSuggestions(_ models: [String], fetched: [String] = [],
                                 keepGenerations: Int = 2) -> Set<String> {
        var newest: [String: Int] = [:]
        for name in models + fetched {
            guard let scalar = generationScalar(versionRank(name)) else { continue }
            let family = familyKey(name)
            newest[family] = max(newest[family] ?? 0, scalar)
        }
        var stale = Set<String>()
        for name in models {
            guard let scalar = generationScalar(versionRank(name)),
                  let anchor = newest[familyKey(name)],
                  anchor - scalar >= keepGenerations else { continue }
            stale.insert(name)
        }
        return stale
    }
}

/// 护栏：哪些模型禁止/不宜从线路配置里删（及人话原因）。
/// 硬锁（禁勾）= 全局档位六字段引用 + 现行管线（source=="gateway"）的默认模型。
/// 软警告（可勾但附原因）= 仅被 gateway-alias 历史兼容文件引用——删了旧包装命令会断，
/// 但不影响任何现行配置。若把 alias 也硬锁，实测本机几乎每个模型都被 alias 引用，
/// 清理功能会全部禁勾变成假功能（2026-10-02 实测：8 条现行线路 + 28 个 alias 文件）。
struct ModelGuardrail {
    let locked: [String: String]   // 模型 → 锁定原因
    let warned: [String: String]   // 模型 → 警告原因

    /// 档位字段 → 展示名（与 LineSettingsEditor 的五档一致 + smallFastModel 镜像）。
    private static let tierLabels: [(key: String, label: String)] = [
        ("model", "主对话"), ("opusModel", "Opus"), ("sonnetModel", "Sonnet"),
        ("fableModel", "Fable"), ("haikuModel", "Haiku"), ("smallFastModel", "小快模型")
    ]

    /// provider = CCR 线路名；config = fetchConfig 结果（档位读 profile.claudeCode，
    /// 并扫 profile.profiles[] 里 agent=="claude-code" 的条目兜底——两个写入方都可能只改一处）。
    static func evaluate(provider: String, config: [String: Any],
                         directory: URL = FileManager.default.homeDirectoryForCurrentUser
                             .appendingPathComponent(".claude/providers")) -> ModelGuardrail {
        var locked: [String: String] = [:]
        var warned: [String: String] = [:]

        // 1) 档位引用（值形如 "glm,glm-5.3"，逗号分隔；provider 段匹配本线路才算）
        var tierHits: [String: [String]] = [:]
        var tierSources: [[String: Any]] = []
        if let profile = config["profile"] as? [String: Any] {
            if let cc = profile["claudeCode"] as? [String: Any] { tierSources.append(cc) }
            if let profiles = profile["profiles"] as? [[String: Any]] {
                tierSources.append(contentsOf: profiles.filter { $0["agent"] as? String == "claude-code" })
            }
        }
        for source in tierSources {
            for tier in tierLabels {
                guard let value = source[tier.key] as? String, !value.isEmpty else { continue }
                let parts = value.split(separator: ",", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == provider else { continue }
                tierHits[parts[1], default: []].append(tier.label)
            }
        }
        for (model, labels) in tierHits {
            let unique = Array(NSOrderedSet(array: labels)) as? [String] ?? labels
            locked[model] = "档位「\(unique.joined(separator: "/"))」正在使用"
        }

        // 2) 线路文件引用（复用现成读取，规避自行遍历目录的大小写坑）
        for (_, line) in GatewayLineService.readLines(directory) {
            guard line["gateway_provider"] as? String == provider,
                  let model = line["gateway_model"] as? String, !model.isEmpty else { continue }
            switch line["source"] as? String {
            case "gateway":
                locked[model] = [locked[model], "是本线路默认模型"]
                    .compactMap { $0 }.joined(separator: "；")
            case "gateway-alias":
                if locked[model] == nil {
                    warned[model] = "历史线路（旧命令兼容文件）仍在引用，删除后旧命令会断"
                }
            default:
                break
            }
        }
        return ModelGuardrail(locked: locked, warned: warned)
    }
}
