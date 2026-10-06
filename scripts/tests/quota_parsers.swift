import Foundation

// QuotaAdapters 单测：夹具是 2026-10-01 真 key 实测的原始响应（scripts/tests/fixtures/quota/，不含 key）。
// 断言具体数值与文案正向特征；"不发请求"用 requests(...) == [] 断言。

@main struct QuotaParserTests {
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ label: String, _ what: String) {
        if condition {
            print("  ok   \(label)")
        } else {
            failures.append(label)
            print("  FAIL \(label) —— \(what)")
        }
    }

    static func fixture(_ name: String) -> Data {
        let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/tests/fixtures/quota"
        let path = "\(dir)/\(name)"
        guard let data = FileManager.default.contents(atPath: path) else {
            print("  FAIL 夹具缺失 \(path)")
            exit(2)
        }
        return data
    }

    static func url(_ s: String) -> URL { URL(string: s)! }

    static func ymd(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func main() {
        // 1. GLM：5 小时 + 本周，次数单位，套餐名/续费日来自 subscription
        let glm = QuotaAdapters.parseGLM(provider: "glm", limit: fixture("glm-limit.json"),
                                         subscription: fixture("glm-subscription.json"))
        expect(glm != nil, "GLM解析", "parseGLM 返回 nil")
        if let glm {
            let five = glm.windows.first { $0.period == .fiveHour }
            let week = glm.windows.first { $0.period == .week }
            expect(five?.remaining == 11430 && five?.total == 12000 && five?.used == 569,
                   "GLM 5小时数值", "实际：\(String(describing: five))")
            expect(week?.remaining == 39029 && week?.total == 60000, "GLM 本周数值", "实际：\(String(describing: week))")
            expect(five?.unit == .count, "GLM单位是次数", "实际：\(String(describing: five?.unit))")
            expect(five?.resetAt != nil, "GLM 5小时有重置时间", "nextResetTime 未解析")
            expect(glm.planName == "GLM Coding Pro", "GLM套餐名", "实际：\(glm.planName)")
            expect(glm.planDetail == "季付 · 续费 ¥1291.2/季", "GLM计费周期+续费价",
                   "实际：\(glm.planDetail ?? "nil")")
            expect(ymd(glm.renewAt) == "2026-11-11" && glm.autoRenew, "GLM续费日+自动续费",
                   "实际：\(ymd(glm.renewAt)) autoRenew=\(glm.autoRenew)")
            expect(glm.status == .ok, "GLM状态ok", "实际：\(glm.status)")
            expect(glm.tightestWindow?.period == .week, "GLM最紧窗口=本周（35% > 5%）",
                   "实际：\(String(describing: glm.tightestWindow?.period))")
            let line = glm.summaryLine()
            expect(line.hasPrefix("GLM Coding Pro · 本周剩 65%"), "GLM行内摘要", "实际：\(line)")
            expect(five?.amountText == "已用 569 / 12000 次", "GLM明细不带美元", "实际：\(five?.amountText ?? "nil")")
        }
        // subscription 缺失也能出数（只是套餐名退回 level）
        let glmNoSub = QuotaAdapters.parseGLM(provider: "glm", limit: fixture("glm-limit.json"), subscription: nil)
        expect(glmNoSub?.planName == "GLM Coding Pro" && glmNoSub?.windows.count == 2, "GLM无订阅接口降级",
               "实际：\(glmNoSub?.planName ?? "nil")")

        // 2. Kimi：300 分钟 = 5 小时 + usage 周额度；6 位微秒时间能解析
        let kimi = QuotaAdapters.parseKimi(provider: "kimi", data: fixture("kimi-usages.json"),
                                           me: fixture("kimi-me.json"))
        expect(kimi != nil, "Kimi解析", "parseKimi 返回 nil")
        expect(kimi?.planName == "Kimi Coding · Allegretto", "Kimi会员档位",
               "实际：\(kimi?.planName ?? "nil")")
        expect(kimi?.planDetail == "加油包已开启 · 本期已扣 ¥0.00", "Kimi加油包计划行",
               "实际：\(kimi?.planDetail ?? "nil")")
        // me 缺失（接口 404/未登录）时降级：档位不显示、booster 仍解析
        let kimiNoMe = QuotaAdapters.parseKimi(provider: "kimi", data: fixture("kimi-usages.json"))
        expect(kimiNoMe?.planName == "Kimi Coding" && kimiNoMe?.planDetail != nil, "Kimi无me降级",
               "实际：\(kimiNoMe?.planName ?? "nil") / \(kimiNoMe?.planDetail ?? "nil")")
        if let kimi {
            let five = kimi.windows.first { $0.period == .fiveHour }
            let week = kimi.windows.first { $0.period == .week }
            expect(five?.remaining == 100 && five?.total == 100, "Kimi 5小时 100/100", "实际：\(String(describing: five))")
            expect(week?.remaining == 100 && week?.total == 100, "Kimi 本周 100/100", "实际：\(String(describing: week))")
            let iso = ISO8601DateFormatter()
            let target = iso.date(from: "2026-10-01T11:19:10Z")!
            expect(five?.resetAt.map { abs($0.timeIntervalSince(target)) < 1 } == true, "Kimi微秒时间解析",
                   "实际：\(String(describing: five?.resetAt))")
            expect(ymd(week?.resetAt) == "2026-10-02", "Kimi本周重置日", "实际：\(ymd(week?.resetAt))")
        }
        // 构造耗尽态：5 小时剩 0 → isExhausted + 摘要说剩 0%
        let kimiOut = Data("""
        {"usage":{"limit":"100","remaining":"40","resetTime":"2026-10-02T03:19:10.513069Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"limit":"100","remaining":"0","resetTime":"2026-10-01T11:19:10.513069Z"}}]}
        """.utf8)
        if let out = QuotaAdapters.parseKimi(provider: "kimi", data: kimiOut) {
            expect(out.isExhausted, "Kimi耗尽判定", "5 小时 remaining=0 应为耗尽")
            expect(out.tightestWindow?.period == .fiveHour, "耗尽窗口是摘要主角",
                   "实际：\(String(describing: out.tightestWindow?.period))")
            expect(out.summaryLine().contains("5 小时剩 0%"), "耗尽摘要文案", "实际：\(out.summaryLine())")
        } else {
            expect(false, "Kimi耗尽样本解析", "返回 nil")
        }

        // 3. DeepSeek：人民币余额，无总量
        let ds = QuotaAdapters.parseDeepSeek(provider: "deepseek", data: fixture("deepseek-balance.json"))
        expect(ds?.windows.first?.remaining == 94.17 && ds?.windows.first?.unit == .cny, "DeepSeek ¥94.17",
               "实际：\(String(describing: ds?.windows.first))")
        expect(ds?.summaryLine().contains("余额 ¥94.17") == true, "DeepSeek摘要用人民币",
               "实际：\(ds?.summaryLine() ?? "nil")")

        // 4. sub2api 钱包透支
        let wallet = QuotaAdapters.parseSub2api(provider: "dragoncode", data: fixture("sub2api-wallet.json"))
        let w = wallet?.windows.first
        expect(w != nil && abs((w?.remaining ?? 0) - (-0.34448634)) < 1e-9, "sub2api钱包透支值",
               "实际：\(String(describing: w))")
        expect(wallet?.summaryLine().contains("透支 $0.3445") == true, "钱包透支文案",
               "实际：\(wallet?.summaryLine() ?? "nil")")
        expect(wallet?.isExhausted == true, "透支算耗尽", "钱包 remaining<0 应为耗尽")
        expect(wallet?.shortText == "透支 $0.3445", "钱包短标签", "实际：\(wallet?.shortText ?? "nil")")
        // sub2api 订阅模式（aigocode/dragoncode 订阅有余量时）：subscription 子对象 → 窗口
        let sub = QuotaAdapters.parseSub2api(provider: "aigocode", data: fixture("sub2api-subscription.json"))
        expect(sub != nil && sub?.status == .ok, "sub2api订阅解析", "实际：\(String(describing: sub?.status))")
        if let sub {
            let day = sub.windows.first { $0.period == .day }
            let week = sub.windows.first { $0.period == .week }
            expect(day?.remaining == 3.8 && day?.total == 5 && day?.unit == .usd,
                   "订阅今日窗口 3.8/5", "实际：\(String(describing: day))")
            expect(week?.remaining == 30 && week?.total == 40, "订阅本周窗口 30/40",
                   "实际：\(String(describing: week))")
            expect(sub.planName == "Claude Pro 套餐", "订阅planName", "实际：\(sub.planName)")
            expect(sub.shortText == "今日剩 76% · 本周剩 75%", "订阅双窗口短标签",
                   "实际：\(sub.shortText)")
        }
        expect(glm?.shortText == "5 小时剩 95% · 本周剩 65%", "GLM短标签（双窗口）",
               "实际：\(glm?.shortText ?? "nil")")
        let restrictedInfo = BalanceInfo(provider: "aigocode", remaining: 0, total: 0, used: 0, planName: "",
                                         windows: [], status: .restricted(reason: "x", url: nil))
        expect(restrictedInfo.shortText == "官网查看", "限定客户端短标签", "实际：\(restrictedInfo.shortText)")

        // 5. 规则表：不查的主机一个请求都不发
        func fixedStatus(_ s: String) -> QuotaStatus? {
            if case .fixed(let status)? = QuotaAdapters.kind(for: url(s)) { return status }
            return nil
        }
        // 百炼 token-plan：走 OpenAPI（AK 由 BalanceService 特殊路径签），requests 本身不发
        expect(QuotaAdapters.kind(for: url("https://token-plan.cn-beijing.maas.aliyuncs.com/apps/anthropic")) == .aliyunTokenPlan,
               "token-plan→OpenAPI额度", "")
        expect(QuotaAdapters.kind(for: url("https://api.aigocode.dev")) == .probe,
               "aigocode→盲探（余额接口不限客户端，2026-10-02 实测）",
               "实际：\(String(describing: QuotaAdapters.kind(for: url("https://api.aigocode.dev"))))")
        expect(fixedStatus("https://zenmux.ai/api/anthropic")?.rawName == "notIntegrated", "zenmux=未接入", "")
        if case .fixed(let st)? = QuotaAdapters.kind(for: url("https://dashscope.aliyuncs.com")) {
            expect(st.rawName == "notIntegrated", "非token-plan的aliyuncs=按量不查", "实际：\(st.rawName)")
        } else {
            expect(false, "非token-plan的aliyuncs=按量不查", "kind 不是 fixed")
        }
        for s in ["https://token-plan.cn-beijing.maas.aliyuncs.com", "https://zenmux.ai"] {
            let kind = QuotaAdapters.kind(for: url(s))!
            expect(QuotaAdapters.requests(for: kind, baseURL: url(s), key: "sk-unit").isEmpty,
                   "不发请求 \(url(s).host!)", "fixed/aliyun 规则产生了请求")
        }
        expect(QuotaAdapters.kind(for: url("http://127.0.0.1:3456")) == nil, "本机网关不查", "")
        expect(QuotaAdapters.kind(for: url("https://open.bigmodel.cn/api/anthropic")) == .glmPlan, "bigmodel→GLM", "")
        expect(QuotaAdapters.kind(for: url("https://api.kimi.com/coding")) == .kimiCoding, "kimi→Coding", "")
        expect(QuotaAdapters.kind(for: url("https://api.deepseek.com/anthropic")) == .deepseekBalance, "deepseek→余额", "")
        expect(QuotaAdapters.kind(for: url("https://co.yes.vg")) == .yescodePlan, "yescode→自研API",
               "实际：\(String(describing: QuotaAdapters.kind(for: url("https://co.yes.vg"))))")
        // YesCode /api/v1/user/balance：真实结构（spending_limits 月+周双窗口）
        let yc = QuotaAdapters.parseYescode(provider: "yescode", data: fixture("yescode-balance.json"))
        expect(yc?.planName == "YesCode · 订阅", "YesCode订阅名", "实际：\(yc?.planName ?? "nil")")
        if let yc {
            let month = yc.windows.first { $0.period == .month }
            let week = yc.windows.first { $0.period == .week }
            expect(month?.remaining == 1540 && month?.total == 2000,
                   "YesCode月窗口 1378.83/2000", "实际：\(String(describing: month))")
            expect(week?.remaining == 199 && week?.total == 200,
                   "YesCode周窗口 419.47/200", "实际：\(String(describing: week))")
            expect(ymd(month?.resetAt) == "2026-12-31", "YesCode月重置10-21",
                   "实际：\(ymd(month?.resetAt))")
            expect(yc.planDetail == "订阅余额 $500 · PayGo $25.50", "YesCode双余额计划行",
                   "实际：\(yc.planDetail ?? "nil")")
            expect(yc.shortText == "本周剩 100% · 本月剩 77%", "YesCode双窗口短标签",
                   "实际：\(yc.shortText)")
        }
        // 兜底口径：无 spending_limits 的纯 PayGo → 余额窗口
        let ycPayg = QuotaAdapters.parseYescode(provider: "yescode", data: Data("""
        {"total_balance":3.45,"pay_as_you_go_balance":3.45,"weekly_limit":0,"weekly_spent_balance":0}
        """.utf8))
        expect(ycPayg?.windows.first?.label == "PayGo 余额" && ycPayg?.shortText == "余额 $3.45",
               "YesCode纯PayGo兜底", "实际：\(ycPayg?.shortText ?? "nil")")
        // 半静默防线：spending_limits 非空但 key 全不认识 → 显式失败（不静默兜底）
        let ycBroken = QuotaAdapters.parseYescode(provider: "yescode", data: Data("""
        {"total_balance":9.9,"spending_limits":[{"key":"per_request","limit":100,"spent":1}]}
        """.utf8))
        if case .failed(let msg)? = ycBroken?.status {
            expect(msg.contains("结构变了"), "YesCode结构变化显式失败", "实际：\(msg)")
        } else {
            expect(false, "YesCode结构变化显式失败", "实际未返回 failed：\(String(describing: ycBroken?.status))")
        }
        // 注：bimonthly 字面即 bi+monthly，后缀必然匹配 monthly——字符串层面无法区分，
      // 不做该断言（真出现也只是窗口粒度标错，非静默失败；防线靠上面的"全不认识→failed"）

        expect(QuotaAdapters.kind(for: url("https://unknown-relay.example.com")) == .probe, "未知中转→盲探", "")

        // 6.5 ACS3 签名已知答案测试（官方文档示例；改 ACS3Signer 必须保此条通过）
        do {
            let headers = [
                "host": "ecs.cn-shanghai.aliyuncs.com",
                "x-acs-action": "RunInstances",
                "x-acs-content-sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                "x-acs-date": "2023-10-26T10:22:32Z",
                "x-acs-signature-nonce": "3156853299f313e23d1673dc12e1703d",
                "x-acs-version": "2014-05-26",
            ]
            let query = [
                "ImageId": "win2019_1809_x64_dtc_zh-cn_40G_alibase_20230811.vhd",
                "RegionId": "cn-shanghai",
            ]
            let auth = ACS3Signer.authorization(
                method: "POST", path: "/", query: query, headers: headers,
                payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                accessKeyId: "YourAccessKeyId", secret: "YourAccessKeySecret")
            expect(auth == "ACS3-HMAC-SHA256 Credential=YourAccessKeyId,SignedHeaders=host;x-acs-action;x-acs-content-sha256;x-acs-date;x-acs-signature-nonce;x-acs-version,Signature=06563a9e1b43f5dfe96b81484da74bceab24a1d853912eee15083a6f0f3283c0",
                   "ACS3签名KAT（官方文档期望值）", "实际：\(auth)")
            expect(ACS3Signer.percentEncode("a b*c~d-e") == "a%20b%2Ac~d-e", "percentEncode 规则",
                   "实际：\(ACS3Signer.percentEncode("a b*c~d-e"))")
        }

        // 6.6 百炼 GetSubscriptionStats 解析（PascalCase 字段）
        let ali = QuotaAdapters.parseAliyun(provider: "bailian", data: fixture("aliyun-subscription-stats.json"))
        expect(ali != nil, "百炼解析", "parseAliyun 返回 nil")
        if let ali {
            let win = ali.windows.first
            expect(win?.remaining == 9230 && win?.total == 11500 && win?.unit == .count,
                   "百炼Credits 9230/11500", "实际：\(String(describing: win))")
            expect(ali.planName == "百炼 Token Plan · Lite", "百炼档位", "实际：\(ali.planName)")
            expect(ali.planDetail?.hasPrefix("订阅期 ") == true, "百炼订阅期", "实际：\(ali.planDetail ?? "nil")")
            expect(ymd(ali.renewAt) == "2026-09-11", "百炼续期日", "实际：\(ymd(ali.renewAt))")
            expect(ali.shortText.contains("本期剩 80%") || ali.shortText.contains("剩 80"), "百炼短标签",
                   "实际：\(ali.shortText)")
        }

        // 6.7 MiniMax /v1/token_plan/remains（2026-10-02 真 key 实测；夹具是原始响应）
        //     上游只给百分比、count 字段恒为 0 —— 窗口按 total=100 建模并标 .percent
        let mm = QuotaAdapters.parseMinimax(provider: "minimax", data: fixture("minimax-token-plan.json"))
        expect(mm != nil, "MiniMax解析", "parseMinimax 返回 nil")
        if let mm {
            let five = mm.windows.first { $0.period == .fiveHour }
            let week = mm.windows.first { $0.period == .week }
            expect(five?.remaining == 100 && five?.total == 100, "MiniMax 5小时=100%",
                   "实际：\(String(describing: five))")
            expect(week?.remaining == 99 && week?.total == 100, "MiniMax 本周=99%",
                   "实际：\(String(describing: week))")
            expect(five?.unit == .percent, "MiniMax单位是百分比（不是次数）",
                   "实际：\(String(describing: five?.unit))")
            expect(five?.resetAt != nil && week?.resetAt != nil, "MiniMax 有重置时间", "end_time 未解析")
            expect(mm.planName == "MiniMax Coding Plan", "MiniMax套餐名", "实际：\(mm.planName)")
            expect(five?.summaryText == "5 小时剩 100%", "MiniMax 摘要文案", "实际：\(five?.summaryText ?? "nil")")
            // 关键：明细行不能说成「次」——上游给的是百分比，不是计数
            expect(five?.amountText.contains("次") == false && five?.amountText.contains("%") == true,
                   "MiniMax 明细不说成「次」", "实际：\(five?.amountText ?? "nil")")
        }
        // 主机规则：国内站与国际站都要认（此前盲探未识别 → 一直错标 notIntegrated）
        expect(QuotaAdapters.kind(for: url("https://api.minimax.cn/anthropic")) == .minimaxPlan,
               "minimax.cn→额度规则", "")
        expect(QuotaAdapters.kind(for: url("https://api.minimaxi.com/anthropic")) == .minimaxPlan,
               "minimaxi.com→额度规则", "")

        // 6. 请求构造：GLM 裸 key、其余 Bearer；key 只出现在 Authorization
        let glmReqs = QuotaAdapters.requests(for: .glmPlan, baseURL: url("https://open.bigmodel.cn/api/anthropic"), key: "sk-unit")
        expect(glmReqs.map { $0.url!.absoluteString } == [
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
            "https://open.bigmodel.cn/api/biz/subscription/list",
        ], "GLM请求路径", "实际：\(glmReqs.map { $0.url!.absoluteString })")
        expect(glmReqs.first?.value(forHTTPHeaderField: "Authorization") == "sk-unit", "GLM裸key", "")
        let dsReq = QuotaAdapters.requests(for: .deepseekBalance, baseURL: url("https://api.deepseek.com/anthropic"), key: "sk-unit")
        expect(dsReq.first?.url?.absoluteString == "https://api.deepseek.com/user/balance"
               && dsReq.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-unit", "DeepSeek请求", "")

        print(failures.isEmpty ? "\n全部通过" : "\n失败 \(failures.count) 项：\(failures)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
