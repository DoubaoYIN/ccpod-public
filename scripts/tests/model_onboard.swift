import Foundation

// ModelOnboardPolicy 单测。夹具 = 2026-10-05 七条线路的真实「网关清单 + 上游目录」快照（只有模型名）。
// 用法：check <夹具路径>；环境变量 MODEL_ONBOARD_DISABLE=date|conflict 用来做反向验证（关掉一条规则，对应断言必须红）。

@main struct ModelOnboardTests {
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ label: String, _ what: String) {
        if condition {
            print("  ok   \(label)")
        } else {
            failures.append(label)
            print("  FAIL \(label) —— \(what)")
        }
    }

    static func main() {
        typealias P = ModelOnboardPolicy
        let disabled = ProcessInfo.processInfo.environment["MODEL_ONBOARD_DISABLE"] ?? ""
        let dateRule = disabled != "date", conflictRule = disabled != "conflict"
        if !disabled.isEmpty { print("  （反向验证：已关掉规则 \(disabled)）") }
        func discover(_ listed: [String], _ catalog: [String]) -> P.Discovery {
            P.discover(listed: listed, catalog: catalog, enforceDateRule: dateRule, enforceConflictRule: conflictRule)
        }

        // —— 读夹具（读不到就失败，不当通过）——
        guard CommandLine.arguments.count > 1,
              let data = FileManager.default.contents(atPath: CommandLine.arguments[1]),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let lines = root["lines"] as? [String: [String: Any]] else {
            print("  FAIL 读得到真实目录夹具 —— 用法：check <scripts/tests/fixtures/model_onboard_catalog_20261005.json>")
            exit(1)
        }
        func listed(_ line: String) -> [String] { lines[line]?["listed"] as? [String] ?? [] }
        func catalog(_ line: String) -> [String] { lines[line]?["catalog"] as? [String] ?? [] }
        expect(lines.count == 7 && lines.values.allSatisfy { !(($0["catalog"] as? [String]) ?? []).isEmpty },
               "夹具含 7 条线路且每条目录非空", "\(lines.keys.sorted())")

        // —— 当天的事故必须能抓到：yescode 用补清单之前的 4 个名字 ——
        let yesOld = discover(["claude-fable-5", "claude-opus-5-5", "claude-sonnet-5", "claude-haiku-4-5"], catalog("yescode"))
        expect(yesOld.candidates == ["claude-fable-5-1", "claude-sonnet-5-5"],
               "yescode 旧清单→候选恰为 [claude-fable-5-1, claude-sonnet-5-5]", "\(yesOld.candidates)")

        // —— 用当前清单 ——
        for (line, want) in [("aigocode", ["claude-sonnet-5-5"]), ("dragoncode", ["claude-sonnet-5-5"]),
                             ("kimi", []), ("glm", []), ("yescode", [])] {
            let got = discover(listed(line), catalog(line)).candidates
            expect(got == want, "\(line) 当前清单→候选恰为 \(want)", "\(got)")
        }
        let bailian = discover(listed("bailian"), catalog("bailian"))
        expect(!bailian.candidates.contains("deepseek-v4-flash-0731"), "bailian 候选不含 deepseek-v4-flash-0731", "\(bailian.candidates)")
        let grok = discover(listed("dragon-grok"), catalog("dragon-grok"))
        expect(!grok.candidates.contains(where: { $0.hasPrefix("grok-4.20") }), "dragon-grok 候选不含任何 grok-4.20*", "\(grok.candidates)")
        expect(grok.candidates.isEmpty, "dragon-grok 候选为空", "\(grok.candidates)")
        expect(bailian.candidates.isEmpty, "bailian 候选为空", "\(bailian.candidates)")

        // —— 每个被排除项都要说得出是哪条规则 ——
        func reason(_ d: P.Discovery, _ model: String) -> String { d.skipped.first { $0.model == model }?.reason ?? "（没有记录）" }
        let wantReasons: [(P.Discovery, String, String)] = [
            (bailian, "deepseek-v4-flash-0731", "名字里带日期"),
            (yesOld, "claude-haiku-4-5-20251001", "名字里带日期"),
            (bailian, "wan2.7-image", "不是对话模型（图像/语音/视频等）"),
            (bailian, "qwen-audio-3.0-tts-plus", "不是对话模型（图像/语音/视频等）"),
            (grok, "grok-imagine-video", "不是对话模型（图像/语音/视频等）"),
            (grok, "grok-4.20-0309-reasoning", "是预览/变体版本"),
            (grok, "grok-4.20-multi-agent-0309", "名字里带日期"),
            (grok, "grok-4.5", "不比清单里的同系列新"),
            (bailian, "auto", "名字里没有版本号"),
            (yesOld, "gpt-5.5", "清单里没有这个系列（跨系列不自动加）"),
            (yesOld, "claude-opus-5", "不比清单里的同系列新"),
        ]
        for (d, model, want) in wantReasons {
            expect(reason(d, model) == want, "\(model) 被排除的原因是「\(want)」", reason(d, model))
        }
        print("  —— 各线路被排除项与原因（当前清单）——")
        for line in lines.keys.sorted() {
            for s in discover(listed(line), catalog(line)).skipped { print("     \(line)  \(s.model)  ←  \(s.reason)") }
        }

        // —— 版本歧义：4.20 对 4.7 两种读法打架，不算候选 ——
        let ambiguous = discover(["grok-4.7"], ["grok-4.20"])
        expect(ambiguous.candidates.isEmpty, "清单 grok-4.7、目录 grok-4.20→不算候选", "\(ambiguous.candidates)")
        expect(reason(ambiguous, "grok-4.20") == "版本号有两种读法，认不准新旧", "grok-4.20 的排除原因是版本号歧义", reason(ambiguous, "grok-4.20"))
        expect(P.compare(["4", "20"], to: ["4", "7"], enforceConflictRule: conflictRule) == .ambiguous, "compare(4.20, 4.7)=ambiguous", "")
        expect(P.compare(["10"], to: ["9"]) == .newer, "主版本 10 对 9 没有歧义，是更新", "")
        expect(P.compare(["5", "1"], to: ["5"]) == .newer, "5-1 比 5 新（短的补 0）", "")
        expect(P.compare(["5"], to: ["5", "5"]) == .older, "5 比 5-5 旧", "")
        expect(P.compare(["5", "5"], to: ["5", "5"]) == .same, "5-5 与 5-5 相同", "")

        // —— 骨架 ——
        func skeleton(_ m: String) -> String {
            if case .success(let p) = P.parse(m) { return p.skeletonText + " @ " + p.version.joined(separator: ".") }
            return "排除"
        }
        expect(skeleton("claude-opus-5-5") == "claude-opus-# @ 5.5", "claude-opus-5-5 的骨架与版本", skeleton("claude-opus-5-5"))
        expect(skeleton("qwen3.8-max") == "qwen-#-max @ 3.8", "qwen3.8-max 的骨架与版本", skeleton("qwen3.8-max"))
        expect(skeleton("k3-256k") == "k-#-256k @ 3", "k3-256k：256k 是规格不是版本", skeleton("k3-256k"))
        expect(skeleton("glm-5.3-flash") != skeleton("glm-5.3"), "glm-5.3-flash 与 glm-5.3 不是同一系列", "")
        expect(skeleton("claude-opus-5-5[1M]") == "claude-opus-# @ 5.5", "[1M] 后缀不算进名字", skeleton("claude-opus-5-5[1M]"))
        let simple = discover(["claude-fable-5", "claude-opus-5-5"], ["claude-fable-5", "claude-fable-5-1", "claude-opus-5-5"])
        expect(simple.candidates == ["claude-fable-5-1"], "最小例子→候选恰为 [claude-fable-5-1]", "\(simple.candidates)")
        let two = discover(["glm-5.2"], ["glm-5.3", "glm-5.4"])
        expect(two.candidates == ["glm-5.4"], "同系列两个更新的→只取最新的 glm-5.4", "\(two.candidates)")
        expect(reason(two, "glm-5.3") == "同系列有更新的候选（glm-5.4）", "glm-5.3 让位给 glm-5.4", reason(two, "glm-5.3"))
        expect(discover(["glm-5.3"], ["GLM-5.3"]).candidates.isEmpty, "只是大小写不同→不算新模型", "")

        // —— 账本判定四态（第二期用）——
        func row(_ model: String, _ logical: String, _ status: Int) -> P.LedgerRow { P.LedgerRow(model: model, logicalModel: logical, status: status) }
        let m = "claude-sonnet-5-5"
        expect(P.verdict(rows: [row(m, "aigocode/\(m)", 200)], provider: "aigocode", model: m) == .pass, "账本：本线路该模型 200→通过", "")
        expect(P.verdict(rows: [row(m, "aigocode/\(m)", 403)], provider: "aigocode", model: m) == .hardFail, "账本：本线路该模型 403→确定失败", "")
        expect(P.verdict(rows: [row(m, "glm/glm-5.3", 200)], provider: "aigocode", model: m) == .unsure, "账本：被转去 glm 的 200→拿不准（不是通过）", "")
        expect(P.verdict(rows: [], provider: "aigocode", model: m) == .unsure, "账本：没有行→拿不准", "")
        expect(P.verdict(rows: [row(m, "aigocode/\(m)", 524)], provider: "aigocode", model: m) == .unsure, "账本：524→拿不准", "")
        expect(P.verdict(rows: [row(m, "yescode/\(m)", 200)], provider: "aigocode", model: m) == .unsure, "账本：别的线路同名模型 200→拿不准", "")
        expect(P.verdict(rows: [row(m, "aigocode/\(m)", 403), row(m, "aigocode/\(m)", 200)], provider: "aigocode", model: m) == .pass, "账本：同窗口有 403 也有 200→通过", "")

        // —— 直连实测判定：通过 = 退出码 0 + is_error=false + result 非空 + usage.output_tokens>0 ——
        // 真实形态（2026-10-05 实测）：通过 → rc=0、is_error=false、result "ok"、usage.output_tokens>0；
        // 被拒 → rc=1、is_error=true、api_error_status=403。缺 usage / 空 result 一律拿不准。
        let exitRule = disabled != "exitcode", errorRule = disabled != "iserror"
        let resultRule = disabled != "result", tokensRule = disabled != "tokens"
        func direct(_ rc: Int?, _ stdout: String, model: String = "claude-sonnet-5-5", timedOut: Bool = false, local: String? = nil) -> P.DirectVerdict {
            P.directVerdict(P.DirectOutput(localError: local, exitCode: rc, timedOut: timedOut, stdout: stdout), model: model,
                            requireExitZero: exitRule, requireIsErrorFalse: errorRule,
                            requireResultNonEmpty: resultRule, requireTokensPositive: tokensRule)
        }
        let okJSON = #"{"type":"result","subtype":"success","is_error":false,"result":"ok","duration_ms":21034,"usage":{"input_tokens":110,"output_tokens":4}}"#
        let emptyResultJSON = #"{"type":"result","is_error":false,"result":"","usage":{"output_tokens":4}}"#
        let noUsageJSON = #"{"type":"result","is_error":false,"result":"ok"}"#
        let deniedJSON = #"{"type":"result","is_error":true,"api_error_status":403,"result":"API Error: 403 model not allowed. Allowed models: claude-fable-5-1, claude-opus-5-5, claude-sonnet-5-5"}"#
        let isErrorJSON = #"{"type":"result","is_error":true,"result":"ok","usage":{"output_tokens":4}}"#
        expect(direct(0, okJSON) == .pass, "直连：rc=0 + is_error=false + result 非空 + tokens>0→通过", "\(direct(0, okJSON))")
        expect(direct(0, emptyResultJSON) != .pass, "直连：is_error=false 但 result 空→不算通过（中转站可能回空内容）", "\(direct(0, emptyResultJSON))")
        expect(direct(0, noUsageJSON) != .pass, "直连：is_error=false、result 非空 但缺 usage→拿不准（不算通过）", "\(direct(0, noUsageJSON))")
        if case .rejected(let status, let detail) = direct(1, deniedJSON) {
            expect(status == 403, "直连：rc=1、api_error_status=403→被上游拒绝（403）", "\(status)")
            expect(detail.contains("Allowed models: claude-fable-5-1, claude-opus-5-5, claude-sonnet-5-5"), "直连：403 带 Allowed models 时把上游给的白名单原文留下", detail)
        } else {
            expect(false, "直连：rc=1、api_error_status=403→被上游拒绝", "\(direct(1, deniedJSON))")
        }
        expect(direct(0, isErrorJSON) != .pass, "直连：退出码 0 但 is_error=true→不算通过（不能「rc=0 就过」）", "\(direct(0, isErrorJSON))")
        expect(direct(1, okJSON) != .pass, "直连：is_error=false 但退出码 1→不算通过（不能只看 is_error）", "\(direct(1, okJSON))")
        expect(direct(0, "Segmentation fault") == .unsure("输出读不懂（退出码 0）"), "直连：退出码 0 但输出不是 JSON→拿不准", "\(direct(0, "Segmentation fault"))")
        expect(direct(1, #"{"is_error":true,"api_error_status":503,"result":"upstream unavailable"}"#) == .unsure("上游返回 503"), "直连：503→拿不准", "")
        expect(direct(1, #"{"is_error":true,"api_error_status":429,"result":"rate limited"}"#) == .unsure("上游返回 429"), "直连：429→拿不准", "")
        expect(direct(nil, "", timedOut: true) == .unsure("超时没有结果"), "直连：超时→拿不准", "")
        expect(direct(1, #"{"is_error":true,"result":"Not logged in"}"#) == .unsure("没有通过，也没有明确的拒绝（退出码 1）"), "直连：失败但没有状态码→拿不准", "")
        expect(direct(nil, "", local: "找不到 claude 可执行文件") == .localFault("找不到 claude 可执行文件"), "直连：找不到 claude→本机故障（不记到模型头上）", "")
        expect(direct(0, "warming up\n" + okJSON) == .pass, "直连：JSON 前面夹了别的行也能读出来", "")
        // P2-1：401 是线路层面的，不记到模型头上；400 只有点名了模型才算拒绝
        expect(direct(1, #"{"is_error":true,"api_error_status":401,"result":"x"}"#) == .unsure("线路层面被拒（401）：这条线路的 key 没放行此模型或线路本身有问题，本线路本轮不再试"), "直连：401→线路层面拿不准（不进模型退避）", "\(direct(1, #"{"is_error":true,"api_error_status":401,"result":"x"}"#))")
        if case .rejected(let got, _) = direct(1, #"{"is_error":true,"api_error_status":400,"result":"model claude-sonnet-5-5 not found"}"#, model: "claude-sonnet-5-5") {
            expect(got == 400, "直连：400 文案点名了模型→被上游拒绝", "")
        } else { expect(false, "直连：400 文案点名了模型→被上游拒绝", "\(direct(1, #"{"is_error":true,"api_error_status":400,"result":"model claude-sonnet-5-5 not found"}"#, model: "claude-sonnet-5-5"))") }
        expect(direct(1, #"{"is_error":true,"api_error_status":400,"result":"bad request"}"#) == .unsure("上游返回 400，但看不出是针对这个模型"), "直连：400 文案没点名模型→拿不准", "")
        if case .rejected(let got, _) = direct(1, #"{"is_error":true,"api_error_status":404,"result":"x"}"#) {
            expect(got == 404, "直连：404→被上游拒绝", "")
        } else { expect(false, "直连：404→被上游拒绝", "\(direct(1, #"{"is_error":true,"api_error_status":404,"result":"x"}"#))") }

        // —— 状态流转与退避 ——
        let t0 = 1_000_000.0
        let r1 = P.afterProbe(previous: nil, verdict: .rejected(status: 403, detail: "no"), now: t0)!
        expect(r1.state == .rejected && r1.hardFails == 1 && r1.nextRetryAt == t0 + 7 * 86_400, "被拒 1 次→rejected，7 天后再试", "\(r1)")
        let r2 = P.afterProbe(previous: r1, verdict: .rejected(status: 403, detail: "no"), now: t0)!
        let r3 = P.afterProbe(previous: r2, verdict: .rejected(status: 403, detail: "no"), now: t0)!
        expect(r2.hardFails == 2 && r2.nextRetryAt == t0 + 7 * 86_400, "连续被拒 2 次→仍是 7 天", "\(r2)")
        expect(r3.hardFails == 3 && r3.nextRetryAt == t0 + 30 * 86_400, "连续被拒 3 次→30 天后再试", "\(r3)")
        let u1 = P.afterProbe(previous: r3, verdict: .unsure("上游返回 503"), now: t0)!
        expect(u1.state == .unsure && u1.unsures == 1 && u1.nextRetryAt == t0, "拿不准 1 次→下一轮可再试（且不沿用被拒次数）", "\(u1)")
        let u3 = P.afterProbe(previous: P.afterProbe(previous: u1, verdict: .unsure("x"), now: t0), verdict: .unsure("x"), now: t0)!
        expect(u3.unsures == 3 && u3.nextRetryAt == t0 + 86_400, "连续拿不准 3 次→歇 24 小时", "\(u3)")
        let passed = P.afterProbe(previous: r1, verdict: .pass, now: t0)!
        expect(passed.state == .approved && passed.hardFails == 0, "通过→approved（等写进清单），失败计数清零", "\(passed)")
        expect(P.afterProbe(previous: r1, verdict: .localFault("找不到 claude"), now: t0) == r1, "本机故障→状态原样不动", "")
        expect(P.shouldProbe(nil, now: t0), "没见过的候选→要测", "")
        expect(!P.shouldProbe(r1, now: t0 + 6 * 86_400), "被拒后第 6 天→不测", "")
        expect(P.shouldProbe(r1, now: t0 + 7 * 86_400), "被拒后第 7 天→可以再测", "")
        expect(!P.shouldProbe(passed, now: t0 + 3600), "直连通过 1 小时内→不重测（直接等写）", "")
        expect(P.shouldProbe(passed, now: t0 + 25 * 3600), "直连通过超过 24 小时还没写→要重测", "")
        for state in [P.EntryState.listed, .unconfirmed, .writing, .removed] {
            expect(!P.shouldProbe(P.Entry(state: state), now: t0 + 999 * 86_400), "\(state.rawValue)→永不再直连实测", "")
        }

        // —— 这一轮测谁 ——
        let cands = [P.Candidate(provider: "aigocode", model: "claude-sonnet-5-5"), P.Candidate(provider: "aigocode", model: "claude-opus-5-6"),
                     P.Candidate(provider: "dragoncode", model: "claude-sonnet-5-5"), P.Candidate(provider: "glm", model: "glm-5.4"),
                     P.Candidate(provider: "dead", model: "x-2")]
        let picked = P.pick(cands, state: P.State(), aliveProviders: ["aigocode", "dragoncode", "glm"], now: t0)
        expect(picked.picked == [cands[0], cands[2]], "5 个候选→每线路 1 个、全局 2 个：aigocode 与 dragoncode 的 sonnet-5-5", "\(picked.picked)")
        func why(_ c: P.Candidate) -> String { picked.skipped.first { $0.0 == c }?.1 ?? "（没有记录）" }
        expect(why(cands[1]) == "这条线路本轮已经测过一个，下一轮再测", "同线路第 2 个→下一轮", why(cands[1]))
        expect(why(cands[3]) == "本轮已经测满 2 个，下一轮再测", "第 3 条线路→本轮测满", why(cands[3]))
        expect(why(cands[4]) == "这条线路近 7 天没有任何成功请求，不花钱测", "死线路→不花钱", why(cands[4]))
        expect(P.pick(cands, state: P.State(), aliveProviders: nil, now: t0).picked.isEmpty, "账本读不了→一个都不测", "")
        var rejectedState = P.State()
        rejectedState.entries["aigocode/claude-sonnet-5-5"] = r1
        let afterReject = P.pick(cands, state: rejectedState, aliveProviders: ["aigocode", "dragoncode"], now: t0 + 86_400)
        expect(afterReject.picked == [cands[1], cands[2]], "被拒的候选在退避期内→跳过它，测同线路的下一个", "\(afterReject.picked)")
        expect(afterReject.skipped.first { $0.0 == cands[0] }?.1 == "上次被上游拒绝（403），6 天后再试", "退避期内的跳过原因写明还要等几天", afterReject.skipped.first { $0.0 == cands[0] }?.1 ?? "")

        // —— 写网关：一轮只写一次、每天有上限 ——
        let config: [String: Any] = ["PORT": 3456, "Providers": [
            ["name": "aigocode", "api_key": "k1", "models": ["claude-opus-5-5", "claude-sonnet-5"]],
            ["name": "dragoncode", "api_key": "k2", "models": ["claude-opus-5-5"]],
            ["name": "glm", "api_key": "k3", "models": ["glm-5.3"]]]]
        let merged = P.applyAdditions(config: config, approved: [cands[0], cands[2], P.Candidate(provider: "glm", model: "glm-5.3"),
                                                                 P.Candidate(provider: "nosuch", model: "m")])
        func models(_ c: [String: Any], _ name: String) -> [String] {
            ((c["Providers"] as? [[String: Any]])?.first { $0["name"] as? String == name }?["models"] as? [String]) ?? []
        }
        expect(merged.added == [cands[0], cands[2]], "两个通过→同一份配置里一次并进去（已在清单的、线路不存在的跳过）", "\(merged.added)")
        expect(models(merged.config, "aigocode") == ["claude-opus-5-5", "claude-sonnet-5", "claude-sonnet-5-5"], "aigocode：原有模型一个不少，新的追加在末尾", "\(models(merged.config, "aigocode"))")
        expect(models(merged.config, "dragoncode") == ["claude-opus-5-5", "claude-sonnet-5-5"], "dragoncode：同一份配置里也加上了", "")
        expect(models(merged.config, "glm") == ["glm-5.3"] && merged.config["PORT"] as? Int == 3456, "没动的线路和别的字段原样", "")
        expect(((merged.config["Providers"] as? [[String: Any]])?[0]["api_key"] as? String) == "k1", "线路的其它字段（密钥等）原样带着", "")
        expect(P.applyAdditions(config: config, approved: [P.Candidate(provider: "glm", model: "glm-5.3")]).added.isEmpty, "没有可追加的→added 为空（不该写）", "")
        var writes = P.State()
        expect(P.writeAllowed(writes, now: t0), "今天还没写过→可以写", "")
        writes.writes = [t0 - 3600, t0 - 25 * 3600]
        expect(P.writeAllowed(writes, now: t0), "24 小时内写过 1 次→还可以写", "")
        writes.writes = [t0 - 3600, t0 - 7200]
        expect(!P.writeAllowed(writes, now: t0), "24 小时内已写 2 次→不许再写", "")

        // —— 上架后被删掉的：不再自动加回 ——
        var listedState = P.State()
        listedState.entries["glm/glm-5.4"] = P.Entry(state: .listed)
        listedState.entries["aigocode/claude-sonnet-5-5"] = P.Entry(state: .listed)
        listedState.entries["gone/x-2"] = P.Entry(state: .listed)
        let reconciled = P.reconcileRemoved(listedState, listed: ["glm": ["glm-5.3"], "aigocode": ["claude-sonnet-5-5"]])
        expect(reconciled.entries["glm/glm-5.4"]?.state == .removed, "上架过的模型不在清单里了→removed", "")
        expect(reconciled.entries["aigocode/claude-sonnet-5-5"]?.state == .listed, "还在清单里的→仍是 listed", "")
        expect(reconciled.entries["gone/x-2"]?.state == .listed, "整条线路都不在了→不动", "")

        // P1-2：writing 状态对账——不在清单→removed；在清单→前进到 unconfirmed（上次的写其实落盘了）
        var writingState = P.State()
        writingState.entries["aigocode/claude-sonnet-5-5"] = P.Entry(state: .writing)
        writingState.entries["dragoncode/claude-opus-5-6"] = P.Entry(state: .writing)
        let rec2 = P.reconcileRemoved(writingState, listed: ["aigocode": ["claude-sonnet-5-5"], "dragoncode": ["claude-opus-5-5"]])
        expect(rec2.entries["aigocode/claude-sonnet-5-5"]?.state == .unconfirmed, "writing 且回读在清单里→前进到 unconfirmed", "\(rec2.entries["aigocode/claude-sonnet-5-5"]?.state.rawValue ?? "nil")")
        expect(rec2.entries["dragoncode/claude-opus-5-6"]?.state == .removed, "writing 且不在清单里→removed（不再自动加回）", "\(rec2.entries["dragoncode/claude-opus-5-6"]?.state.rawValue ?? "nil")")
        expect(rec2.entries.values.filter { $0.state == .approved }.isEmpty, "writing/removed 不会留在「直连通过待写」名单（不进 applyAdditions）", "\(rec2.entries)")

        // —— 通知文案 ——
        let change = P.mainModelChange(before: ["claude-opus-5-5"], after: ["claude-opus-5-5", "claude-opus-5-6"]) { $0.last }
        expect(change?.from == "claude-opus-5-5" && change?.to == "claude-opus-5-6", "主模型会变→给出从谁换成谁", "\(String(describing: change))")
        expect(P.mainModelChange(before: ["a"], after: ["a", "b"]) { $0.first } == nil, "主模型不变→nil", "")
        let one = P.notification([P.Added(lineName: "AIGoCode", model: "claude-sonnet-5-5", mainFrom: nil, mainTo: nil)])
        expect(one?.title == "AIGoCode 上架了新模型 claude-sonnet-5-5", "单个上架的通知标题", one?.title ?? "")
        expect(one?.body == "已用真实 Claude Code 直连实测通过，并加进了网关清单。正在跑的会话不受影响。", "主模型不变时正文不提主模型", one?.body ?? "")
        let both = P.notification([P.Added(lineName: "AIGoCode", model: "claude-sonnet-5-5", mainFrom: nil, mainTo: nil),
                                  P.Added(lineName: "Dragon Code", model: "claude-opus-5-6", mainFrom: "claude-opus-5-5", mainTo: "claude-opus-5-6")])
        expect(both?.title == "上架了 2 个新模型", "两个上架合并成一条通知", both?.title ?? "")
        expect(both?.body.contains("Dragon Code 新开的窗口主模型会从 claude-opus-5-5 换成 claude-opus-5-6。") == true, "主模型会变时正文明写从谁换成谁", both?.body ?? "")
        expect(P.notification([]) == nil, "没有上架→不发通知", "")

        // —— 账本时间戳的写法必须与账本逐字符一致 ——
        expect(P.ledgerTimestamp(Date(timeIntervalSince1970: 1_791_193_724.196)) == "2026-10-05T09:48:44.196Z", "账本时间戳格式 = 2026-10-05T09:48:44.196Z", P.ledgerTimestamp(Date(timeIntervalSince1970: 1_791_193_724.196)))

        // —— 状态文件：600；读不懂时返回 nil 而不是空 ——
        let dir = NSTemporaryDirectory() + "model-onboard-test-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let statePath = dir + "/state.json"
        expect(ModelOnboardStateStore.load(path: statePath) == P.State(), "状态文件不存在→空状态", "")
        var saved = P.State()
        saved.entries["aigocode/claude-sonnet-5-5"] = r1
        saved.writes = [t0]
        do {
            try ModelOnboardStateStore.save(saved, path: statePath)
            let perm = (try FileManager.default.attributesOfItem(atPath: statePath)[.posixPermissions] as? NSNumber)?.intValue ?? -1
            expect(perm == 0o600, "状态文件权限是 600", String(perm, radix: 8))
            expect(ModelOnboardStateStore.load(path: statePath) == saved, "写进去再读出来一模一样", "")
            try "not json".write(toFile: statePath, atomically: true, encoding: .utf8)
            expect(ModelOnboardStateStore.load(path: statePath) == nil, "状态文件读不懂→nil（不能当成空的）", "")
        } catch {
            expect(false, "状态文件读写", "\(error)")
        }

        // —— 退避数值 ——
        expect(P.retryDelayAfterHardFail(consecutiveFailures: 1) == 7 * 86_400, "确定失败 1 次→7 天后再试", "")
        expect(P.retryDelayAfterHardFail(consecutiveFailures: 2) == 7 * 86_400, "确定失败 2 次→7 天后再试", "")
        expect(P.retryDelayAfterHardFail(consecutiveFailures: 3) == 30 * 86_400, "确定失败 3 次→30 天后再试", "")
        expect(P.retryDelayAfterUnsure(consecutiveUnsure: 1) == 0, "拿不准 1 次→下一轮可再试", "")
        expect(P.retryDelayAfterUnsure(consecutiveUnsure: 3) == 86_400, "拿不准 3 次→歇 24 小时", "")

        if failures.isEmpty {
            print("model_onboard: 全部通过")
        } else {
            print("model_onboard: \(failures.count) 项失败")
            exit(1)
        }
    }
}
