import Foundation

// ModelOnboardPolicy — 新模型自动上架的判定规则（纯函数、只依赖 Foundation，
// scripts/tests/test_model_onboard.sh 拿 2026-10-05 的真实上游目录脱离 App 单测）。
//
// 起因（2026-10-05）：yescode 的 Fable 5.1 一直能用却没人用上——网关里的模型清单是手抄的，
// 上游上新后没人对账；清单里没有的名字又会被网关静默转给别的线路并回 200（PITFALLS #43）。
//
// 总原则：**拿不准的一律不算候选**。宁可漏掉一个新模型，也不把日期变体、图像模型、
// 版本号有歧义的名字拿去花钱实测。

enum ModelOnboardPolicy {

    // MARK: - 模型名 → 骨架 + 版本

    struct Parsed: Equatable {
        /// 把版本那一处换成 "#" 后的词序列，如 ["claude","fable","#"]、["glm","#","flash"]、["k","#","256k"]
        let skeleton: [String]
        /// 版本各段。每一段保留原文（比较时要看位数），如 claude-opus-5-5 → ["5","5"]、qwen3.8 → ["3","8"]
        let version: [String]
        var skeletonText: String { skeleton.joined(separator: "-") }
    }

    enum Rejection: String, Equatable, Error {
        case nonChat = "不是对话模型（图像/语音/视频等）"
        case variant = "是预览/变体版本"
        case dated = "名字里带日期"
        case noVersion = "名字里没有版本号"
        case scatteredVersion = "版本号不在一处，认不准"
    }

    /// 整词匹配（不是子串）：避免把 "wan" 误伤到别的词。
    static let nonChatWords: Set<String> = [
        "image", "images", "imagine", "vision", "tts", "audio", "speech", "asr", "whisper",
        "video", "veo", "embed", "embedding", "embeddings", "rerank", "reranker", "ocr",
        "realtime", "moderation", "dall", "sora", "cogview", "cogvideo", "wan",
        "seedream", "seedance", "kling", "flux", "music",
    ]
    static let variantWords: Set<String> = [
        "preview", "exp", "experimental", "beta", "latest", "thinking", "reasoning",
    ]

    private enum Token: Equatable {
        case word(String)      // 纯字母
        case number(String)    // 纯数字，可带小数点：5、5.3、20251001
        case literal(String)   // 数字开头又带字母：256k、480b、1024x1536——是规格不是版本
    }

    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"[0-9]+(?:\.[0-9]+)*[a-z][a-z0-9.]*|[0-9]+(?:\.[0-9]+)*|[a-z]+"#)

    private static func tokens(_ model: String) -> [Token] {
        var name = model.lowercased()
        // [1M] 这类上下文后缀不是模型名的一部分（与 ModelCatalogFetcher.normalize 同口径）
        if let range = name.range(of: #"\[[0-9]+m\]$"#, options: .regularExpression) {
            name = String(name[..<range.lowerBound])
        }
        let nsRange = NSRange(name.startIndex..., in: name)
        return tokenRegex.matches(in: name, range: nsRange).compactMap { match -> Token? in
            guard let range = Range(match.range, in: name) else { return nil }
            let text = String(name[range])
            guard let first = text.first else { return nil }
            if first.isLetter { return .word(text) }
            return text.allSatisfy({ $0.isNumber || $0 == "." }) ? .number(text) : .literal(text)
        }
    }

    /// enforceDateRule 只给单测做反向验证用（关掉后日期变体必须冒出来成为候选）。
    static func parse(_ model: String, enforceDateRule: Bool = true) -> Result<Parsed, Rejection> {
        let toks = tokens(model)
        for case .word(let word) in toks {
            if nonChatWords.contains(word) { return .failure(.nonChat) }
        }
        for case .word(let word) in toks {
            if variantWords.contains(word) { return .failure(.variant) }
        }
        if enforceDateRule {
            for case .number(let text) in toks where text.split(separator: ".").contains(where: { $0.count >= 4 }) {
                return .failure(.dated)   // 20251001、0731、0309：四位及以上的纯数字段一律当日期
            }
        }
        // 版本 = 连在一起的数字词（claude-opus-5-5 的 5、5）。数字词分散在两处 → 认不准哪处是版本。
        var runs: [Range<Int>] = []
        var index = 0
        while index < toks.count {
            if case .number = toks[index] {
                let start = index
                while index < toks.count, case .number = toks[index] { index += 1 }
                runs.append(start..<index)
            } else {
                index += 1
            }
        }
        guard let run = runs.first else { return .failure(.noVersion) }
        guard runs.count == 1 else { return .failure(.scatteredVersion) }
        var skeleton: [String] = []
        var version: [String] = []
        for (position, token) in toks.enumerated() {
            switch token {
            case .word(let text), .literal(let text):
                skeleton.append(text)
            case .number(let text):
                if position == run.lowerBound { skeleton.append("#") }
                version.append(contentsOf: text.split(separator: ".").map(String.init))
            }
        }
        return .success(Parsed(skeleton: skeleton, version: version))
    }

    // MARK: - 版本比较

    enum VersionOrder: Equatable { case newer, same, older, ambiguous }

    /// candidate 相对 base。逐段按整数比，短的补 0（所以 5 < 5-1：fable-5 → fable-5-1 就是当天的事故）。
    /// 第一处不同若在次版本段、且两边位数不同（4.20 对 4.7）→ 「20 > 7」和「4.2 < 4.7」两种读法打架，判 ambiguous。
    /// 主版本段位数不同（9 对 10）没有歧义，照整数比。
    static func compare(_ candidate: [String], to base: [String], enforceConflictRule: Bool = true) -> VersionOrder {
        for position in 0..<max(candidate.count, base.count) {
            let left = position < candidate.count ? candidate[position] : "0"
            let right = position < base.count ? base[position] : "0"
            guard let a = Int(left), let b = Int(right) else { return .ambiguous }
            if a == b { continue }
            if enforceConflictRule, position > 0,
               position < candidate.count, position < base.count, left.count != right.count {
                return .ambiguous
            }
            return a > b ? .newer : .older
        }
        return .same
    }

    // MARK: - 候选

    struct Skipped: Equatable {
        let model: String
        let reason: String
    }

    struct Discovery: Equatable {
        /// 值得实测的候选：每个系列至多一个（该系列里最新的那个）
        let candidates: [String]
        /// 上游目录里有、清单里没有、但不算候选的，每个都带原因（给人看，也给单测断言）
        let skipped: [Skipped]
    }

    /// listed = 网关清单里该线路现有的模型；catalog = 上游目录。
    /// 候选条件：目录里有、清单里没有、同系列（骨架逐词相同）已在清单里、版本**明确**高于清单里同系列最高版。
    /// 清单里没有的新系列永不自动加（跨系列要人来定）。
    static func discover(listed: [String], catalog: [String],
                         enforceDateRule: Bool = true, enforceConflictRule: Bool = true) -> Discovery {
        // 清单里每个系列的已有版本。清单里认不准的名字（如带日期的 claude-haiku-4-5-20251001）不当锚点。
        var listedVersions: [String: [[String]]] = [:]
        for model in listed {
            if case .success(let parsed) = parse(model, enforceDateRule: enforceDateRule) {
                listedVersions[parsed.skeletonText, default: []].append(parsed.version)
            }
        }
        let listedSet = Set(listed.map { $0.lowercased() })
        var skipped: [Skipped] = []
        var newerBySkeleton: [String: [(model: String, version: [String])]] = [:]
        var seen = Set<String>()
        for model in catalog {
            let key = model.lowercased()
            guard !listedSet.contains(key), seen.insert(key).inserted else { continue }
            let parsed: Parsed
            switch parse(model, enforceDateRule: enforceDateRule) {
            case .failure(let rejection):
                skipped.append(Skipped(model: model, reason: rejection.rawValue))
                continue
            case .success(let value):
                parsed = value
            }
            guard let bases = listedVersions[parsed.skeletonText] else {
                skipped.append(Skipped(model: model, reason: "清单里没有这个系列（跨系列不自动加）"))
                continue
            }
            let orders = bases.map { compare(parsed.version, to: $0, enforceConflictRule: enforceConflictRule) }
            if orders.contains(.ambiguous) {
                skipped.append(Skipped(model: model, reason: "版本号有两种读法，认不准新旧"))
            } else if orders.allSatisfy({ $0 == .newer }) {
                newerBySkeleton[parsed.skeletonText, default: []].append((model, parsed.version))
            } else {
                skipped.append(Skipped(model: model, reason: "不比清单里的同系列新"))
            }
        }
        var candidates: [String] = []
        for (_, group) in newerBySkeleton {
            // 同系列多个更新的：只取最新的那个；它们之间比不出来就整组放弃
            var best = group[0]
            var unclear = false
            for item in group.dropFirst() {
                switch compare(item.version, to: best.version, enforceConflictRule: enforceConflictRule) {
                case .newer: best = item
                case .ambiguous: unclear = true
                case .same, .older: break
                }
            }
            for item in group where unclear || item.model != best.model {
                skipped.append(Skipped(model: item.model,
                                       reason: unclear ? "版本号有两种读法，认不准新旧" : "同系列有更新的候选（\(best.model)）"))
            }
            if !unclear { candidates.append(best.model) }
        }
        return Discovery(candidates: candidates.sorted(), skipped: skipped.sorted { $0.model < $1.model })
    }

    // MARK: - 账本判定（只用于「写进清单之后，经网关走一遍确认路由」那一步）

    struct LedgerRow: Equatable {
        let model: String          // 请求的模型名（账本里本来就不带线路前缀）
        let logicalModel: String   // 实际路由："线路/模型"
        let status: Int
    }

    enum ProbeVerdict: String, Equatable {
        case pass       // 本线路该模型真返回了 200
        case hardFail   // 本线路该模型被明确拒绝（400/401/403/404）
        case unsure     // 被转去了别的线路、5xx/429、或者根本没对上这次请求
    }

    /// rows = 实测时间窗内的账本行。只认 logicalModel 精确等于「线路/模型」的行；
    /// 「有行就算过」是错的——被网关转走的请求也是 200（PITFALLS #43）。
    static func verdict(rows: [LedgerRow], provider: String, model: String) -> ProbeVerdict {
        let route = provider + "/" + model
        let mine = rows.filter { $0.logicalModel == route }
        if mine.contains(where: { $0.status == 200 }) { return .pass }
        if mine.contains(where: { [400, 401, 403, 404].contains($0.status) }) { return .hardFail }
        return .unsure
    }

    /// 账本 created_at 的写法（如 2026-10-05T09:48:44.196Z）。时间窗用字符串比较，格式必须逐字符一致。
    static func ledgerTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // MARK: - 直连实测的判定（主判据：真实 Claude Code 客户端直连上游，读它的 --output-format json）
    //
    // 为什么直连而不是「先加进网关清单再测」：往网关写配置会重启网关的转发进程，同一秒在跑的会话会吃到 502；
    // 直连上游测，没通过的候选就完全不用碰网关。

    struct DirectOutput: Equatable {
        let localError: String?   // 本机问题（找不到 claude、临时目录建不了…）——不是模型的问题
        let exitCode: Int?
        let timedOut: Bool
        let stdout: String
    }

    enum DirectVerdict: Equatable {
        case pass
        case rejected(status: Int, detail: String)   // 上游明确拒绝：400/401/403/404
        case unsure(String)                          // 5xx/429/超时/输出读不懂
        case localFault(String)                      // 本机故障：整轮中止，不记到模型头上
    }

    static let rejectStatuses: Set<Int> = [400, 401, 403, 404]

    /// 「通过」= 退出码 0 且 is_error 明确 false，且 result 去空白非空，且 usage.output_tokens > 0。
    /// 「退出码 0 就算过」是错的：输出读不懂时不知道到底发生了什么；「只看 is_error」也是错的：进程异常退出时不可信；
    /// 「is_error=false 但 result 空 / 没有 usage」也是错的：中转站可能回 200 空内容或错误页，拿不准就当拿不准。
    /// 后四个参数只给单测做反向验证用（关掉一个条件，对应断言必须红）。
    static func directVerdict(_ output: DirectOutput, model: String,
                              requireExitZero: Bool = true, requireIsErrorFalse: Bool = true,
                              requireResultNonEmpty: Bool = true, requireTokensPositive: Bool = true) -> DirectVerdict {
        if let localError = output.localError, !localError.isEmpty { return .localFault(localError) }
        if output.timedOut { return .unsure("超时没有结果") }
        guard let object = parseJSONObject(output.stdout) else {
            return .unsure("输出读不懂（退出码 \(output.exitCode.map(String.init) ?? "未知")）")
        }
        let text = (object["result"] as? String) ?? ""
        let status = (object["api_error_status"] as? Int) ?? (object["api_error_status"] as? NSNumber)?.intValue
        let cleanResult = (object["is_error"] as? Bool) == false
        let resultNonEmpty = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let outputTokens = (object["usage"] as? [String: Any])?["output_tokens"] as? NSNumber
        let tokensPositive = (outputTokens?.intValue ?? 0) > 0
        let passed = (cleanResult || !requireIsErrorFalse)
            && (output.exitCode == 0 || !requireExitZero)
            && (resultNonEmpty || !requireResultNonEmpty)
            && (tokensPositive || !requireTokensPositive)
        if passed { return .pass }
        if let status, rejectStatuses.contains(status) {
            // 401 是线路层面的（key 没放行这个模型、或线路本身坏了），不记到模型头上做退避（P2-1）
            if status == 401 {
                return .unsure("线路层面被拒（401）：这条线路的 key 没放行此模型或线路本身有问题，本线路本轮不再试")
            }
            // 400 只有错误文案点名了这个模型（或出现 model 字样）才算「这个模型被拒」，否则拿不准（P2-1）
            if status == 400 {
                let lower = text.lowercased()
                if (model.isEmpty ? false : lower.contains(model.lowercased())) || lower.contains("model") {
                    return .rejected(status: status, detail: String(text.prefix(300)))
                }
                return .unsure("上游返回 400，但看不出是针对这个模型")
            }
            return .rejected(status: status, detail: String(text.prefix(status == 403 && text.contains("Allowed models") ? 800 : 300)))
        }
        if let status { return .unsure("上游返回 \(status)") }
        return .unsure("没有通过，也没有明确的拒绝（退出码 \(output.exitCode.map(String.init) ?? "未知")）")
    }

    /// claude -p --output-format json 的输出是一个 JSON 对象；前面万一夹了别的行，就取最后一个能解析成对象的行。
    private static func parseJSONObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return object }
        for line in trimmed.split(separator: "\n").reversed() {
            if let data = String(line).data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return object }
        }
        return nil
    }

    // MARK: - 每个候选的状态（防重复花钱）

    enum EntryState: String, Codable {
        case rejected      // 上游明确拒绝，过一阵再试
        case unsure        // 拿不准，可以再试
        case approved      // 直连实测通过，等写进清单（干跑、或当天写入次数用完时会停在这里）
        case unconfirmed   // 已写进清单，但经网关走一遍还没确认到路由；下一轮只重验，不回滚
        case writing       // 写入意图已落盘（计数已加），等回读确认是否真在清单里
        case listed        // 已上架并确认
        case removed       // 上架后又从清单里消失：当作用户有意删除，不再自动加回
    }

    struct Entry: Codable, Equatable {
        var state: EntryState
        var hardFails: Int = 0
        var unsures: Int = 0
        var lastTriedAt: Double = 0
        var nextRetryAt: Double = 0
        var lastStatus: Int?
        var note: String?
    }

    struct State: Codable, Equatable {
        var schemaVersion: Int = 1
        var entries: [String: Entry] = [:]   // 键 = "线路/模型"
        var writes: [Double] = []            // 往网关写配置的时刻（每天有上限）
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", entries, writes
        }
    }

    static func key(_ provider: String, _ model: String) -> String { provider + "/" + model }

    /// 确定拒绝后多久再试：前两次 7 天，连续第 3 次起 30 天。
    static func retryDelayAfterHardFail(consecutiveFailures: Int) -> TimeInterval {
        (consecutiveFailures >= 3 ? 30 : 7) * 86_400
    }

    /// 拿不准后多久再试：下一轮就可以（0），连续第 3 次起歇 24 小时。
    static func retryDelayAfterUnsure(consecutiveUnsure: Int) -> TimeInterval {
        consecutiveUnsure >= 3 ? 86_400 : 0
    }

    /// 直连实测后的新状态。localFault 不该走到这里（整轮中止，不动任何状态）。
    static func afterProbe(previous: Entry?, verdict: DirectVerdict, now: Double) -> Entry? {
        switch verdict {
        case .pass:
            return Entry(state: .approved, lastTriedAt: now, nextRetryAt: 0, lastStatus: 200, note: nil)
        case .rejected(let status, let detail):
            let fails = (previous?.state == .rejected ? previous?.hardFails ?? 0 : 0) + 1
            return Entry(state: .rejected, hardFails: fails, lastTriedAt: now,
                         nextRetryAt: now + retryDelayAfterHardFail(consecutiveFailures: fails),
                         lastStatus: status, note: detail.isEmpty ? nil : detail)
        case .unsure(let why):
            let count = (previous?.state == .unsure ? previous?.unsures ?? 0 : 0) + 1
            return Entry(state: .unsure, unsures: count, lastTriedAt: now,
                         nextRetryAt: now + retryDelayAfterUnsure(consecutiveUnsure: count),
                         lastStatus: nil, note: why)
        case .localFault:
            return previous
        }
    }

    /// 直连通过的结论只在 24 小时内有效：超过了要重测再写（上游可能已经变了）。
    static let approvalLifetime: TimeInterval = 86_400

    /// 这个候选现在要不要花一次请求去直连实测。
    static func shouldProbe(_ entry: Entry?, now: Double) -> Bool {
        guard let entry else { return true }
        switch entry.state {
        case .rejected, .unsure: return now >= entry.nextRetryAt
        case .approved: return now - entry.lastTriedAt > approvalLifetime
        case .unconfirmed, .writing, .listed, .removed: return false
        }
    }

    /// 上架过（listed/unconfirmed/writing）的模型和当前清单对账：
    /// - 不在清单里了 → 记成 removed，以后不再自动加回（writing 也算「上架过」：下一轮发现 writing 的模型不在清单 → removed）；
    /// - writing 且回读在清单里 → 说明上次的写其实落盘了，前进到 unconfirmed 等确认路由。
    static func reconcileRemoved(_ state: State, listed: [String: [String]]) -> State {
        var next = state
        for (key, entry) in state.entries {
            switch entry.state {
            case .listed, .unconfirmed, .writing:
                let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2, let models = listed[parts[0]] else { continue }   // 线路整条不在了：不动
                if models.contains(parts[1]) {
                    if entry.state == .writing {
                        next.entries[key]?.state = .unconfirmed
                        next.entries[key]?.note = nil
                    }
                } else {
                    next.entries[key]?.state = .removed
                    next.entries[key]?.note = "上架后又从清单里消失，当作有意删除，不再自动加回"
                }
            default:
                break
            }
        }
        return next
    }

    struct Candidate: Equatable {
        let provider: String
        let model: String
    }

    static let maxProbesPerRound = 2

    /// 这一轮实测谁：每条线路至多 1 个、全局至多 2 个；近 7 天账本里没有任何 200 的线路整条跳过（没余额或坏了，不花钱）。
    /// aliveProviders = nil 表示账本读不了：不知道哪条线路活着，就一个都不测。
    static func pick(_ candidates: [Candidate], state: State, aliveProviders: Set<String>?, now: Double,
                     limit: Int = maxProbesPerRound) -> (picked: [Candidate], skipped: [(Candidate, String)]) {
        var picked: [Candidate] = []
        var skipped: [(Candidate, String)] = []
        var usedProviders = Set<String>()
        for candidate in candidates {
            let entry = state.entries[key(candidate.provider, candidate.model)]
            guard let aliveProviders else { skipped.append((candidate, "读不了账本，不知道线路是否还活着，这轮不测")); continue }
            if !aliveProviders.contains(candidate.provider) {
                skipped.append((candidate, "这条线路近 7 天没有任何成功请求，不花钱测"))
            } else if !shouldProbe(entry, now: now) {
                skipped.append((candidate, skipReason(entry, now: now)))
            } else if usedProviders.contains(candidate.provider) {
                skipped.append((candidate, "这条线路本轮已经测过一个，下一轮再测"))
            } else if picked.count >= limit {
                skipped.append((candidate, "本轮已经测满 \(limit) 个，下一轮再测"))
            } else {
                picked.append(candidate)
                usedProviders.insert(candidate.provider)
            }
        }
        return (picked, skipped)
    }

    private static func skipReason(_ entry: Entry?, now: Double) -> String {
        guard let entry else { return "" }
        switch entry.state {
        case .rejected:
            return "上次被上游拒绝（\(entry.lastStatus.map(String.init) ?? "?")），\(daysText(entry.nextRetryAt - now))后再试"
        case .unsure: return "连续几次没测出结果，\(daysText(entry.nextRetryAt - now))后再试"
        case .approved: return "直连已通过，等写进清单"
        case .unconfirmed: return "已写进清单，等确认路由"
        case .writing: return "已提交写入，等回读确认"
        case .listed: return "已上架"
        case .removed: return "上架后被删掉过，不再自动加回"
        }
    }

    static func daysText(_ seconds: Double) -> String {
        seconds >= 86_400 ? "\(Int((seconds / 86_400).rounded(.up))) 天" : "\(max(1, Int((seconds / 3600).rounded(.up)))) 小时"
    }

    // MARK: - 写网关（每天有上限；一轮只写一次）

    static let maxWritesPerDay = 2

    static func writeAllowed(_ state: State, now: Double) -> Bool {
        state.writes.filter { now - $0 < 86_400 }.count < maxWritesPerDay
    }

    /// 把通过的候选**一次性**并进同一份配置：只给对应线路的 models 追加，已经在的跳过，别的字段一个不动。
    /// 返回新配置和真正追加了的项；没有可追加的 → added 为空（调用方不该写）。
    static func applyAdditions(config: [String: Any], approved: [Candidate]) -> (config: [String: Any], added: [Candidate]) {
        guard var providers = config["Providers"] as? [[String: Any]] else { return (config, []) }
        var added: [Candidate] = []
        for candidate in approved {
            guard let index = providers.firstIndex(where: { ($0["name"] as? String) == candidate.provider }),
                  var models = providers[index]["models"] as? [String],
                  !models.contains(candidate.model) else { continue }
            models.append(candidate.model)
            providers[index]["models"] = models
            added.append(candidate)
        }
        guard !added.isEmpty else { return (config, []) }
        var next = config
        next["Providers"] = providers
        return (next, added)
    }

    // MARK: - 通知

    struct Added: Equatable {
        let lineName: String          // 给人看的线路名
        let model: String
        let mainFrom: String?         // 自动选型的线路主模型会从哪个换成哪个；不变则两者皆 nil
        let mainTo: String?
    }

    /// 自动选型的线路：加之前、加之后各算一次「会选谁当主模型」，不一样就得明说。
    static func mainModelChange(before: [String], after: [String],
                                suggest: ([String]) -> String?) -> (from: String, to: String)? {
        guard let old = suggest(before), let new = suggest(after), old != new else { return nil }
        return (old, new)
    }

    /// 只在「直连通过 + 已写入并回读确认在清单里」之后调用；一轮合并成一条。
    static func notification(_ added: [Added]) -> (title: String, body: String)? {
        guard !added.isEmpty else { return nil }
        let title = added.count == 1
            ? "\(added[0].lineName) 上架了新模型 \(added[0].model)"
            : "上架了 \(added.count) 个新模型"
        var lines: [String] = []
        if added.count > 1 { lines.append(added.map { "\($0.lineName) \($0.model)" }.joined(separator: "、")) }
        lines.append("已用真实 Claude Code 直连实测通过，并加进了网关清单。正在跑的会话不受影响。")
        for item in added {
            if let from = item.mainFrom, let to = item.mainTo {
                lines.append("\(item.lineName) 新开的窗口主模型会从 \(from) 换成 \(to)。")
            }
        }
        return (title, lines.joined(separator: "\n"))
    }
}

// 状态文件读写（只依赖 Foundation，单测直接断言权限）。里面只有模型名和状态，没有密钥；仍按约定 600。
enum ModelOnboardStateStore {
    static let defaultPath = NSString(string: "~/.claude/ccpod-model-onboard.json").expandingTildeInPath

    /// 文件不存在 → 空状态。文件在但读不懂 → nil（调用方必须停手：把读不懂当成空会把退避记录全忘掉，然后重复花钱）。
    static func load(path: String = defaultPath) -> ModelOnboardPolicy.State? {
        guard FileManager.default.fileExists(atPath: path) else { return ModelOnboardPolicy.State() }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(ModelOnboardPolicy.State.self, from: data)
    }

    static func save(_ state: ModelOnboardPolicy.State, path: String = defaultPath) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        // .atomic 会按 umask 建成 644，必须显式收紧（PITFALLS #18）
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
