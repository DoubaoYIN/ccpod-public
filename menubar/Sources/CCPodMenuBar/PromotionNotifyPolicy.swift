import Foundation

/// 优惠雷达的提醒策略。**全部是纯函数**：无 IO、无单例、不隐式取当前时间
/// （`now` 一律由调用方传入），所以能脱离 App 用 swiftc 秒级单测。
///
/// 三条硬约束（spec §0.2 / §0.3）：
/// 1. **只提醒**。不改线路、不改 settings、不碰 CCR。文案里不许出现「已切换」这类话。
/// 2. **分级**。A 类 `peakValley` 且 `verified` 才可弹通知；B 类 `limitedTime` 永不弹，
///    只进面板 + ⚠️/❓。用户原始需求「qwen 夜间优惠」正属 B 类：第三方转述、资格受限，
///    弹通知会让人白跑一趟。
/// 3. **失败可见**。抓不到 / 读不出必须显示出来，不能和「今天没优惠」长得一样。
enum PromotionNotifyPolicy {

    /// 同一条情报 24 小时内不重复弹。
    static let minRealertGap: TimeInterval = 24 * 60 * 60

    /// 通知正文上限。超了会被系统截断，用户看到的是半句话。
    static let maxBodyChars = 300

    /// popover 摘要行最多列几条明细，多的折叠成「等 N 条」。
    static let maxListedLines = 3

    // MARK: 分级门禁

    /// 能不能弹系统通知。这是整个功能的「守门员」，放宽它等于开始替第三方站背书。
    ///
    /// 四个条件对应 spec §5.2 的四条必要条件。第 2 条（`class == peak_valley`）在这里查，
    /// 第 1、4 条由 Python 侧算进 `verified`，第 3 条（`extractor` 是规则）在这里**再查一遍**。
    static func isAlertable(_ p: Promotion) -> Bool {
        guard p.kind == .peakValley else { return false }   // B 类永不弹，与 verified 无关
        guard p.verified else { return false }              // 依据必须是官方页逐字原文
        // ⚠️ P0 下这条**恒真**（只有规则提取器；promo-fetch.py 的 extractor 唯一构造点
        // 是 `"rule:%s" % rule_id`，2026-10-10 当场 grep 取证），但它防的不是 P0，
        // 是「生产方说谎」：`verified` 来自磁盘上的 JSON，任何进程都能写，P2 的模型
        // 兜底落地后一个 bug 就能让 `extractor: "model:…"` 的条目带着 `verified: true`
        // 进来。到那天，这一行是唯一挡住「模型编的摘录被当成官方原文弹通知」的东西。
        // `extractor == nil`（旧文件 / 字段缺失）一律按不可信处理。
        guard let ex = p.extractor, ex.hasPrefix("rule:") else { return false }
        return p.status == .active || p.status == .upcoming
    }

    // MARK: 通知去重

    static func shouldQueueAlert(id: String, lastAlertedAt: Date?, now: Date) -> Bool {
        guard let last = lastAlertedAt else { return true }
        let gap = now.timeIntervalSince(last)
        // gap < 0 = lastAlertedAt 在未来（用户改了时区/时钟）。这种情况必须放行，
        // 否则「等够 24 小时」永远等不到，通知会永久哑掉——而且是静默哑掉。
        if gap < 0 { return true }
        return gap >= minRealertGap
    }

    // MARK: 页级失败

    /// 抓不到（网络/HTTP 层）与读不出（抓到了但没解析出情报）分开数。
    /// 修法完全不同：前者查 URL 和反爬，后者改正则。
    static func problemCounts(pages: [PromotionPage]) -> (unreachable: Int, unreadable: Int) {
        var unreachable = 0
        var unreadable = 0
        for p in pages {
            switch p.status {
            case .ok: break
            case .fetchFailed: unreachable += 1
            case .unsupportedJSPage, .parseFailed: unreadable += 1
            }
        }
        return (unreachable, unreadable)
    }

    static func problemText(unreachable: Int, unreadable: Int) -> String? {
        if unreachable == 0 && unreadable == 0 { return nil }
        if unreadable == 0 { return "⚠️ \(unreachable) 页抓不到" }
        if unreachable == 0 { return "⚠️ \(unreadable) 页读不出" }
        return "⚠️ \(unreachable + unreadable) 页有问题"
    }

    // MARK: 倒计时

    /// 把 "22:00" 拆成 (22, 0)。畸形串返回 nil。
    private static func parseHHMM(_ s: String) -> (hour: Int, minute: Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// 距离闲时窗口还有多久 / 窗口内还剩多久。
    ///
    /// `endsNextDay` 是这里唯一容易错的地方：22:00–次日 08:00，
    /// 凌晨 3 点必须算「进行中，还剩 5 小时」，不是「21 小时后开始」。
    /// 时区未知或时间串畸形一律返回 nil——不编时间，让调用方降级成不显示倒计时。
    ///
    /// `compact: true` 是 popover 那一行用的短版，**只说时长、不说钟点**：
    /// 一行放不下「闲时 22:00 开始，30 分钟后」，而更关键的是那个 `22:00` 是
    /// **页面声明时区**的钟点，脱离上下文单说一个「22:00」对不在那个时区的人就是个错钟点。
    /// 时长没有这个歧义（时长与时区无关）。面板行用长版，因为同一张卡片里
    /// 紧跟着就有 `22:00–次日 08:00（Asia/Shanghai）` 把时区标出来了。
    static func countdownText(window: PromotionWindow, now: Date,
                              compact: Bool = false) -> String? {
        guard let tz = TimeZone(identifier: window.tz) else { return nil }
        guard let start = parseHHMM(window.start) else { return nil }
        guard let end = parseHHMM(window.end) else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        func dateAt(dayOffsetFromNow offset: Int, hour: Int, minute: Int) -> Date? {
            guard let base = cal.date(byAdding: .day, value: offset, to: now) else { return nil }
            var c = cal.dateComponents([.year, .month, .day], from: base)
            c.hour = hour
            c.minute = minute
            c.second = 0
            c.timeZone = tz
            return cal.date(from: c)
        }

        // 找「当前或最近一次」窗口起点：今天的起点若还没到，就用昨天的。
        let todayStart = dateAt(dayOffsetFromNow: 0, hour: start.hour, minute: start.minute)
        guard let ts = todayStart else { return nil }
        let currentStart = ts <= now ? ts
            : (dateAt(dayOffsetFromNow: -1, hour: start.hour, minute: start.minute) ?? ts)
        let nextStart = ts > now ? ts
            : (dateAt(dayOffsetFromNow: 1, hour: start.hour, minute: start.minute) ?? ts.addingTimeInterval(86400))

        func endOfWindow(from ws: Date) -> Date? {
            let dayOffset = window.endsNextDay ? 1 : 0
            guard let base = cal.date(byAdding: .day, value: dayOffset, to: ws) else { return nil }
            var c = cal.dateComponents([.year, .month, .day], from: base)
            c.hour = end.hour
            c.minute = end.minute
            c.second = 0
            c.timeZone = tz
            return cal.date(from: c)
        }

        if let currentEnd = endOfWindow(from: currentStart), now < currentEnd {
            let left = durationText(currentEnd.timeIntervalSince(now))
            return compact ? "进行中，还剩 \(left)" : "闲时进行中，还剩 \(left)"
        }
        let wait = durationText(nextStart.timeIntervalSince(now))
        if compact { return "\(wait)后开始" }
        return "闲时 \(window.start) 开始，\(wait)后"
    }

    /// 不足 1 小时说分钟，否则说小时（向下取整：宁可说「3 小时后」也不要「4 小时后」让人白等）。
    static func durationText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total < 3600 {
            let minutes = max(1, total / 60)   // 0 分钟说成「1 分钟内」比说「0 分钟」有用
            return "\(minutes) 分钟"
        }
        return "\(total / 3600) 小时"
    }

    // MARK: popover 摘要行

    /// 菜单栏 popover 里那一行。返回 nil = 不显示这一行（用户还没配任何优惠页时不该占地方）。
    ///
    /// 前缀是分级信号，不要混用：
    ///   🌙 = 已核实的分时段优惠（可以照着做）
    ///   ❓ = 未核实的活动（自己去看，别当真）
    ///   ⚠️ = 有页抓不到/读不出（情报可能不全）
    ///   🔕 = 系统通知权限被关（提醒功能实际是哑的）
    static func popoverLine(promotions: [Promotion], pages: [PromotionPage],
                            notifyBlocked: Bool, now: Date) -> String? {
        let live = promotions.filter { $0.status != .expired }
        let alertable = live.filter { isAlertable($0) }
        let unverified = live.filter { !isAlertable($0) }
        let counts = problemCounts(pages: pages)
        let problem = problemText(unreachable: counts.unreachable, unreadable: counts.unreadable)

        var head: String?
        if alertable.count == 1, let p = alertable.first {
            let short = p.discount?.short ?? "有优惠"
            // 用 compact 版。早先这里写成对长版做 `replacingOccurrences(of: "闲时 ", …)`，
            // 那是错的：长版的「进行中」分支是 `闲时进行中`（**没有空格**），替换压根不命中，
            // popover 会印出「🌙 闲时 5 折 · 闲时进行中，还剩 9 小时」这种叠词。
            // 与其用字符串手术凑短版，不如让函数直接给出短版。
            if let w = p.window, let cd = countdownText(window: w, now: now, compact: true) {
                head = "🌙 \(short) · \(cd)"
            } else {
                head = "🌙 \(short)"
            }
        } else if alertable.count > 1 {
            head = "🌙 \(alertable.count) 条优惠生效中"
        } else if !unverified.isEmpty {
            head = "❓ \(unverified.count) 条未核实活动（面板可见）"
        }

        var parts: [String] = []
        if let h = head { parts.append(h) }
        if let pr = problem { parts.append(pr) }
        if notifyBlocked { parts.append("🔕 通知已关") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    // MARK: 每日汇总

    /// 每天 21:30 发一条。返回 nil = 今天不发（没情报也没问题时天天发「今天没优惠」是噪音，
    /// 会让人直接把通知关掉——那比不发更糟）。
    static func summary(promotions: [Promotion], pages: [PromotionPage],
                        now: Date) -> (title: String, body: String)? {
        let live = promotions.filter { $0.status != .expired }
        let alertable = live.filter { isAlertable($0) }
        let unverified = live.filter { !isAlertable($0) }
        let counts = problemCounts(pages: pages)
        let problem = problemText(unreachable: counts.unreachable, unreadable: counts.unreadable)

        if alertable.isEmpty && unverified.isEmpty && problem == nil { return nil }

        var lines: [String] = []

        if !alertable.isEmpty {
            lines.append("已核实 \(alertable.count) 条：")
            for p in Array(alertable.prefix(maxListedLines)) {
                var line = "· \(p.title)"
                // compact：标题里已经带了窗口和时区（`…（22:00–次日 08:00 北京时间）`），
                // 后面再跟一句「闲时 22:00 开始」就是把同一件事说两遍，还白占通知的字符预算。
                if let w = p.window, let cd = countdownText(window: w, now: now, compact: true) {
                    line += "（\(cd)）"
                }
                lines.append(line)
            }
            if alertable.count > maxListedLines {
                lines.append("· 等 \(alertable.count) 条，面板可见")
            }
        }

        if !unverified.isEmpty {
            // 计划 :3215 原文是 `unverified.isEmpty ? 0 : unverified.count`——本分支在
            // `if !unverified.isEmpty` 里面，isEmpty 恒 false，三元表达式是死代码，已简化。
            lines.append("未核实 \(unverified.count) 条（只列不提醒）：")
            for p in Array(unverified.prefix(maxListedLines)) {
                lines.append("· \(p.title)")
            }
            if unverified.count > maxListedLines {
                lines.append("· 等 \(unverified.count) 条，面板可见")
            }
        }

        if problem != nil {
            lines.append(problem!)
            // 失败要点名到线路并带上判据（HTTP 状态码 / 可见字符数），
            // 否则用户只看到「1 页抓不到」，不知道该改 URL 还是该等网络。
            for p in pages where p.status != .ok {
                var detail = "· \(p.line.isEmpty ? p.url : p.line)："
                switch p.status {
                case .fetchFailed:
                    detail += "抓不到"
                    if let code = p.httpStatus { detail += "（HTTP \(code)）" }
                    if let e = p.error, !e.isEmpty { detail += " \(e)" }
                case .unsupportedJSPage:
                    detail += "读不出，正文仅 \(p.visibleChars) 字符（疑似 JS 渲染页）"
                case .parseFailed:
                    detail += "读不出，正文 \(p.visibleChars) 字符"
                    if let n = p.note { detail += "（\(n)）" }
                case .ok:
                    continue
                }
                lines.append(detail)
            }
        }

        var body = lines.joined(separator: "\n")
        if body.count > maxBodyChars {
            // 截断要说清总条数，否则用户以为只有列出来的那几条。
            body = String(body.prefix(maxBodyChars - 20))
                + "\n…共 \(live.count) 条，面板看全"
        }
        return ("🌙 闲时优惠日报", body)
    }

    // MARK: 新活动插队

    /// 发现新的可弹情报时立刻发一条（不等 21:30）。返回 nil = 不该插队。
    static func interruptAlert(for p: Promotion, now: Date) -> (title: String, body: String)? {
        guard isAlertable(p) else { return nil }
        let short = p.discount?.short ?? "有优惠"
        var lines: [String] = [p.title]
        // compact：同上，标题已带窗口与时区，正文只补「还有多久」。
        if let w = p.window, let cd = countdownText(window: w, now: now, compact: true) {
            lines.append(cd)
        }
        if let e = p.eligibility, !e.isEmpty {
            lines.append(e)
        }
        // 给来源域名，让人能自己去核。verified 的语义是「官方页面确实这么写」，
        // 不代表实际计费一定如此——所以必须留下可核查的路径。
        if let host = URL(string: p.source.url)?.host {
            lines.append("来源：\(host)")
        }
        var body = lines.joined(separator: "\n")
        if body.count > maxBodyChars {
            body = String(body.prefix(maxBodyChars - 12)) + "\n…面板看全"
        }
        return ("🌙 新优惠：\(short)", body)
    }
}

/// 什么时候该抓、什么时候该发汇总。**纯函数**，`now` 与 `calendar` 都由调用方传入，
/// 所以能用假时钟把跨日、刚过点、已跑过、时钟回拨四种情况全测一遍。
enum PromotionSchedule {

    /// 每天 21:00 抓、21:30 汇总（spec §7）。
    /// 抓在汇总之前半小时：留给公网请求和重试的时间，别让汇总读到上一天的数据。
    static let fetchHour = 21
    static let fetchMinute = 0
    static let summaryHour = 21
    static let summaryMinute = 30

    /// `lastRunAt` 是 ISO 串（如 `2026-10-10T21:00:05+08:00`），前 10 位就是本地日期。
    /// 判定规则：
    ///   - 今天的 `hour:minute` 还没到 → false
    ///   - 到了，且今天已经跑过 → false（否则每分钟的 Timer 会反复打公网）
    ///   - 到了，且今天没跑过 → true（**含开机时已过点的情况**：菜单栏 App 常常
    ///     在 21:00 那一刻根本没活着，不补跑就等于这个功能大多数日子不工作）
    /// `lastRunAt` 解析不出来时按「没跑过」处理 —— 宁可多跑一次，也不能因为一个
    /// 坏字符串让功能永久静默。
    static func due(lastRunAt: String?, now: Date, hour: Int, minute: Int,
                    calendar: Calendar) -> Bool {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard let target = calendar.date(from: comps) else { return false }
        guard now >= target else { return false }
        let today = dayString(of: now, calendar: calendar)
        if let last = lastRunAt, dayString(iso: last) == today { return false }
        return true
    }

    /// `2026-10-10T21:00:05+08:00` → `2026-10-10`。坏串返回 nil。
    static func dayString(iso: String) -> String? {
        let trimmed = iso.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let head = String(trimmed.prefix(10))
        // 只认 YYYY-MM-DD 形状，别的当坏串
        let parts = head.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isNumber } }) else { return nil }
        return head
    }

    static func dayString(of date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 从线路配置构建 manifest。**只收 http/https**：
    /// `file://` 会让 `/etc/passwd` 之类的本地文件内容被当成「优惠情报」显示到面板上，
    /// 那是把本地信息搬到 UI 里，不是这个功能该做的事。
    /// 同一 URL 被多条线路配置时**每条线路都出一个条目**——Python 侧只对抓取去重，
    /// 页记录仍按线路各出一份。
    static func buildManifest(lines: [String: [String: Any]],
                              state: PromotionState) -> [[String: String]] {
        lines.keys.sorted().compactMap { id -> [String: String]? in
            guard let raw = lines[id]?["promo_url"] as? String else { return nil }
            let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, let parsed = URL(string: url) else { return nil }
            guard let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            guard parsed.host != nil, !(parsed.host ?? "").isEmpty else { return nil }
            // 查端指纹键走 storageKey(fromRaw:)：键 = sha256(redact(url))，与存端
            // storageKey(fromDecoded:) 同键（见 PromotionURLContract 契约注释）。
            // 直接用原始 url 作键是禁止拼法——键里可能有 key 原文，且与存端永久不同键。
            return ["line": id,
                    "url": url,
                    "previous_fingerprint": state.fingerprints[PromotionURLContract.storageKey(fromRaw: url)] ?? ""]
        }
    }
}

// MARK: - 页级失败的大白话

/// 把 `PromotionPageStatus` 翻成用户能读懂的话。
///
/// 为什么单独一层：四个枚举值直接印上去就是 `fetch-failed` 这种给程序员看的串，
/// 而用户偏好写得很明白——UI 措辞别像报错码。
/// 又因为这四句话是「面板为什么空着」的唯一解释（失败可见性不变量），
/// 说错一个字用户就以为功能坏了，所以走 swiftc 通道钉死，不靠肉眼。
enum PromotionPageCopy {

    static func label(_ status: PromotionPageStatus) -> String {
        switch status {
        case .ok: return "✅ 读到了"
        case .fetchFailed: return "⚠️ 抓不到"
        case .unsupportedJSPage: return "⚠️ 这页要 JavaScript"
        case .parseFailed: return "⚠️ 读不出优惠"
        }
    }

    /// 一句话解释 + 证据。证据（状态码 / 可见字符数 / error / note）必须在话里，
    /// 否则「抓不到」和「读不出」在用户看来是一回事。
    static func explanation(_ page: PromotionPage) -> String {
        switch page.status {
        case .ok:
            return page.unchanged ? "内容和上次一样，没有新变化。" : "已抓到并解析。"
        case .fetchFailed:
            if let s = page.httpStatus {
                // 状态码本身对用户没意义，修法才有意义：403 和 404 要做的事完全不同。
                let hint: String
                switch s {
                case 401, 403: hint = "常见是这页需要登录，或挡了自动访问。"
                case 404: hint = "这个网址上没东西——大概是填错了，或厂商把页面挪走了。"
                case 429: hint = "被限流了。ccpod 一天只抓一次，通常是对方的全局限流，明天多半自己好。"
                case 500...599: hint = "对方服务器出错了，跟你这边没关系，下次抓取通常就好。"
                default: hint = ""
                }
                return "对方回了 HTTP \(s)。\(hint)"
            }
            if let e = page.error, !e.isEmpty { return "网络层就没通。原文：\(e)" }
            return "网络层就没通，脚本也没给出原因。"
        case .unsupportedJSPage:
            return "整页只有 \(page.visibleChars) 个可见字符——正文是 JavaScript 渲染出来的。"
                 + "ccpod 不跑浏览器（只做无头 HTTP 抓取，见 docs/SECURITY.md），所以读不到这一页。"
        case .parseFailed:
            let note = (page.note?.isEmpty == false) ? page.note! : "这一页的写法还没人教过 ccpod。"
            return "页是抓到了的（\(page.visibleChars) 个可见字符），但没有一条规则匹配上。原因：\(note)"
        }
    }
}
