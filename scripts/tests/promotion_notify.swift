import Foundation

// 优惠雷达 Task 6 测试主体：提醒策略纯函数层（分级门禁 / 去重 / 倒计时 / 文案）。
// 通道与 promotion_store.swift 相同（swiftc 独立编译，无 XCTest）。
//
// 🔴 与计划正文的两个形态偏离（都是照抄必失败，当场实证过）：
// 1. 计划 :2714-2778 的测试代码是**顶层表达式**形态。裸 swiftc 多文件编译下，
//    非 main.swift 文件的顶层表达式直接编译失败，实测错误原文：
//    `error: expressions are not allowed at the top level`（2026-10-10 /tmp
//    两文件最小复现；同一份代码改名 main.swift 后 rc=0）。文件名按计划必须叫
//    promotion_notify.swift → 只能改成 @main struct 形态（Task 5 同款）。
// 2. 计划的 check() 不计数、末尾不打印 CHECKS=。但 .local/count-swift-checks.py
//    的判据要求「源码 check( 调用数 == 运行时自报 CHECKS=」，且本 Task 的验收
//    口径（运行时 == 静态合计 + 47，差值来自第 9 节双层 for 的 1 个静态调用点
//    × 48 次运行时）依赖这个自报 → 照 Task 5 在 check 里累加，退出前打印。
//
// 🔴 第 9 节（文案红线）的检出力**依赖**前面各节：它用 `s1?.body ?? ""` 构造
// 文案数组，某个值为 nil 时那一项是空串，而 `!"".contains(禁词)` 恒真 → 48 条
// 全部空转通过。前面各节有断言钉住这些值非 nil（§6 l1/l5/l6/l7、§7 s1/s2/s3、
// §8 i1），但那是依赖关系不是自证 → 本节开头加了一条观测前提断言兜底。

@main struct PromotionNotifyTests {

    static var failures = 0
    static var checkCount = 0

    static func check(_ cond: Bool, _ msg: String) {
        checkCount += 1
        if cond { print("  ✅ \(msg)") } else { print("  ❌ \(msg)"); failures += 1 }
    }

    /// 固定在 Asia/Shanghai 的某个时刻，让倒计时可断言。
    static func shanghai(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    static let realWindow = PromotionWindow(tz: "Asia/Shanghai", start: "22:00", end: "08:00",
                                            days: ["mon","tue","wed","thu","fri","sat","sun"],
                                            endsNextDay: true)

    /// 2026-10-10 实测抓取结果的 Swift 形态。
    static func realPromo(status: PromotionStatus = .active,
                          kind: PromotionKind = .peakValley,
                          verified: Bool = true,
                          extractor: String? = "rule:bailian-peakvalley") -> Promotion {
        Promotion(id: "bailian-peakvalley-deepseek", line: "gw-bailian",
                  title: "阿里云百炼 DeepSeek 系列 闲时 5 折（22:00–次日 08:00 北京时间）",
                  vendor: "阿里云百炼",
                  models: ["deepseek-v4-flash-0731", "deepseek-v4-pro-0813", "deepseek-v4.1-flash"],
                  window: realWindow,
                  discount: PromotionDiscount(ratio: 0.5, text: "闲时约为忙时的 5 折", short: "闲时 5 折"),
                  eligibility: "无需报名，闲时时段调用自动按闲时价计费；具体单价与地域以官方页为准",
                  source: PromotionSource(url: "https://help.aliyun.com/zh/model-studio/billing-for-model-studio",
                                          fetchedAt: "2026-10-10T00:40:00+08:00", official: true),
                  evidence: ["忙时为北京时间 8:00 - 22:00，闲时为北京时间 22:00 - 次日 8:00。"],
                  extractor: extractor, verified: verified,
                  status: status, kind: kind, validFrom: "2026-08-17", validUntil: nil)
    }

    // 107606 / 1964692 = 阿里计费页整页的实测值（visible_text **反转义后**口径 / 源页字节数）。
    // 这里只需要"一个远大于 500 阈值的真实数"，用实测值是为了让测试数据可追溯到某个真页。
    // 原写 109349（反转义前口径）已作废，语义见修正 15 与「三个数字」语义表
    // （.local/notes-281/plan-corrections.md，两处均已在落笔前核实存在）。
    static func okPage(line: String = "gw-bailian") -> PromotionPage {
        PromotionPage(line: line, url: "https://help.aliyun.com/x", status: .ok, httpStatus: 200,
                      bytes: 1964692, visibleChars: 107606, fingerprint: "sha256:a",
                      error: nil, note: nil, truncated: false, unchanged: false)
    }
    static func page(_ status: PromotionPageStatus, line: String, err: String? = nil,
                     note: String? = nil, chars: Int = 0, http: Int? = nil) -> PromotionPage {
        PromotionPage(line: line, url: "https://\(line).example/p", status: status,
                      httpStatus: http, bytes: 0, visibleChars: chars, fingerprint: nil,
                      error: err, note: note, truncated: false, unchanged: false)
    }

    static func main() {

        print("== 1. 分级门禁：谁能弹通知（spec §0.2 的硬约束）==")
        check(PromotionNotifyPolicy.isAlertable(realPromo()), "A 类 + verified + active → 可弹")
        check(PromotionNotifyPolicy.isAlertable(realPromo(status: .upcoming)), "A 类 + verified + upcoming → 可弹（新活动插队）")
        check(!PromotionNotifyPolicy.isAlertable(realPromo(status: .expired)), "已过期的不弹")
        check(!PromotionNotifyPolicy.isAlertable(realPromo(verified: false)),
              "🔴 未核实的不弹。verified=false 意味着依据不是官方页原文，弹出去就是替第三方站背书")
        check(!PromotionNotifyPolicy.isAlertable(realPromo(kind: .limitedTime)),
              "🔴 B 类限时活动**永不**弹通知 —— 用户原始需求「qwen 夜间优惠」正属此类，" +
              "第三方转述 + 资格受限，弹通知会让人白跑一趟")
        check(!PromotionNotifyPolicy.isAlertable(realPromo(kind: .limitedTime, verified: true)),
              "🔴 B 类即使 verified=true 也不弹。分级看的是 class，不是可信度")
        // 下面两条防的是「生产方说谎」：verified 来自磁盘 JSON，任何进程都能写。
        // P0 下这两条走不到（没有模型提取器），但 P2 模型兜底落地那天，
        // 它们是唯一挡住「模型编的摘录被当成官方原文弹通知」的东西。
        check(!PromotionNotifyPolicy.isAlertable(realPromo(extractor: "model:gpt-5")),
              "🔴 模型提取的条目即使 verified=true 也不弹（spec §5.2 第 3 条）")
        check(!PromotionNotifyPolicy.isAlertable(realPromo(extractor: nil)),
              "🔴 extractor 缺失（旧文件/字段没了）按不可信处理，不弹")

        print("== 2. 24h 内同一条不重复弹 ==")
        let t0 = shanghai(2026, 10, 10, 21, 30)
        check(PromotionNotifyPolicy.shouldQueueAlert(id: "p", lastAlertedAt: nil, now: t0), "从没弹过 → 弹")
        check(!PromotionNotifyPolicy.shouldQueueAlert(id: "p", lastAlertedAt: t0.addingTimeInterval(-3600), now: t0), "1 小时前弹过 → 不弹")
        check(!PromotionNotifyPolicy.shouldQueueAlert(id: "p", lastAlertedAt: t0.addingTimeInterval(-23 * 3600), now: t0), "23 小时前弹过 → 不弹")
        check(PromotionNotifyPolicy.shouldQueueAlert(id: "p", lastAlertedAt: t0.addingTimeInterval(-24 * 3600), now: t0), "整 24 小时 → 弹（边界含）")
        check(PromotionNotifyPolicy.shouldQueueAlert(id: "p", lastAlertedAt: t0.addingTimeInterval(-999999), now: t0), "很久以前 → 弹")
        check(PromotionNotifyPolicy.minRealertGap == 24 * 60 * 60, "minRealertGap == 86400")
        // 时钟往回拨（用户改时区/夏令时）不能让通知永久哑掉
        check(PromotionNotifyPolicy.shouldQueueAlert(id: "p", lastAlertedAt: t0.addingTimeInterval(7200), now: t0),
              "lastAlertedAt 在未来（时钟回拨）→ 仍然弹，不能永久哑掉")

        print("== 3. 页级失败计数：抓不到 vs 读不出 ==")
        let (u0, r0) = PromotionNotifyPolicy.problemCounts(pages: [okPage()])
        check(u0 == 0 && r0 == 0, "全 ok → 0 / 0")
        let (u1, r1) = PromotionNotifyPolicy.problemCounts(pages: [
            page(.fetchFailed, line: "a", err: "HTTP 403 Forbidden", http: 403)])
        check(u1 == 1 && r1 == 0, "fetch-failed → 抓不到 1")
        let (u2, r2) = PromotionNotifyPolicy.problemCounts(pages: [
            page(.unsupportedJSPage, line: "a", chars: 55)])
        check(u2 == 0 && r2 == 1, "unsupported-js-page → 读不出 1")
        let (u3, r3) = PromotionNotifyPolicy.problemCounts(pages: [
            // 计划 :2788 原文把 chars 写在 note 前，与计划 :2741 自己的签名
            // （note 先于 chars）矛盾，Swift 要求按声明顺序 → 照抄必编译失败。
            page(.parseFailed, line: "a", note: "rule-matched-no-hit", chars: 107606)])
        check(u3 == 0 && r3 == 1, "parse-failed → 读不出 1")
        let (u4, r4) = PromotionNotifyPolicy.problemCounts(pages: [
            page(.fetchFailed, line: "a"), page(.unsupportedJSPage, line: "b", chars: 55),
            page(.parseFailed, line: "c", note: "no-rule-matched-url"), okPage(line: "d")])
        check(u4 == 1 && r4 == 2, "混合 → 抓不到 1 / 读不出 2")

        print("== 4. 问题文案：能具体就具体，混在一起才说「有问题」==")
        check(PromotionNotifyPolicy.problemText(unreachable: 0, unreadable: 0) == nil, "没问题 → nil")
        check(PromotionNotifyPolicy.problemText(unreachable: 1, unreadable: 0) == "⚠️ 1 页抓不到", "只抓不到 → 说「抓不到」")
        check(PromotionNotifyPolicy.problemText(unreachable: 0, unreadable: 1) == "⚠️ 1 页读不出", "只读不出 → 说「读不出」")
        check(PromotionNotifyPolicy.problemText(unreachable: 3, unreadable: 0) == "⚠️ 3 页抓不到", "多页抓不到")
        check(PromotionNotifyPolicy.problemText(unreachable: 1, unreadable: 1) == "⚠️ 2 页有问题", "两类都有 → 合并成「有问题」")

        print("== 5. 倒计时（跨午夜是这里最容易错的地方）==")
        // 21:30 —— 闲时还没开始，30 分钟后开始
        let c1 = PromotionNotifyPolicy.countdownText(window: realWindow, now: shanghai(2026,10,10,21,30))
        check(c1 == "闲时 22:00 开始，30 分钟后", "21:30 → 「闲时 22:00 开始，30 分钟后」（实际 \(c1 ?? "nil")）")
        // 23:00 —— 闲时进行中，到次日 08:00 还剩 9 小时
        let c2 = PromotionNotifyPolicy.countdownText(window: realWindow, now: shanghai(2026,10,10,23,0))
        check(c2 == "闲时进行中，还剩 9 小时", "23:00 → 进行中还剩 9 小时（实际 \(c2 ?? "nil")）")
        // 03:00 —— 仍在闲时（跨午夜！），还剩 5 小时
        let c3 = PromotionNotifyPolicy.countdownText(window: realWindow, now: shanghai(2026,10,11,3,0))
        check(c3 == "闲时进行中，还剩 5 小时", "🔴 次日 03:00 仍算进行中（跨午夜，实际 \(c3 ?? "nil")）")
        // 12:00 —— 忙时，下一次闲时 10 小时后开始
        let c4 = PromotionNotifyPolicy.countdownText(window: realWindow, now: shanghai(2026,10,10,12,0))
        check(c4 == "闲时 22:00 开始，10 小时后", "12:00 → 10 小时后（实际 \(c4 ?? "nil")）")
        // 08:00 整 —— 闲时刚结束，不算进行中
        let c5 = PromotionNotifyPolicy.countdownText(window: realWindow, now: shanghai(2026,10,10,8,0))
        check(c5 == "闲时 22:00 开始，14 小时后", "08:00 整 → 已结束，下一次 14 小时后（实际 \(c5 ?? "nil")）")
        // 22:00 整 —— 刚开始
        let c6 = PromotionNotifyPolicy.countdownText(window: realWindow, now: shanghai(2026,10,10,22,0))
        check(c6 == "闲时进行中，还剩 10 小时", "22:00 整 → 进行中（实际 \(c6 ?? "nil")）")
        // 不跨午夜的窗口也要对
        let dayWindow = PromotionWindow(tz: "Asia/Shanghai", start: "01:00", end: "05:00",
                                        days: ["mon","tue","wed","thu","fri","sat","sun"],
                                        endsNextDay: false)
        let c7 = PromotionNotifyPolicy.countdownText(window: dayWindow, now: shanghai(2026,10,10,2,0))
        check(c7 == "闲时进行中，还剩 3 小时", "不跨午夜窗口 02:00 → 还剩 3 小时（实际 \(c7 ?? "nil")）")
        // 未知时区不能崩，返回 nil 让调用方降级成不显示倒计时
        let badTZ = PromotionWindow(tz: "Mars/Olympus", start: "22:00", end: "08:00",
                                    days: ["mon"], endsNextDay: true)
        check(PromotionNotifyPolicy.countdownText(window: badTZ, now: t0) == nil, "未知时区 → nil（不崩、不编时间）")
        // 畸形时间串
        let badHM = PromotionWindow(tz: "Asia/Shanghai", start: "晚上十点", end: "08:00",
                                    days: ["mon"], endsNextDay: true)
        check(PromotionNotifyPolicy.countdownText(window: badHM, now: t0) == nil, "畸形时间串 → nil")

        print("== 6. popover 摘要行 ==")
        // 什么都没有（用户还没配任何优惠页）→ 不占地方
        check(PromotionNotifyPolicy.popoverLine(promotions: [], pages: [], notifyBlocked: false,
                                                now: shanghai(2026,10,10,21,30)) == nil,
              "没配页也没情报 → nil（不显示这一行）")
        // 有一条生效中的 A 类
        let l1 = PromotionNotifyPolicy.popoverLine(promotions: [realPromo()], pages: [okPage()],
                                                   notifyBlocked: false, now: shanghai(2026,10,10,21,30))
        check(l1 == "🌙 闲时 5 折 · 30 分钟后开始", "单条生效中（实际 \(l1 ?? "nil")）")
        // 闲时进行中
        let l2 = PromotionNotifyPolicy.popoverLine(promotions: [realPromo()], pages: [okPage()],
                                                   notifyBlocked: false, now: shanghai(2026,10,10,23,0))
        check(l2 == "🌙 闲时 5 折 · 进行中，还剩 9 小时", "进行中（实际 \(l2 ?? "nil")）")
        // 两条 → 不堆标题，给条数
        let l3 = PromotionNotifyPolicy.popoverLine(
            promotions: [realPromo(), realPromo(status: .upcoming)], pages: [okPage()],
            notifyBlocked: false, now: shanghai(2026,10,10,21,30))
        check(l3 == "🌙 2 条优惠生效中", "多条 → 报数（实际 \(l3 ?? "nil")）")
        // 只有问题没有情报 → 只显示问题
        let l4 = PromotionNotifyPolicy.popoverLine(
            promotions: [], pages: [page(.fetchFailed, line: "a", err: "HTTP 403 Forbidden", http: 403)],
            notifyBlocked: false, now: shanghai(2026,10,10,21,30))
        check(l4 == "⚠️ 1 页抓不到", "只有问题（实际 \(l4 ?? "nil")）")
        // 情报 + 问题同行
        let l5 = PromotionNotifyPolicy.popoverLine(
            promotions: [realPromo()],
            pages: [okPage(), page(.unsupportedJSPage, line: "b", chars: 55)],
            notifyBlocked: false, now: shanghai(2026,10,10,21,30))
        check(l5 == "🌙 闲时 5 折 · 30 分钟后开始 ⚠️ 1 页读不出", "情报 + 问题（实际 \(l5 ?? "nil")）")
        // 通知权限被系统关掉 → 必须说出来，否则用户以为没优惠
        let l6 = PromotionNotifyPolicy.popoverLine(promotions: [realPromo()], pages: [okPage()],
                                                   notifyBlocked: true, now: shanghai(2026,10,10,21,30))
        check(l6 == "🌙 闲时 5 折 · 30 分钟后开始 🔕 通知已关", "notifyBlocked（实际 \(l6 ?? "nil")）")
        // B 类不进 popover 主行（它不配 🌙 那个前缀，会和已核实的混为一谈）
        let l7 = PromotionNotifyPolicy.popoverLine(promotions: [realPromo(kind: .limitedTime)],
                                                   pages: [okPage()], notifyBlocked: false,
                                                   now: shanghai(2026,10,10,21,30))
        check(l7 == "❓ 1 条未核实活动（面板可见）", "B 类 → ❓ 且措辞说明未核实（实际 \(l7 ?? "nil")）")
        // 已过期的不显示
        check(PromotionNotifyPolicy.popoverLine(promotions: [realPromo(status: .expired)], pages: [okPage()],
                                                notifyBlocked: false, now: shanghai(2026,10,10,21,30)) == nil,
              "只剩过期情报 + 页全 ok → nil")

        print("== 7. 每日汇总 ==")
        let s1 = PromotionNotifyPolicy.summary(promotions: [realPromo()], pages: [okPage()],
                                               now: shanghai(2026,10,10,21,30))
        check(s1 != nil, "有情报 → 发汇总")
        check(s1?.title == "🌙 闲时优惠日报", "汇总标题（实际 \(s1?.title ?? "nil")）")
        let body1 = s1?.body ?? ""
        check(body1.contains("阿里云百炼 DeepSeek 系列 闲时 5 折"), "汇总正文含标题")
        check(body1.contains("30 分钟后开始"), "汇总正文含倒计时")
        check(body1.contains("已核实"), "汇总正文明说这条是已核实的")
        // 什么都没有 → 不发。天天发一条「今天没优惠」是噪音，会让人关掉通知。
        check(PromotionNotifyPolicy.summary(promotions: [], pages: [okPage()],
                                            now: shanghai(2026,10,10,21,30)) == nil,
              "无情报无问题 → 不发汇总")
        check(PromotionNotifyPolicy.summary(promotions: [], pages: [],
                                            now: shanghai(2026,10,10,21,30)) == nil,
              "什么都没配 → 不发汇总")
        // 只有问题也要发：静默失败正是这个功能要消灭的东西
        let s2 = PromotionNotifyPolicy.summary(
            promotions: [], pages: [page(.fetchFailed, line: "gw-a", err: "HTTP 403 Forbidden", http: 403)],
            now: shanghai(2026,10,10,21,30))
        check(s2 != nil, "只有页失败 → 仍然发汇总（否则用户以为一切正常）")
        check((s2?.body ?? "").contains("gw-a"), "失败正文点名是哪条线路")
        check((s2?.body ?? "").contains("403"), "失败正文带 HTTP 状态码（spec §8.2 要求）")
        // B 类进汇总但明确标注未核实、且不弹插队通知
        let s3 = PromotionNotifyPolicy.summary(promotions: [realPromo(kind: .limitedTime, verified: false)],
                                               pages: [okPage()], now: shanghai(2026,10,10,21,30))
        check(s3 != nil, "只有 B 类 → 也发汇总（用户就是为这个来的）")
        let body3 = s3?.body ?? ""
        check(body3.contains("未核实"), "B 类在汇总里必须标「未核实」")
        check(!body3.contains("已核实"), "B 类不能被标成已核实")
        // 正文长度要有上限，否则通知被系统截断，用户看到的是半句话
        let many = (1...40).map { i in
            var p = realPromo(); p = Promotion(
                id: "p\(i)", line: "l\(i)", title: String(repeating: "很长的标题", count: 12),
                vendor: "厂商", models: [], window: realWindow,
                discount: PromotionDiscount(ratio: 0.5, text: "闲时约为忙时的 5 折", short: "闲时 5 折"),
                eligibility: nil, source: p.source, evidence: [], extractor: nil,
                verified: true, status: .active, kind: .peakValley, validFrom: nil, validUntil: nil)
            return p
        }
        let s4 = PromotionNotifyPolicy.summary(promotions: many, pages: [okPage()],
                                               now: shanghai(2026,10,10,21,30))
        check((s4?.body ?? "").count <= PromotionNotifyPolicy.maxBodyChars,
              "40 条情报也不超长（实际 \((s4?.body ?? "").count) ≤ \(PromotionNotifyPolicy.maxBodyChars)）")
        check((s4?.body ?? "").contains("等 40 条") || (s4?.body ?? "").contains("共 40 条"),
              "被截断时要说清总条数，不能让人以为只有列出来的那几条")

        print("== 8. 新活动插队通知 ==")
        let i1 = PromotionNotifyPolicy.interruptAlert(for: realPromo(), now: shanghai(2026,10,10,21,30))
        check(i1?.title == "🌙 新优惠：闲时 5 折", "插队标题（实际 \(i1?.title ?? "nil")）")
        let ib1 = i1?.body ?? ""
        check(ib1.contains("阿里云百炼 DeepSeek 系列"), "插队正文含厂商与系列")
        check(ib1.contains("22:00"), "插队正文含窗口起点")
        check(ib1.contains("30 分钟后开始"), "插队正文含倒计时")
        check(ib1.contains("help.aliyun.com"), "插队正文含来源域（让人能自己去核）")
        check(PromotionNotifyPolicy.interruptAlert(for: realPromo(kind: .limitedTime),
                                                   now: shanghai(2026,10,10,21,30)) == nil,
              "🔴 B 类没有插队通知")
        check(PromotionNotifyPolicy.interruptAlert(for: realPromo(verified: false),
                                                   now: shanghai(2026,10,10,21,30)) == nil,
              "🔴 未核实没有插队通知")
        check(PromotionNotifyPolicy.interruptAlert(for: realPromo(status: .expired),
                                                   now: shanghai(2026,10,10,21,30)) == nil,
              "过期没有插队通知")

        print("== 9. 文案红线：不许出现「已为你切换」这类暗示自动改配置的话（spec §0.3 只提醒）==")
        let all = [
            s1?.body ?? "", s2?.body ?? "", s3?.body ?? "", i1?.body ?? "",
            l1 ?? "", l5 ?? "", l6 ?? "", l7 ?? "",
        ]
        // 观测前提（派单文档第八节 L7）：8 条文案必须都非空。某个为 nil 时对应项是
        // 空串，而 `!"".contains(禁词)` 恒真 → 下面 48 条全部空转通过。前面各节
        // （§6/§7/§8）有断言钉住这些值非 nil，但那是依赖关系不是自证，这里兜底。
        check(all.filter { !$0.isEmpty }.count == 8,
              "文案红线段的观测前提：8 条文案都非空（否则 !\"\".contains(禁词) 恒真、这 48 条全是空转）")
        for forbidden in ["已切换", "已为你", "已修改", "已启用", "自动切换", "已调整线路"] {
            for text in all {
                check(!text.contains(forbidden),
                      "文案不含「\(forbidden)」（这个功能只提醒，动配置是越界）")
            }
        }

        print("== 10. 调度判定：21:00 抓、21:30 汇总 ==")
        let cal: Calendar = { var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }()

        // 还没到点 → 不该跑
        check(!PromotionSchedule.due(lastRunAt: nil, now: shanghai(2026,10,10,20,59),
                                     hour: 21, minute: 0, calendar: cal), "20:59 → 不跑")
        // 刚过点 → 该跑
        check(PromotionSchedule.due(lastRunAt: nil, now: shanghai(2026,10,10,21,0),
                                    hour: 21, minute: 0, calendar: cal), "21:00 整 → 跑（边界含）")
        check(PromotionSchedule.due(lastRunAt: nil, now: shanghai(2026,10,10,21,1),
                                    hour: 21, minute: 0, calendar: cal), "21:01 → 跑")
        // 今天已经跑过 → 不重复
        check(!PromotionSchedule.due(lastRunAt: "2026-10-10T21:00:05+08:00",
                                     now: shanghai(2026,10,10,21,30), hour: 21, minute: 0, calendar: cal),
              "今天 21:00 跑过 → 不重复跑（否则一分钟内 Timer 会打几十次公网请求）")
        // 隔天 → 该跑
        check(PromotionSchedule.due(lastRunAt: "2026-10-09T21:00:05+08:00",
                                    now: shanghai(2026,10,10,21,30), hour: 21, minute: 0, calendar: cal),
              "昨天跑过、今天到点 → 跑")
        // 还没到今天的点（15:00），即便昨天跑过也不该现在跑——「补跑」只在已过点时发生
        check(!PromotionSchedule.due(lastRunAt: "2026-10-09T21:00:05+08:00",
                                     now: shanghai(2026,10,10,15,0), hour: 21, minute: 0, calendar: cal),
              "21:00 那个点还没到 → 15:00 不补跑")
        check(PromotionSchedule.due(lastRunAt: "2026-10-09T21:00:05+08:00",
                                    now: shanghai(2026,10,10,23,59), hour: 21, minute: 0, calendar: cal),
              "23:59 且今天没跑 → 补跑（菜单栏 App 常常整天没在 21:00 那一刻活着）")
        // 汇总必须在抓取之后：21:30 的判定用同一个函数，只是 hour/minute 不同
        check(PromotionSchedule.due(lastRunAt: nil, now: shanghai(2026,10,10,21,29),
                                    hour: 21, minute: 30, calendar: cal) == false, "21:29 → 汇总不发")
        check(PromotionSchedule.due(lastRunAt: nil, now: shanghai(2026,10,10,21,30),
                                    hour: 21, minute: 30, calendar: cal) == true, "21:30 → 汇总发")
        // lastRunAt 是坏字符串 → 当成没跑过，不能因为解析失败就永久不跑
        check(PromotionSchedule.due(lastRunAt: "不是日期", now: shanghai(2026,10,10,21,0),
                                    hour: 21, minute: 0, calendar: cal), "lastRunAt 坏掉 → 照常跑")
        // 时钟回拨到早上（用户改时区）→ 当天已跑过就不该再跑
        check(!PromotionSchedule.due(lastRunAt: "2026-10-10T21:00:05+08:00",
                                     now: shanghai(2026,10,10,9,0), hour: 21, minute: 0, calendar: cal),
              "时钟回拨到 09:00，但今天跑过 → 不跑")

        print("== 11. manifest 构建：按 (line,url) 出条目、指纹带过去、跳过没配 URL 的 ==")
        let lines: [String: [String: Any]] = [
            "gw-bailian": ["name": "百炼",
                           "promo_url": "https://help.aliyun.com/zh/model-studio/billing-for-model-studio"],
            "gw-volc": ["name": "火山"],                                   // 没配 → 不进 manifest
            "gw-empty": ["name": "空的", "promo_url": ""],                  // 空串 → 不进 manifest
            "gw-dup": ["name": "同页",
                       "promo_url": "https://help.aliyun.com/zh/model-studio/billing-for-model-studio"],
            "gw-bad": ["name": "填歪了", "promo_url": "不是 URL"],           // 非法 → 不进 manifest
        ]
        var st = PromotionState.empty
        // 测试用契约的 storageKey(fromRaw:) 作键：与 buildManifest 查端同键。
        // 直接用原始 url 作键是禁止拼法（PromotionURLContract 契约注释点名）。
        st.fingerprints[PromotionURLContract.storageKey(fromRaw: "https://help.aliyun.com/zh/model-studio/billing-for-model-studio")] = "sha256:old"
        let manifest = PromotionSchedule.buildManifest(lines: lines, state: st)
        // 5 条线路里只有 gw-bailian 和 gw-dup 配了合法 URL → manifest 正好 2 条。
        check(manifest.count == 2, "manifest 2 条（bailian + dup）；没配/空串/非法 URL 都被跳过（实际 \(manifest.count)）")
        check(manifest.allSatisfy { $0.keys.sorted() == ["line", "previous_fingerprint", "url"] },
              "每条正好 3 个键，多一个少一个 Python 侧都会出意外")
        check(manifest.compactMap { $0["line"] }.sorted() == ["gw-bailian", "gw-dup"],
              "⚠️ 同一个 URL 被两条线路配置时**两条都要进 manifest**：Python 侧只对抓取去重，" +
              "页记录仍按线路各出一份（实际 \(manifest.compactMap { $0["line"] }.sorted())）")
        check(manifest.allSatisfy { $0["previous_fingerprint"] == "sha256:old" },
              "已知指纹要带过去，Python 才能判 unchanged")
        let manifest2 = PromotionSchedule.buildManifest(lines: lines, state: .empty)
        check(manifest2.allSatisfy { $0["previous_fingerprint"] == "" },
              "没有旧指纹时给空串（Python 侧 bool(\"\") == False → unchanged=False）")
        // 顺序必须稳定：字典遍历顺序不定，manifest 抖动会让「页顺序变了」看起来像情报变了
        let orderA = PromotionSchedule.buildManifest(lines: lines, state: .empty).compactMap { $0["line"] }
        let orderB = PromotionSchedule.buildManifest(lines: lines, state: .empty).compactMap { $0["line"] }
        check(orderA == orderB && orderA == orderA.sorted(), "manifest 按 line id 排序，顺序稳定")
        // 非 http(s) 的 scheme 一律不收：file:// 会让本地文件内容被当成「优惠情报」显示出来
        let schemeLines: [String: [String: Any]] = [
            "a": ["promo_url": "file:///etc/passwd"],
            "b": ["promo_url": "ftp://x/y"],
            "c": ["promo_url": "https://ok/x"],
        ]
        check(PromotionSchedule.buildManifest(lines: schemeLines, state: .empty)
                .compactMap { $0["line"] } == ["c"],
              "🔴 只收 http/https。file:// 会把本地文件内容抓进情报面板")

        // 页级失败文案：这四句是「面板为什么空着」的唯一解释。
        // 失败可见性不变量要求每种「空」都有自己的名字 + 自己的证据，
        // 所以这里断言的不是「有句话」，而是「证据数字真的在那句话里」。
        check(PromotionPageCopy.label(.ok) == "✅ 读到了", "ok 态标签")
        check(PromotionPageCopy.label(.fetchFailed) == "⚠️ 抓不到", "fetchFailed 态标签")
        check(PromotionPageCopy.label(.unsupportedJSPage).contains("JavaScript"),
              "JS 页必须点名 JavaScript，否则用户以为是网坏了")
        check(PromotionPageCopy.label(.parseFailed) == "⚠️ 读不出优惠", "parseFailed 态标签")

        // 修正 38：计划 :4404-4409 的辅助函数漏了 truncated: —— PromotionPage 的
        // 成员初始化器 truncated 无默认值，照抄必 `missing argument for parameter
        // 'truncated' in call`。补 truncated: false。
        // 修正 39：计划把它命名为 page()，但本文件 :72 已有 static func page(...)
        // （第 3 节 problemCounts 用）。main() 体内的同名嵌套函数会遮蔽 struct 层的
        // page，让第 3 节的 page(.fetchFailed, line:err:http:) 全报
        // "extra arguments"（实测）。改名 copyPage 避开。
        func copyPage(_ status: PromotionPageStatus, httpStatus: Int? = nil, visibleChars: Int = 0,
                  error: String? = nil, note: String? = nil, unchanged: Bool = false) -> PromotionPage {
            PromotionPage(line: "gw-x", url: "https://example.com/pricing", status: status,
                          httpStatus: httpStatus, bytes: 0, visibleChars: visibleChars,
                          fingerprint: nil, error: error, note: note, truncated: false, unchanged: unchanged)
        }

        let jsCopy = PromotionPageCopy.explanation(copyPage(.unsupportedJSPage, httpStatus: 200, visibleChars: 120))
        check(jsCopy.contains("120"), "JS 页的解释里必须带上可见字符数——那是证据，不是装饰：\(jsCopy)")
        check(jsCopy.contains("不跑浏览器"), "必须说清 ccpod 不跑浏览器，这是能力边界不是 bug")

        check(PromotionPageCopy.explanation(copyPage(.fetchFailed, httpStatus: 403)).contains("403"),
              "HTTP 状态码必须露出来")
        // 状态码对用户没意义，修法才有意义：403 和 404 要做的事完全不同，话必须不一样
        check(PromotionPageCopy.explanation(copyPage(.fetchFailed, httpStatus: 403)).contains("登录"),
              "403 要提示可能需要登录/被反爬挡")
        check(PromotionPageCopy.explanation(copyPage(.fetchFailed, httpStatus: 404)).contains("填错"),
              "404 要提示大概是网址填错了")
        check(PromotionPageCopy.explanation(copyPage(.fetchFailed, httpStatus: 429)).contains("限流"), "429 提示限流")
        check(PromotionPageCopy.explanation(copyPage(.fetchFailed, httpStatus: 503)).contains("服务器出错"), "503 提示服务器出错")
        check(PromotionPageCopy.explanation(copyPage(.fetchFailed, httpStatus: 418)) == "对方回了 HTTP 418。",
              "没预料到的状态码就只报码，不要硬编一句可能错的话")
        let netCopy = PromotionPageCopy.explanation(copyPage(.fetchFailed, error: "timed out"))
        check(netCopy.contains("timed out"), "没有状态码时要退回 error 原文：\(netCopy)")
        let bareCopy = PromotionPageCopy.explanation(copyPage(.fetchFailed))
        check(bareCopy.contains("没给出原因"), "连 error 都没有时也要说清是脚本没给，不能变成空字符串")

        let parseCopy = PromotionPageCopy.explanation(
            copyPage(.parseFailed, httpStatus: 200, visibleChars: 4200, note: "no-rule-matched-url"))
        check(parseCopy.contains("4200"), "解析失败要说清「页是抓到了的」，可见字符数就是证据")
        check(parseCopy.contains("no-rule-matched-url"), "note 是四种空里区分彼此的关键，必须原文露出")

        check(PromotionPageCopy.explanation(copyPage(.ok)) == "已抓到并解析。", "ok 态解释")
        check(PromotionPageCopy.explanation(copyPage(.ok, unchanged: true)).contains("和上次一样"),
              "unchanged 必须说成「没变化」，不能说成「没优惠」")
        print("PASS: 页级失败文案（四态各有说法，证据数字都在话里）")

        print("")
        print("CHECKS=\(checkCount)")
        if failures == 0 { print("全部通过 ✅") } else { print("\(failures) 项失败 ❌"); exit(1) }
    }
}
