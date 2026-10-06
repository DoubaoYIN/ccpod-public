import Foundation

// QuotaAdapters — 额度数据模型 + 主机规则表 + 纯函数解析器。
// 网络与解析分离：本文件不发请求、不读配置、不碰钥匙串，只把 Data 变成 BalanceInfo，
// 因此可以被 scripts/tests/quota_parsers.swift 单独编译，用实测样本断言具体数值。
// 字段全部以 2026-10-01 真 key 实测为准（样本见 scripts/tests/fixtures/quota/）。

enum QuotaUnit: String {
    case usd
    case cny
    case count     // 次数/积分（GLM、Kimi 只给数量，不是钱）
    /// 百分比。上游只给"剩百分之几"、不给绝对量时用（MiniMax Coding Plan 实测：
    /// `current_interval_remaining_percent`）。窗口仍按 total=100 / used=100-pct 建模，
    /// 这样 remainingRatio 与进度条复用既有逻辑；单位单独标出来是为了**明细行不说谎**——
    /// 若沿用 .count，明细会写成「已用 1 / 100 次」，把百分比说成次数。
    case percent
}

struct QuotaWindow: Identifiable {
    let period: QuotaPeriod
    let label: String
    let remaining: Double
    let total: Double
    let used: Double
    let resetAt: Date?
    let expiresAt: Date?
    var unit: QuotaUnit = .usd

    var id: String { "\(period.rawValue):\(label)" }

    var progress: Double? {
        guard total > 0 else { return nil }
        return min(max(used / total, 0), 1)
    }

    /// 剩余比例（0-1）；钱包类窗口没有总量时为 nil。
    var remainingRatio: Double? {
        progress.map { 1 - $0 }
    }
}

enum QuotaPeriod: String {
    case fiveHour
    case day
    case week
    case month
    case unknown

    var sortOrder: Int {
        switch self {
        case .fiveHour: return 0
        case .day: return 1
        case .week: return 2
        case .month: return 3
        case .unknown: return 4
        }
    }

    /// 大白话标签（不用 D/W 缩写）。
    var shortLabel: String {
        switch self {
        case .fiveHour: return "5 小时"
        case .day: return "今日"
        case .week: return "本周"
        case .month: return "本月"
        case .unknown: return "额度"
        }
    }
}

/// 一条管线额度的"可查程度"。UI 不能把"不支持""失败""没查过"都显示成空白。
enum QuotaStatus: Equatable {
    case ok
    /// 服务商限制了用途（如 aigocode 只认 Claude Code 客户端）：不发任何请求。
    case restricted(reason: String, url: URL?)
    /// 没有接入（ZenMux 额度不足、未识别的中转接口等）。
    case notIntegrated(reason: String)
    /// 只能在网页控制台登录后查看（百炼 Coding Plan 实测 ConsoleNeedLogin）。
    case consoleOnly(url: URL)
    case failed(reason: String)

    var rawName: String {
        switch self {
        case .ok: return "ok"
        case .restricted: return "restricted"
        case .notIntegrated: return "notIntegrated"
        case .consoleOnly: return "consoleOnly"
        case .failed: return "failed"
        }
    }

    /// 非 ok 时给用户看的一句话。
    var message: String? {
        switch self {
        case .ok: return nil
        case .restricted(let reason, _): return reason
        case .notIntegrated(let reason): return reason
        case .consoleOnly: return "仅控制台可查（需网页登录）"
        case .failed(let reason): return reason
        }
    }

    var link: URL? {
        switch self {
        case .restricted(_, let url): return url
        case .consoleOnly(let url): return url
        default: return nil
        }
    }
}

struct BalanceInfo {
    let provider: String
    let remaining: Double
    let total: Double
    let used: Double
    let planName: String
    let windows: [QuotaWindow]
    var status: QuotaStatus = .ok
    /// 套餐下次续费/到期日（GLM subscription/list 的 nextRenewTime）。
    var renewAt: Date? = nil
    var autoRenew: Bool = false
    /// 计划补充说明一行（GLM「季付 · 续费 ¥1291.2/季」，Kimi「加油包已开启 · 本期已扣 ¥0.00」）。
    var planDetail: String? = nil
    var updatedAt: Date = Date()

    func primaryWindows(limit: Int = 2) -> [QuotaWindow] {
        Array(windows.prefix(max(limit, 0)))
    }

    var primaryWindow: QuotaWindow? {
        windows.first
    }

    /// 摘要主角：已用比例最高的有总量窗口（5 小时用完了，本周还剩再多也用不了）；
    /// 都没有总量（钱包）则取第一个。
    var tightestWindow: QuotaWindow? {
        let bounded = windows.filter { $0.progress != nil }
        if let worst = bounded.max(by: { ($0.progress ?? 0) < ($1.progress ?? 0) }) {
            return worst
        }
        return windows.first
    }

    static func status(_ status: QuotaStatus, provider: String, planName: String = "") -> BalanceInfo {
        BalanceInfo(provider: provider, remaining: 0, total: 0, used: 0,
                    planName: planName, windows: [], status: status)
    }
}

/// 额度查询方式。主机规则表优先（确定性、可单测，也避免把 key 发到无关端点），
/// 未知主机才走 sub2api/new-api/ZenMux 三路盲探。
enum QuotaKind: Equatable {
    case glmPlan
    case kimiCoding
    case deepseekBalance
    /// MiniMax Coding Plan / Token Plan：`GET /v1/token_plan/remains`（Bearer，模型 key 即可）。
    /// 上游**不给绝对量**——只给 `*_remaining_percent`；count 字段在该 plan 下恒为 0，
    /// 别拿它算（社区对 count 语义有两种相反说法，实测证伪：都是 0，本就不承载信息）。
    case minimaxPlan
    /// 百炼 Token Plan：走 ModelStudio OpenAPI（RAM AK 签名，ACS3Signer），
    /// 模型 key（sk-sp-）打不了这组接口。没配 AK 时降级为「仅控制台」。
    case aliyunTokenPlan
    /// YesCode：自研 API，模型 key（cr_）查不了余额（403 明说只认用户会话），
    /// 需账号密码登录换 JWT。凭证从钥匙串来（ccpod-yescode-username/-password）。
    case yescodePlan
    case probe
    case fixed(QuotaStatus)
}

enum QuotaAdapters {
    static let bailianConsole = URL(string: "https://bailian.console.aliyun.com/")!
    static let userAgent = "ccpod-quota/1.0"

    /// 返回 nil = 不是上游（本机网关等），不查。
    static func kind(for baseURL: URL) -> QuotaKind? {
        guard let host = baseURL.host?.lowercased(), !host.isEmpty else { return nil }
        if host == "127.0.0.1" || host == "localhost" || host == "::1" { return nil }
        if host.hasSuffix("bigmodel.cn") || host == "z.ai" || host.hasSuffix(".z.ai") { return .glmPlan }
        if host == "api.kimi.com" { return .kimiCoding }
        if host == "deepseek.com" || host.hasSuffix(".deepseek.com") { return .deepseekBalance }
        // MiniMax：国内站 .cn / 国际站 .io（国际站为推断，未实测——用户 key 是国内站的）。
        // 2026-10-02 实测：`GET {origin}/v1/token_plan/remains` 双站可通、Bearer 模型 key 即可，
        // 返回真实窗口数据；此前盲探三路都没识别 → 一直错标 notIntegrated。
        // ⚠️ 别用 `openplatform/coding_plan/remains` 那个端点判死刑：第三方资料说它拒 sk-cp- key
        // （2062 no active token plan），但那是**另一个端点**，不代表 MiniMax 没有额度接口。
        if host == "minimax.cn" || host.hasSuffix(".minimax.cn")
            || host == "minimaxi.com" || host.hasSuffix(".minimaxi.com") { return .minimaxPlan }
        if host.hasSuffix("aliyuncs.com") {
            // token-plan.*：优先走 ModelStudio OpenAPI 查 Credits（需 RAM AK）；
            // 没配 AK 时 BalanceService 降级为「仅控制台」。模型 key 打控制台接口
            // 回 ConsoleNeedLogin（2026-10-01 实测），那条路废弃。
            if host.hasPrefix("token-plan") { return .aliyunTokenPlan }
            return .fixed(.notIntegrated(reason: "阿里云按量计费，余额请到控制台看"))
        }
        if host == "aigocode.dev" || host.hasSuffix(".aigocode.dev") {
            // 2026-10-02 实测：限客户端的只是 /v1/messages 模型接口；余额接口 /v1/usage
            // 普通 UA 也能查（200 + planName 钱包余额）。放开通用盲探，sub2api 端点会命中。
            return .probe
        }
        if host == "zenmux.ai" || host.hasSuffix(".zenmux.ai") {
            return .fixed(.notIntegrated(reason: "未接入额度查询"))
        }
        if host == "yes.vg" || host.hasSuffix(".yes.vg") {
            // 自研系统（/api/v1/*，cr_ key），2026-10-02 实测+yescode-status 项目文档
            return .yescodePlan
        }
        return .probe
    }

    /// 该方式要发的请求（顺序即解析参数顺序）。fixed/probe 返回空：fixed 一个请求都不发，
    /// probe 由 BalanceService 的既有三路探测负责。
    static func requests(for kind: QuotaKind, baseURL: URL, key: String) -> [URLRequest] {
        func origin(_ url: URL) -> String {
            var comps = URLComponents()
            comps.scheme = url.scheme ?? "https"
            comps.host = url.host
            comps.port = url.port
            return comps.string ?? ""
        }
        func make(_ string: String, auth: String) -> URLRequest? {
            guard let url = URL(string: string) else { return nil }
            var req = URLRequest(url: url)
            req.setValue(auth, forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            return req
        }
        switch kind {
        case .glmPlan:
            // 智谱这两个接口要裸 key（不带 Bearer），实测
            let host = origin(baseURL)
            return [
                make(host + "/api/monitor/usage/quota/limit", auth: key),
                make(host + "/api/biz/subscription/list", auth: key),
            ].compactMap { $0 }
        case .kimiCoding:
            return [
                make("https://api.kimi.com/coding/v1/usages", auth: "Bearer \(key)"),
                // /coding/v1/me：会员档位（user_level_name，2026-10-01 实测）
                make("https://api.kimi.com/coding/v1/me", auth: "Bearer \(key)"),
            ].compactMap { $0 }
        case .deepseekBalance:
            return [make(origin(baseURL) + "/user/balance", auth: "Bearer \(key)")].compactMap { $0 }
        case .minimaxPlan:
            // 用线路自己的 origin（.cn 或 .io），与 key 的归属站一致
            return [make(origin(baseURL) + "/v1/token_plan/remains", auth: "Bearer \(key)")].compactMap { $0 }
        case .aliyunTokenPlan, .yescodePlan:
            // 请求由 BalanceService 特殊构造（ACS3 签名 / JWT 登录）
            return []
        case .probe, .fixed:
            return []
        }
    }

    // MARK: - Parsers（Data → BalanceInfo）

    /// GLM Coding Plan：limit 必需，subscription 可选（只用来拿套餐名与续费日）。
    static func parseGLM(provider: String, limit: Data, subscription: Data?) -> BalanceInfo? {
        guard let json = object(limit), let data = json["data"] as? [String: Any],
              let limits = data["limits"] as? [[String: Any]] else { return nil }
        var windows: [QuotaWindow] = []
        for item in limits {
            // unit: 3=小时、5=月、6=周（实测 3/6；5 为社区实现推断，未实测）
            let unit = intValue(item["unit"]) ?? 0
            let number = intValue(item["number"]) ?? 0
            let period: QuotaPeriod
            switch (unit, number) {
            case (3, 5): period = .fiveHour
            case (6, 1): period = .week
            case (5, 1): period = .month
            default: continue
            }
            let total = doubleValue(item["usage"]) ?? 0
            let used = doubleValue(item["currentValue"]) ?? 0
            guard total > 0 else { continue }
            let remaining = doubleValue(item["remaining"]) ?? max(total - used, 0)
            windows.append(QuotaWindow(period: period, label: period.shortLabel,
                                       remaining: remaining, total: total, used: used,
                                       resetAt: item["nextResetTime"].flatMap(parseDate), expiresAt: nil,
                                       unit: .count))
        }
        let level = (data["level"] as? String) ?? ""
        var planName = level.isEmpty ? "GLM Coding" : "GLM Coding \(level.capitalized)"
        var renewAt: Date?
        var autoRenew = false
        var planDetail: String?
        if let subscription, let sub = object(subscription),
           let list = sub["data"] as? [[String: Any]],
           let current = list.first(where: { ($0["inCurrentPeriod"] as? Bool) == true }) ?? list.first {
            if let name = current["productName"] as? String, !name.isEmpty { planName = name }
            renewAt = (current["nextRenewTime"] as? String).flatMap(parseDay)
            autoRenew = intValue(current["autoRenew"]) == 1
            let cycles = ["monthly": "月付", "quarterly": "季付", "yearly": "年付"]
            let cycle = (current["billingCycle"] as? String).flatMap { cycles[$0] }
            var parts: [String] = []
            if let cycle { parts.append(cycle) }
            if let price = doubleValue(current["renewPrice"]), price > 0 {
                parts.append(String(format: "续费 ¥%.1f", price) + (cycle.map { "/" + String($0.prefix(1)) } ?? ""))
            }
            if !parts.isEmpty { planDetail = parts.joined(separator: " · ") }
        }
        var info = normalize(provider: provider, planName: planName, windows: windows)
        info.renewAt = renewAt
        info.autoRenew = autoRenew
        info.planDetail = planDetail
        return info
    }

    /// Kimi Coding：`usage` 是周额度，`limits[]` 是按时长的窗口（实测 300 分钟 = 5 小时）。
    /// me（/coding/v1/me，可选）带会员档位；booster_wallet 带加油包月充值信息（金额单位是分）。
    /// 月度主额度池不在 coding API 里（App「我的→会员计划」才能看），这里只有频控窗口。
    static func parseKimi(provider: String, data: Data, me: Data? = nil) -> BalanceInfo? {
        guard let json = object(data) else { return nil }
        var windows: [QuotaWindow] = []
        func window(_ detail: [String: Any], period: QuotaPeriod) -> QuotaWindow? {
            guard let total = doubleValue(detail["limit"]), total > 0 else { return nil }
            let remaining = doubleValue(detail["remaining"]) ?? 0
            return QuotaWindow(period: period, label: period.shortLabel,
                               remaining: remaining, total: total, used: max(total - remaining, 0),
                               resetAt: detail["resetTime"].flatMap(parseDate), expiresAt: nil, unit: .count)
        }
        if let limits = json["limits"] as? [[String: Any]] {
            for item in limits {
                guard let win = item["window"] as? [String: Any],
                      let detail = item["detail"] as? [String: Any] else { continue }
                let duration = doubleValue(win["duration"]) ?? 0
                let scale: Double
                switch win["timeUnit"] as? String {
                case "TIME_UNIT_MINUTE": scale = 60
                case "TIME_UNIT_HOUR": scale = 3600
                case "TIME_UNIT_DAY": scale = 86400
                default: scale = 1
                }
                let seconds = duration * scale
                let period: QuotaPeriod
                switch seconds {
                case 18_000: period = .fiveHour
                case 86_400: period = .day
                case 604_800: period = .week
                default: continue
                }
                if let w = window(detail, period: period) { windows.append(w) }
            }
        }
        if let usage = json["usage"] as? [String: Any],
           !windows.contains(where: { $0.period == .week }),
           let w = window(usage, period: .week) {
            windows.append(w)
        }
        guard !windows.isEmpty else { return nil }
        var planName = "Kimi Coding"
        if let me, let obj = object(me),
           let tier = (obj["user_level_name"] as? String), !tier.isEmpty {
            planName += " · \(tier)"
        }
        var planDetail: String?
        if let booster = json["booster_wallet"] as? [String: Any] {
            // 2026-10-02 用户 App 实证：加油包页显示「余额 ¥0 / 本周期消费 ¥0 / 消费无限制」——
            // 接口的 monthlyChargeLimit(10000分) ≠ 消费上限（App 明示无限制），大概率是
            // 自动代扣授权阈值。只显示有 App 对照的字段（monthlyUsed 0→¥0.00 一致，按分），
            // 不编造上限。
            func cents(_ key: String) -> Double? {
                (booster[key] as? [String: Any]).flatMap { doubleValue($0["priceInCents"]) }
            }
            let opened = (booster["status"] as? String) == "STATUS_ACTIVE"
            if opened, let used = cents("monthlyUsed") {
                planDetail = String(format: "加油包已开启 · 本期已扣 ¥%.2f", used / 100)
            }
        }
        var info = normalize(provider: provider, planName: planName, windows: windows)
        info.planDetail = planDetail
        return info
    }

    /// MiniMax Coding / Token Plan：`GET /v1/token_plan/remains`（Bearer 模型 key）。
    ///
    /// 2026-10-02 用真 key 实测的响应形状（**只取百分比字段**）：
    /// ```json
    /// {"model_remains": [{"model_name": "general",
    ///    "start_time": 1790906400000, "end_time": 1790924400000,          // 5 小时窗口（ms）
    ///    "current_interval_remaining_percent": 99,
    ///    "weekly_start_time": 1790524800000, "weekly_end_time": 1791129600000,
    ///    "current_weekly_remaining_percent": 99,
    ///    "current_interval_total_count": 0, "current_interval_usage_count": 0,
    ///    "weekly_boost_permille": 1500, "current_interval_status": 1},
    ///   {"model_name": "video", …}],                                       // 视频池，coding 不用
    ///  "base_resp": {"status_code": 0, "status_msg": "success"}}
    /// ```
    /// **为什么不用 count 字段**：社区对 `current_interval_usage_count` 是「已用」还是「剩余」
    /// 有两种截然相反的说法；实测证伪——该 plan 的 count 字段**恒为 0**，本就不承载信息，
    /// 上游只暴露百分比。所以窗口按 total=100 / used=100-pct 建模并标 `unit: .percent`，
    /// 这样进度条复用既有逻辑，而明细行不会把百分比说成「次」。
    /// `weekly_boost_permille` 语义未核实，**不展示**（宁可少说，不装成事实）。
    static func parseMinimax(provider: String, data: Data) -> BalanceInfo? {
        guard let json = object(data),
              let list = json["model_remains"] as? [[String: Any]] else { return nil }
        // "general" = 文本/Coding 池；没有就退第一条（video 池不用于 coding）
        guard let e = list.first(where: { ($0["model_name"] as? String) == "general" }) ?? list.first
        else { return nil }

        var windows: [QuotaWindow] = []
        func percentWindow(_ key: String, resetKey: String, period: QuotaPeriod) {
            guard let pct = e[key].flatMap(doubleValue) else { return }
            windows.append(QuotaWindow(
                period: period, label: period.shortLabel,
                remaining: pct, total: 100, used: max(100 - pct, 0),
                resetAt: e[resetKey].flatMap(parseDate), expiresAt: nil, unit: .percent))
        }
        percentWindow("current_interval_remaining_percent", resetKey: "end_time", period: .fiveHour)
        percentWindow("current_weekly_remaining_percent", resetKey: "weekly_end_time", period: .week)

        guard !windows.isEmpty else { return nil }
        let level = (json["base_resp"] as? [String: Any]).flatMap { $0["status_msg"] as? String }
        let planName = (level == "success" || level == nil) ? "MiniMax Coding Plan" : "MiniMax"
        return normalize(provider: provider, planName: planName, windows: windows)
    }

    /// 百炼 Token Plan（GetSubscriptionStats）。字段 PascalCase（SDK 模型 name 映射证实）。
    /// 时间戳单位未知（秒/毫秒），parseDate 自适应。
    static func parseAliyun(provider: String, data: Data) -> BalanceInfo? {
        guard let json = object(data), let payload = json["Data"] as? [String: Any] else { return nil }
        let total = doubleValue(payload["SeatCredits"]) ?? 0
        let remaining = doubleValue(payload["SeatRemainingCredits"]) ?? 0
        guard total > 0 else { return nil }
        let seatType = (payload["SeatType"] as? String) ?? ""
        let window = QuotaWindow(
            period: .month,
            label: "本期",
            remaining: remaining,
            total: total,
            used: max(total - remaining, 0),
            resetAt: payload["SeatRefreshTime"].flatMap(parseDate),
            expiresAt: nil,
            unit: .count)
        var info = normalize(provider: provider,
                             planName: seatType.isEmpty ? "百炼 Token Plan" : "百炼 Token Plan · \(seatType)",
                             windows: [window])
        info.renewAt = payload["SubscriptionEndTime"].flatMap(parseDate)
        let span = [
            payload["SubscriptionStartTime"].flatMap(parseDate),
            info.renewAt,
        ].compactMap { $0 }.map { Self.dayString($0) }.joined(separator: " ~ ")
        info.planDetail = span.isEmpty ? nil : "订阅期 " + span
        return info
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// YesCode（GET /api/v1/user/balance，JWT）。2026-10-02 实测响应：
    /// `spending_limits[]` 数组带月/周双窗口（limit/spent/resets_at），比第三方文档
    /// 描述的顶层字段丰富；顶层字段做兜底。订阅与 PayGo 是两个独立余额，放 planDetail。
    static func parseYescode(provider: String, data: Data) -> BalanceInfo? {
        guard let json = object(data), let balance = doubleValue(json["total_balance"] ?? json["balance"]) else {
            return nil
        }
        var windows: [QuotaWindow] = []
        if let limits = json["spending_limits"] as? [[String: Any]] {
            for item in limits {
                let key = (item["key"] as? String) ?? ""
                // 后缀精确匹配：contains 会把 "bimonthly" 之类误配成月窗口（测试抓到过）
                let period: QuotaPeriod
                switch key {
                case let k where k.hasSuffix("monthly"): period = .month
                case let k where k.hasSuffix("weekly"): period = .week
                default: continue
                }
                let total = doubleValue(item["limit"]) ?? 0
                let used = doubleValue(item["spent"]) ?? 0
                guard total > 0 else { continue }
                windows.append(QuotaWindow(
                    period: period, label: period.shortLabel,
                    remaining: doubleValue(item["remaining"]) ?? max(total - used, 0),
                    total: total, used: used,
                    resetAt: (item["resets_at"] as? String).flatMap(parseDate),
                    expiresAt: nil, unit: .usd))
            }
            // 半静默防线（对抗性审查 A9）：数组非空但一个窗口都解析不出 = 字段改名/结构变了，
            // 显式失败让用户知道，而不是静默退回旧口径兜底。
            if windows.isEmpty {
                return BalanceInfo.status(
                    .failed(reason: "YesCode 返回结构变了（spending_limits 无法识别），请反馈更新解析器"),
                    provider: provider)
            }
        }
        if windows.isEmpty {
            // 兜底：旧口径顶层字段（无订阅的纯 PayGo）
            let weeklyLimit = doubleValue(json["weekly_limit"]) ?? 0
            let weeklySpent = doubleValue(json["weekly_spent_balance"]) ?? 0
            if weeklyLimit > 0 {
                windows.append(QuotaWindow(period: .week, label: "本周",
                                           remaining: max(weeklyLimit - weeklySpent, 0),
                                           total: weeklyLimit, used: weeklySpent,
                                           resetAt: (json["weekly_reset_at"] as? String).flatMap(parseDate),
                                           expiresAt: nil, unit: .usd))
            }
        }
        let payg = doubleValue(json["pay_as_you_go_balance"])
        let subscription = doubleValue(json["subscription_balance"]) ?? 0
        let subscribed = (json["subscription_active"] as? Bool) == true
        if windows.isEmpty {
            windows.append(QuotaWindow(period: .unknown, label: "PayGo 余额",
                                       remaining: payg ?? balance, total: 0, used: 0,
                                       resetAt: nil, expiresAt: nil, unit: .usd))
        }
        var info = normalize(provider: provider,
                             planName: subscribed ? "YesCode · 订阅" : "YesCode",
                             windows: windows)
        var parts: [String] = []
        if subscription > 0 { parts.append(String(format: "订阅余额 $%.0f", subscription)) }
        if let payg { parts.append(String(format: "PayGo $%.2f", payg)) }
        if !parts.isEmpty { info.planDetail = parts.joined(separator: " · ") }
        return info
    }

    /// DeepSeek 按量：人民币余额，没有总量。
    static func parseDeepSeek(provider: String, data: Data) -> BalanceInfo? {
        guard let json = object(data), let infos = json["balance_infos"] as? [[String: Any]],
              let first = infos.first(where: { ($0["currency"] as? String) == "CNY" }) ?? infos.first,
              let balance = doubleValue(first["total_balance"]) else { return nil }
        let unit: QuotaUnit = (first["currency"] as? String) == "USD" ? .usd : .cny
        let window = QuotaWindow(period: .unknown, label: "余额", remaining: balance,
                                 total: 0, used: 0, resetAt: nil, expiresAt: nil, unit: unit)
        var info = normalize(provider: provider, planName: "DeepSeek 按量", windows: [window])
        if (json["is_available"] as? Bool) == false {
            info.status = .failed(reason: "余额不足，已不可用")
        }
        return info
    }

    /// sub2api `/v1/usage`：订阅（日/周/月美元额度）、rate_limits（5h/1d/7d）、quota、钱包。
    static func parseSub2api(provider: String, data: Data) -> BalanceInfo? {
        guard let json = object(data) else { return nil }
        let fallbackRemaining = doubleValue(json["remaining"]) ?? 0
        let planName = json["planName"] as? String ?? ""
        let balance = doubleValue(json["balance"])
        let topExpiry = extractDate(from: json, keys: ["expires_at", "expire_at", "expired_at"])
        var fallbackTotal = balance ?? fallbackRemaining
        var fallbackUsed = 0.0
        if let balance, balance > 0 {
            fallbackUsed = max(balance - fallbackRemaining, 0)
        }

        var windows: [QuotaWindow] = []
        if let sub = json["subscription"] as? [String: Any] {
            let expiresAt = extractDate(from: sub, keys: ["expires_at", "expire_at", "expired_at", "access_until"]) ?? topExpiry
            let periods: [(QuotaPeriod, String, String, [String])] = [
                (.day,   "daily_limit_usd",   "daily_usage_usd",
                 ["daily_reset_at",   "daily_resets_at",   "next_daily_reset_at"]),
                (.week,  "weekly_limit_usd",  "weekly_usage_usd",
                 ["weekly_reset_at",  "weekly_resets_at",  "next_weekly_reset_at"]),
                (.month, "monthly_limit_usd", "monthly_usage_usd",
                 ["monthly_reset_at", "monthly_resets_at", "next_monthly_reset_at"]),
            ]
            for (period, limitKey, usageKey, resetKeys) in periods {
                let limit = doubleValue(sub[limitKey]) ?? 0
                guard limit > 0 else { continue }
                let used = doubleValue(sub[usageKey]) ?? 0
                windows.append(QuotaWindow(period: period, label: period.shortLabel,
                                           remaining: max(limit - used, 0), total: limit, used: max(used, 0),
                                           resetAt: extractDate(from: sub, keys: resetKeys), expiresAt: expiresAt))
            }
        }
        // rate_limits[]：{window "5h"|"1d"|"7d", limit, used, remaining, reset_at}（社区文档，未实测）
        if let rates = json["rate_limits"] as? [[String: Any]] {
            for item in rates {
                let period: QuotaPeriod
                switch (item["window"] as? String)?.lowercased() {
                case "5h": period = .fiveHour
                case "1d", "24h": period = .day
                case "7d": period = .week
                case "30d": period = .month
                default: continue
                }
                guard !windows.contains(where: { $0.period == period }),
                      let limit = doubleValue(item["limit"]), limit > 0 else { continue }
                let used = doubleValue(item["used"]) ?? max(limit - (doubleValue(item["remaining"]) ?? limit), 0)
                windows.append(QuotaWindow(period: period, label: period.shortLabel,
                                           remaining: doubleValue(item["remaining"]) ?? max(limit - used, 0),
                                           total: limit, used: used,
                                           resetAt: extractDate(from: item, keys: ["reset_at", "resets_at"]),
                                           expiresAt: topExpiry))
            }
        }
        // quota{limit, used, remaining}：总量型（未实测）
        if windows.isEmpty, let quota = json["quota"] as? [String: Any],
           let limit = doubleValue(quota["limit"]), limit > 0 {
            let used = doubleValue(quota["used"]) ?? 0
            windows.append(QuotaWindow(period: .unknown, label: planName.isEmpty ? "总额度" : planName,
                                       remaining: doubleValue(quota["remaining"]) ?? max(limit - used, 0),
                                       total: limit, used: used, resetAt: nil, expiresAt: topExpiry))
        }
        if windows.isEmpty, let balance, !planName.isEmpty {
            // 套餐用尽切到灵活额度 / 纯钱包 key：subscription 缺失但有 planName + balance
            windows.append(QuotaWindow(period: .unknown, label: planName, remaining: balance,
                                       total: 0, used: 0, resetAt: nil, expiresAt: topExpiry))
        }
        if let primary = windows.first(where: { $0.total > 0 }) {
            fallbackTotal = primary.total
            fallbackUsed = primary.used
        }
        return normalize(provider: provider, planName: planName, windows: windows,
                         fallbackRemaining: windows.first?.remaining ?? fallbackRemaining,
                         fallbackTotal: fallbackTotal, fallbackUsed: fallbackUsed)
    }

    // MARK: - Normalize

    static func normalize(provider: String, planName: String, windows: [QuotaWindow],
                          fallbackRemaining: Double = 0, fallbackTotal: Double = 0,
                          fallbackUsed: Double = 0) -> BalanceInfo {
        var normalized = windows
            .map { window -> QuotaWindow in
                // 钱包窗口（unknown）允许 remaining 为负数表示透支；订阅窗口仍夹到 ≥0
                let keepNegative = window.period == .unknown
                return QuotaWindow(
                    period: window.period,
                    label: window.label.isEmpty ? window.period.shortLabel : window.label,
                    remaining: keepNegative ? window.remaining : max(window.remaining, 0),
                    total: max(window.total, 0),
                    used: max(window.used, 0),
                    resetAt: window.resetAt,
                    expiresAt: window.expiresAt,
                    unit: window.unit
                )
            }
            .filter { window in
                if window.period == .unknown {
                    return window.total > 0 || window.used > 0 || window.remaining != 0 || !window.label.isEmpty
                }
                return window.total > 0 || window.used > 0 || window.remaining > 0
            }
            .sorted(by: sortWindows)

        let total = max(fallbackTotal, 0)
        let used = max(fallbackUsed, 0)
        if normalized.isEmpty && (total > 0 || used > 0 || fallbackRemaining != 0) {
            normalized = [
                QuotaWindow(period: .unknown,
                            label: planName.isEmpty ? QuotaPeriod.unknown.shortLabel : planName,
                            remaining: fallbackRemaining, total: total, used: used,
                            resetAt: nil, expiresAt: nil)
            ]
        }

        let primary = normalized.first
        return BalanceInfo(
            provider: provider,
            remaining: primary?.remaining ?? fallbackRemaining,
            total: primary?.total ?? total,
            used: primary?.used ?? used,
            planName: planName,
            windows: normalized
        )
    }

    private static func sortWindows(_ lhs: QuotaWindow, _ rhs: QuotaWindow) -> Bool {
        if lhs.period.sortOrder != rhs.period.sortOrder {
            return lhs.period.sortOrder < rhs.period.sortOrder
        }
        if lhs.total != rhs.total {
            return lhs.total > rhs.total
        }
        return lhs.label < rhs.label
    }

    // MARK: - Value helpers

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func intValue(_ raw: Any?) -> Int? {
        doubleValue(raw).map { Int($0) }
    }

    static func extractDate(from dict: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let raw = dict[key] else { continue }
            if let date = parseDate(raw) {
                return date
            }
        }
        return nil
    }

    static func parseDate(_ raw: Any) -> Date? {
        if let value = raw as? Double {
            return dateFromTimestamp(value)
        }
        if let value = raw as? Int {
            return dateFromTimestamp(Double(value))
        }
        if let value = raw as? NSNumber {
            return dateFromTimestamp(value.doubleValue)
        }
        if let value = raw as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let numeric = Double(trimmed) {
                return dateFromTimestamp(numeric)
            }
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: trimmed) {
                return date
            }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: trimmed) {
                return date
            }
            // Kimi 实测带 6 位微秒（2026-10-02T03:19:10.513069Z），ISO8601DateFormatter 只认 3 位
            if let dot = trimmed.firstIndex(of: "."), trimmed.hasSuffix("Z") {
                return iso.date(from: String(trimmed[..<dot]) + "Z")
            }
        }
        return nil
    }

    /// "2026-11-11" → 本地时区当天 00:00。
    static func parseDay(_ raw: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: raw.trimmingCharacters(in: .whitespaces))
    }

    private static func dateFromTimestamp(_ raw: Double) -> Date? {
        guard raw > 0 else { return nil }
        let seconds = raw > 1_000_000_000_000 ? raw / 1000.0 : raw
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - 显示文案（纯函数，单测可断言；UI 只拼不算）

extension QuotaUnit {
    /// 金额带币种符号；次数取整（GLM/Kimi 给的是次数，不是钱）。
    func amount(_ value: Double, precise: Bool = false) -> String {
        switch self {
        case .usd: return String(format: precise ? "$%.4f" : "$%.2f", value)
        case .cny: return String(format: precise ? "¥%.4f" : "¥%.2f", value)
        case .count: return String(format: "%.0f", value.rounded())
        case .percent: return String(format: "%.0f%%", value.rounded())
        }
    }

    var suffix: String {
        switch self {
        case .count: return " 次"
        case .percent: return "%"
        case .usd, .cny: return ""
        }
    }
}

extension QuotaWindow {
    var remainingPercent: Int? {
        remainingRatio.map { Int(($0 * 100).rounded()) }
    }

    /// 摘要：有总量 → "5 小时剩 95%"；钱包 → "余额 ¥94.17" / "透支 $0.3445"。
    var summaryText: String {
        if let percent = remainingPercent {
            return "\(label)剩 \(percent)%"
        }
        if remaining < 0 { return "透支 " + unit.amount(-remaining, precise: true) }
        return "余额 " + unit.amount(remaining)
    }

    /// 明细："已用 569 / 12000 次"、"已用 $1.20 / $5.00"；钱包同摘要。
    var amountText: String {
        guard total > 0 else { return summaryText }
        return "已用 \(unit.amount(used)) / \(unit.amount(total))\(unit.suffix)"
    }
}

extension BalanceInfo {
    /// 管线行内一行字："GLM Coding Pro · 5 小时剩 95% · 15:40 重置"。非 ok 返回 status 原因。
    func summaryLine(now: Date = Date()) -> String {
        if let message = status.message { return message }
        var parts: [String] = []
        if !planName.isEmpty { parts.append(planName) }
        if let window = tightestWindow {
            parts.append(window.summaryText)
            if window.total > 0, let reset = window.resetAt, reset > now {
                parts.append(QuotaAdapters.resetPhrase(reset, now: now))
            }
        }
        return parts.isEmpty ? "没有额度数据" : parts.joined(separator: " · ")
    }

    /// 列表行右侧的短标签（一行放得下）："本周剩 64%"、"透支 $0.3445"、"控制台查看"。
    /// 完整说明看 summaryLine / 展开区。
    var shortText: String {
        switch status {
        case .ok:
            // 双窗口（5 小时 + 本周）都显示，用户不用展开就能看到两个数；
            // 单窗口（钱包/按量）只显示它。
            let bounded = windows.filter { $0.progress != nil }
            if bounded.count >= 2 {
                return bounded.prefix(2)
                    .map { "\($0.label)剩 \($0.remainingPercent ?? 0)%" }
                    .joined(separator: " · ")
            }
            return tightestWindow?.summaryText ?? "没有数据"
        case .restricted: return "官网查看"
        case .consoleOnly: return "控制台查看"
        case .notIntegrated: return "未接入"
        case .failed: return "查询失败"
        }
    }

    /// 有窗口用尽（有总量的剩 0，或钱包透支）。
    var isExhausted: Bool {
        windows.contains { $0.total > 0 ? $0.remaining <= 0 : $0.remaining < 0 }
    }
}

extension QuotaAdapters {
    /// 今天内 → "15:40 重置"；更远 → "10/05 重置"。
    static func resetPhrase(_ date: Date, now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "MM/dd HH:mm"
        return fmt.string(from: date) + " 重置"
    }
}
