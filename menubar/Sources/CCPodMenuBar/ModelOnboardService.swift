import Foundation
import SQLite3
import UserNotifications

// ModelOnboardService — 新模型自动上架（判定规则全在 ModelOnboardPolicy，这里只做有副作用的那部分）。
//
// 每轮（挂在存量线路周期实测后面，同一个后台线程）：
//   1. 发现：只读网关配置 + 拉各线路上游模型目录 → 「比清单里同系列更新」的候选；
//   2. 实测：用真实 Claude Code 客户端**直连上游**发一次最小请求（scripts/ccmodel-probe.py）；
//   3. 上架：本轮有通过的 → 新鲜读一次网关配置、只追加模型、**只写一次**、回读确认；
//   4. 确认：等几秒，经网关再走一次，看账本里是不是真路由到了「线路/模型」；
//   5. 通知 + 记录。
//
// 为什么直连而不是「先加进清单再测」：往网关写 Providers 会让它重启转发进程（CCR 3.1.1 的 saveConfig：
// Providers 在「要不要重启」的比较范围里），同一秒在跑的会话会吃到 502。直连测，没通过的候选完全不碰网关。
//
// 开关（`defaults write com.ccpod.menubar <键> -bool true`）：
//   modelOnboardDryRun    干跑：照常发现、照常直连实测，但不写网关，只把「本应写入什么」记下来
//   modelOnboardDisabled  只发现，不实测、不上架
enum ModelOnboardService {

    static let recordPath = NSString(string: "~/.claude/ccpod-model-onboard-round.json").expandingTildeInPath
    static let lastRoundKey = "modelOnboardLastRound"   // 与 lineAutoProbeLastRound 同款留痕，`defaults read com.ccpod.menubar` 可查
    static let dryRunKey = "modelOnboardDryRun"
    static let disabledKey = "modelOnboardDisabled"
    static let probeScriptKey = "modelOnboardProbeScript"
    static let usageDB = NSString(string: "~/.claude-code-router/app-data/usage.sqlite").expandingTildeInPath
    /// 一条线路拉目录最多等这么久（ModelCatalogFetcher 自己是 15s 请求超时、25s 总超时，可能连试两个地址）。
    static let catalogWait: TimeInterval = 60
    /// 实测脚本自己 60 秒超时会杀掉 claude；这里再留余量兜底，绝不无限等。
    static let probeWait: TimeInterval = 90
    /// 写完网关后等它重启好再去确认路由。
    static let settleSeconds: TimeInterval = 4

    struct LineResult {
        let provider: String
        let listedCount: Int
        let catalogCount: Int?      // nil = 目录没拉到
        let error: String?          // 目录没拉到的原因（已脱敏）
        let discovery: ModelOnboardPolicy.Discovery?
    }

    struct ProbeRecord {
        let provider: String
        let model: String
        let outcome: String     // 通过 / 被上游拒绝 / 拿不准 / 没测（附原因）
        let detail: String?     // 已脱敏
    }

    struct Round {
        var lines: [LineResult] = []
        var failure: String?            // 整轮没做成的原因（网关没在运行等）
        var mode = "live"               // live / dry-run / discover-only
        var probes: [ProbeRecord] = []
        var aborted: String?            // 本机故障导致实测中止
        var added: [ModelOnboardPolicy.Added] = []            // 已写入并回读确认
        var wouldWrite: [ModelOnboardPolicy.Candidate] = []   // 干跑时：本应写入什么
        var unconfirmed: [String] = []  // 已加入清单但路由未确认（"线路/模型"）
        var notes: [String] = []

        /// 给弹窗「自动实测」那一行用的一句话；没什么可说时为 nil。
        var summary: String? {
            if let failure { return "新模型检查未执行：\(failure)" }
            var parts: [String] = []
            if let aborted { parts.append("新模型实测中止：\(aborted)") }
            if !added.isEmpty { parts.append("上架了 \(added.count) 个新模型（\(added.map { "\($0.lineName) \($0.model)" }.joined(separator: "、"))）") }
            if !wouldWrite.isEmpty {
                parts.append("干跑：\(wouldWrite.map { "\(gatewayProviderGroupDisplayName($0.provider)) \($0.model)" }.joined(separator: "、")) 直连实测通过，本应上架（没有写网关）")
            }
            if !unconfirmed.isEmpty { parts.append("\(unconfirmed.joined(separator: "、")) 已加入清单但路由未确认") }
            let failed = probes.filter { $0.outcome == "被上游拒绝" || $0.outcome == "拿不准" }
            if !failed.isEmpty {
                parts.append("\(failed.count) 个新模型没通过（\(failed.map { "\(gatewayProviderGroupDisplayName($0.provider)) \($0.model) \($0.outcome)" }.joined(separator: "、"))）")
            }
            let handled = Set(probes.map { ModelOnboardPolicy.key($0.provider, $0.model) })
            let waiting = lines.flatMap { line in
                (line.discovery?.candidates ?? []).filter { !handled.contains(ModelOnboardPolicy.key(line.provider, $0)) }
                    .map { "\(gatewayProviderGroupDisplayName(line.provider)) \($0)" }
            }
            if !waiting.isEmpty, added.isEmpty, wouldWrite.isEmpty {
                parts.append("发现 \(waiting.count) 个上游新模型还没上架（\(waiting.joined(separator: "、"))）")
            }
            let unreachable = lines.filter { $0.catalogCount == nil }.count
            if unreachable > 0 { parts.append("\(unreachable) 条线路的模型目录没拉到") }
            parts.append(contentsOf: notes)
            return parts.isEmpty ? nil : parts.joined(separator: "；")
        }
    }

    /// 线路的密钥只在这一轮的内存里，不进 Round、不进记录。
    private struct LineSecret {
        let provider: String
        let baseURL: String
        let apiKey: String
        let listed: [String]
    }

    /// 同步执行，**必须在后台线程调用**（会等网络、会等子进程）。每一步等待都有上限。
    static func discoverRound(recordPath: String = recordPath, statePath: String = ModelOnboardStateStore.defaultPath) -> Round {
        guard !Thread.isMainThread else {
            return Round(failure: "内部错误：新模型检查被放到了主线程，已跳过")
        }
        var secrets: [LineSecret] = []
        var round = collect(&secrets)
        let defaults = UserDefaults.standard
        let dryRun = defaults.bool(forKey: dryRunKey) || ProcessInfo.processInfo.environment["CCPOD_MODEL_ONBOARD_DRYRUN"] == "1"
        if defaults.bool(forKey: disabledKey) {
            round.mode = "discover-only"
        } else {
            round.mode = dryRun ? "dry-run" : "live"
            if round.failure == nil { onboard(&round, secrets: secrets, dryRun: dryRun, statePath: statePath) }
        }
        write(round, to: recordPath)
        if let alert = ModelOnboardPolicy.notification(round.added) { postNotification(title: alert.title, body: alert.body) }
        return round
    }

    // MARK: - 1. 发现

    private static func collect(_ secrets: inout [LineSecret]) -> Round {
        guard let state = CCRConfigService.serviceState() else { return Round(failure: "网关没在运行") }
        let config: [String: Any]
        do {
            config = try CCRConfigService.fetchConfig(state: state)
        } catch {
            return Round(failure: SecretRedactor.redact(error.localizedDescription))
        }
        guard let providers = config["Providers"] as? [[String: Any]] else { return Round(failure: "网关配置结构异常") }
        var lines: [LineResult] = []
        for provider in providers {
            guard let name = provider["name"] as? String, let listed = provider["models"] as? [String] else { continue }
            guard let baseURL = provider["api_base_url"] as? String, !baseURL.isEmpty,
                  let apiKey = SecretResolver.value(from: provider["api_key"]), !apiKey.isEmpty else {
                lines.append(LineResult(provider: name, listedCount: listed.count, catalogCount: nil,
                                        error: "线路缺地址或密钥", discovery: nil))
                continue
            }
            secrets.append(LineSecret(provider: name, baseURL: baseURL, apiKey: apiKey, listed: listed))
            let outcome = fetchCatalog(baseURL: baseURL, apiKey: apiKey)
            guard let catalog = outcome.models else {
                lines.append(LineResult(provider: name, listedCount: listed.count, catalogCount: nil,
                                        error: scrub(outcome.message, [apiKey]), discovery: nil))
                continue
            }
            let ids = catalog.map(ModelCatalogFetcher.normalize)
            lines.append(LineResult(provider: name, listedCount: listed.count, catalogCount: ids.count, error: nil,
                                    discovery: ModelOnboardPolicy.discover(listed: listed, catalog: ids)))
        }
        return Round(lines: lines)
    }

    /// ModelCatalogFetcher 在主线程回调；这里在后台线程等它，带上限。
    private static func fetchCatalog(baseURL: String, apiKey: String) -> ModelCatalogFetcher.Outcome {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: ModelCatalogFetcher.Outcome?
        ModelCatalogFetcher.fetch(baseURL: baseURL, apiKey: apiKey) { outcome in
            lock.lock(); result = outcome; lock.unlock()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + catalogWait) == .timedOut {
            return ModelCatalogFetcher.Outcome(models: nil, message: "拉模型目录超过 \(Int(catalogWait)) 秒没有结果")
        }
        lock.lock(); defer { lock.unlock() }
        return result ?? ModelCatalogFetcher.Outcome(models: nil, message: "拉取失败")
    }

    // MARK: - 2–4. 实测、上架、确认

    private static func onboard(_ round: inout Round, secrets: [LineSecret], dryRun: Bool, statePath: String) {
        typealias P = ModelOnboardPolicy
        guard var state = ModelOnboardStateStore.load(path: statePath) else {
            // 读不懂就停手：把它当成空的会忘掉所有退避记录，然后重复花钱
            round.aborted = "状态文件读不懂（\(statePath)），这一轮不实测、不上架"
            return
        }
        let now = Date().timeIntervalSince1970
        let listed = Dictionary(secrets.map { ($0.provider, $0.listed) }, uniquingKeysWith: { first, _ in first })
        state = P.reconcileRemoved(state, listed: listed)
        var secretValues = secrets.map(\.apiKey)

        // 直连实测
        let candidates = round.lines.flatMap { line in
            (line.discovery?.candidates ?? []).map { P.Candidate(provider: line.provider, model: $0) }
        }
        let selection = P.pick(candidates, state: state, aliveProviders: aliveProviders(), now: now)
        for (candidate, reason) in selection.skipped where !reason.isEmpty {
            round.probes.append(ProbeRecord(provider: candidate.provider, model: candidate.model, outcome: "没测", detail: reason))
        }
        for candidate in selection.picked {
            guard let secret = secrets.first(where: { $0.provider == candidate.provider }) else { continue }
            let output = runProbe(baseURL: secret.baseURL, model: candidate.model, apiKey: secret.apiKey)
            let verdict = P.directVerdict(output, model: candidate.model)
            if case .localFault(let why) = verdict {
                // 本机问题不记到模型头上：整轮中止，状态原样不动
                round.aborted = scrub(why, secretValues)
                break
            }
            let key = P.key(candidate.provider, candidate.model)
            if var entry = P.afterProbe(previous: state.entries[key], verdict: verdict, now: now) {
                entry.note = entry.note.map { scrub($0, secretValues) }
                state.entries[key] = entry
            }
            switch verdict {
            case .pass:
                round.probes.append(ProbeRecord(provider: candidate.provider, model: candidate.model, outcome: "通过", detail: "直连实测通过"))
            case .rejected(let status, let detail):
                round.probes.append(ProbeRecord(provider: candidate.provider, model: candidate.model, outcome: "被上游拒绝",
                                                detail: scrub("上游返回 \(status)。\(detail)", secretValues)))
            case .unsure(let why):
                round.probes.append(ProbeRecord(provider: candidate.provider, model: candidate.model, outcome: "拿不准",
                                                detail: scrub(why, secretValues)))
            case .localFault:
                break
            }
        }

        // 直连通过、还没写进清单的（含上一轮干跑或写入次数用完留下的，24 小时内有效）
        let approved = state.entries.compactMap { key, entry -> P.Candidate? in
            guard entry.state == .approved, now - entry.lastTriedAt <= P.approvalLifetime else { return nil }
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            return parts.count == 2 ? P.Candidate(provider: parts[0], model: parts[1]) : nil
        }.sorted { P.key($0.provider, $0.model) < P.key($1.provider, $1.model) }

        var newlyWritten: [P.Candidate] = []
        if !approved.isEmpty, round.aborted == nil {
            if dryRun {
                round.wouldWrite = approved
            } else if !P.writeAllowed(state, now: now) {
                round.notes.append("今天往网关写配置的次数已到上限（\(P.maxWritesPerDay) 次），直连通过的新模型明天再上架")
            } else {
                newlyWritten = writeOnce(approved, round: &round, state: &state, now: now, statePath: statePath)
            }
        }

        // 经网关确认路由：这一轮刚写的 + 之前没确认上的（最多 2 个，每个花一次最小请求）
        if !dryRun, round.aborted == nil {
            if !newlyWritten.isEmpty { Thread.sleep(forTimeInterval: settleSeconds) }
            let pending = state.entries.filter { $0.value.state == .unconfirmed && now >= $0.value.nextRetryAt }.keys.sorted()
            if !pending.isEmpty {
                // 一次性读配置：网关地址 + 入站 key（找不到 profile:default-claude-code 就不确认、不计数，P2-3）
                if let ctx = confirmContext() {
                    secretValues.append(ctx.inbound)   // 入站 key 也过脱敏（P2-3）
                    for key in pending.prefix(P.maxProbesPerRound) {
                        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
                        guard parts.count == 2 else { continue }
                        switch confirmViaGateway(provider: parts[0], model: parts[1], origin: ctx.origin, inbound: ctx.inbound) {
                        case .confirmed:
                            state.entries[key]?.state = .listed
                            state.entries[key]?.note = nil
                        case .notConfirmed:
                            let tries = (state.entries[key]?.unsures ?? 0) + 1
                            state.entries[key]?.unsures = tries
                            state.entries[key]?.nextRetryAt = now + (tries >= 3 ? 7 * 86_400 : 0)
                            state.entries[key]?.note = "已加入清单，但经网关走一遍没确认到路由（第 \(tries) 次）；没有回滚"
                            round.unconfirmed.append(key)
                        case .localFault(let why):
                            // 本机故障（脚本起不来、找不到入站 key）不记成「没确认到路由」，不计入 unsures（P2-2）
                            round.notes.append(scrub("经网关确认没做成（本机问题）：\(why)", secretValues))
                        }
                    }
                } else {
                    round.notes.append("没法确认路由：找不到网关的入站钥匙（profile:default-claude-code），这一轮不确认")
                }
            }
        }

        do {
            try ModelOnboardStateStore.save(state, path: statePath)
        } catch {
            round.notes.append("状态文件写不进去（\(error.localizedDescription)），下一轮可能重复实测")
        }
    }

    /// 一轮只写一次：新鲜读配置 → 只追加模型 → saveConfig → 回读确认。返回确认已在清单里的。
    /// P1-2：saveConfig 之前先把写入意图落盘（计数 + writing 状态立即写状态文件），
    /// 这样写超时已生效 / App 在写之后被杀，计数和意图都不丢；saveConfig 抛错不假定没写，回读一次再定。
    private static func writeOnce(_ approved: [ModelOnboardPolicy.Candidate], round: inout Round,
                                  state: inout ModelOnboardPolicy.State, now: Double,
                                  statePath: String) -> [ModelOnboardPolicy.Candidate] {
        typealias P = ModelOnboardPolicy
        guard let service = CCRConfigService.serviceState(),
              let fresh = try? CCRConfigService.fetchConfig(state: service) else {
            round.notes.append("直连通过的新模型没能上架：这会儿读不到网关配置，下一轮再试")
            return []
        }
        let merged = P.applyAdditions(config: fresh, approved: approved)
        // 已经在清单里的（别人先加了）：不用写，直接进入「等确认路由」
        for candidate in approved where !merged.added.contains(candidate) {
            if models(of: candidate.provider, in: fresh)?.contains(candidate.model) == true {
                state.entries[P.key(candidate.provider, candidate.model)]?.state = .unconfirmed
            }
        }
        guard !merged.added.isEmpty else { return [] }

        // P1-2：写之前先把意图落盘（计数先加、状态先记 writing），立即写状态文件
        state.writes = state.writes.filter { now - $0 < 86_400 } + [now]
        for candidate in merged.added {
            let key = P.key(candidate.provider, candidate.model)
            state.entries[key]?.state = .writing
            state.entries[key]?.note = nil
        }
        do { try ModelOnboardStateStore.save(state, path: statePath) } catch {
            round.notes.append("写网关前没记下意图（\(SecretRedactor.redact(error.localizedDescription))），仍继续写")
        }

        // 写网关（可能抛错；抛错不假定没写，下面统一回读）
        do {
            // 不带 {applyProfile:false}：与线路设置窗口、今天手动补清单走的是同一条已验证过的路径。
            // 网关会不会重启取决于 Providers 变没变（变了必重启），跟 applyProfile 无关。
            _ = try CCRConfigService.rpc(method: "saveConfig", args: [merged.config], state: service)
        } catch {
            round.notes.append("往网关写配置报错（\(SecretRedactor.redact(error.localizedDescription))），回读确认是否其实已写入")
        }

        // 回读确认：只有确实在清单里的才算上架、才前进到 unconfirmed；不在的保持 writing，下一轮对账会处理
        let after = (try? CCRConfigService.fetchConfig(state: service)) ?? [:]
        let lineFiles = GatewayLineService.readLines(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/providers"))
        var written: [P.Candidate] = []
        for candidate in merged.added {
            let key = P.key(candidate.provider, candidate.model)
            guard let nowListed = models(of: candidate.provider, in: after), nowListed.contains(candidate.model) else {
                round.notes.append("\(key) 写完回读不在清单里，保持待定，下一轮若仍不在就不再加回")
                continue
            }
            state.entries[key]?.state = .unconfirmed
            state.entries[key]?.unsures = 0
            state.entries[key]?.nextRetryAt = 0
            written.append(candidate)
            // 自动选型的线路：主模型会不会因此换掉，要在通知里明说
            var change: (from: String, to: String)?
            let line = lineFiles[GatewayLineService.pipelineID(candidate.provider)]
            if line?["model_selection"] as? String != "manual", let before = models(of: candidate.provider, in: fresh) {
                change = P.mainModelChange(before: before, after: nowListed, suggest: GatewayLineService.suggestedModel)
            }
            round.added.append(P.Added(lineName: gatewayProviderGroupDisplayName(candidate.provider), model: candidate.model,
                                       mainFrom: change?.from, mainTo: change?.to))
        }
        return written
    }

    private static func models(of provider: String, in config: [String: Any]) -> [String]? {
        (config["Providers"] as? [[String: Any]])?.first { ($0["name"] as? String) == provider }?["models"] as? [String]
    }

    /// 经网关确认路由的结果。
    enum ConfirmOutcome: Equatable {
        case confirmed
        case notConfirmed   // 走了网关，账本没对上（真没路由到，或账本读不了）
        case localFault(String)   // 本机问题（脚本起不来等）：不计入「没确认到路由」的次数
    }

    /// 网关地址 + 入站 key（与真实会话同一把：Profile: Claude Code）。拿不到返回 nil。
    private struct ConfirmContext {
        let origin: String
        let inbound: String
    }

    private static func confirmContext() -> ConfirmContext? {
        guard let service = CCRConfigService.serviceState(),
              let config = try? CCRConfigService.fetchConfig(state: service),
              let origin = try? GatewayLineService.inferenceOrigin(config: config) else { return nil }
        // P2-3：只认 profile:default-claude-code 这一把；找不到就不确认，绝不用 keys.first 兜底（那是别家的 key）
        let keys = config["APIKEYS"] as? [[String: Any]] ?? []
        guard let profile = keys.first(where: { ($0["id"] as? String) == "profile:default-claude-code" }),
              let inbound = SecretResolver.value(from: profile["key"]), !inbound.isEmpty else { return nil }
        return ConfirmContext(origin: origin, inbound: inbound)
    }

    /// 经本机网关用真实客户端走一次「线路/模型」，再到账本里看它是不是真路由到了这条线路并返回 200。
    /// 入站 key 用网关配置里「Profile: Claude Code」那一把（与真实会话同一把），同样走一次性配置目录。
    private static func confirmViaGateway(provider: String, model: String, origin: String, inbound: String) -> ConfirmOutcome {
        let since = ModelOnboardPolicy.ledgerTimestamp(Date().addingTimeInterval(-1))
        let probe = runProbe(baseURL: origin, model: provider + "/" + model, apiKey: inbound)
        if let localError = probe.localError, !localError.isEmpty { return .localFault(localError) }
        Thread.sleep(forTimeInterval: 1)   // 账本是请求结束后才落的
        guard let rows = ledgerRows(since: since) else { return .notConfirmed }
        return ModelOnboardPolicy.verdict(rows: rows, provider: provider, model: model) == .pass ? .confirmed : .notConfirmed
    }

    // MARK: - 实测子进程（scripts/ccmodel-probe.py：人在终端也能用同一条路径手动复现）

    static func probeScriptPath() -> String? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: probeScriptKey), fm.isReadableFile(atPath: custom) { return custom }
        // 安装脚本把 ccgo 链到仓库的 scripts/ccgo.sh；实测脚本就在它旁边
        let link = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/ccgo")
        let script = link.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("ccmodel-probe.py")
        return fm.isReadableFile(atPath: script.path) ? script.path : nil
    }

    private static func runProbe(baseURL: String, model: String, apiKey: String) -> ModelOnboardPolicy.DirectOutput {
        guard let script = probeScriptPath() else {
            return .init(localError: "找不到实测脚本 ccmodel-probe.py（ccgo 没装好，或仓库挪了位置）", exitCode: nil, timedOut: false, stdout: "")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script, "--base-url", baseURL, "--model", model]
        var environment = ProcessInfo.processInfo.environment
        environment["CCPOD_PROBE_API_KEY"] = apiKey   // key 只经环境传给脚本；脚本再只挑白名单变量传给 claude
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return .init(localError: "实测脚本起不来：\(error.localizedDescription)", exitCode: nil, timedOut: false, stdout: "")
        }
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + probeWait)
        watchdog.setEventHandler { [weak process] in process?.terminate() }
        watchdog.resume()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        watchdog.cancel()
        process.waitUntilExit()
        // lossy 解码：半个多字节字符不该让整段变成 nil（PITFALLS #15）
        let text = String(decoding: data, as: UTF8.self)
        guard let payload = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return .init(localError: "实测脚本没有给出可读的结果（退出码 \(process.terminationStatus)）", exitCode: nil, timedOut: false, stdout: "")
        }
        return .init(localError: object["local_error"] as? String,
                     exitCode: (object["rc"] as? NSNumber)?.intValue,
                     timedOut: (object["timed_out"] as? Bool) ?? false,
                     stdout: (object["stdout"] as? String) ?? "")
    }

    // MARK: - 账本（只读）

    private static func withLedger<T>(_ body: (OpaquePointer) -> T?) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(usageDB, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        return body(db)
    }

    private static func query(_ db: OpaquePointer, _ sql: String, _ argument: String, columns: Int32) -> [[String]]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT：让 sqlite 自己拷一份字符串
        sqlite3_bind_text(statement, 1, argument, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<columns).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" })
        }
        return rows
    }

    /// 近 7 天有过成功请求的线路；账本读不了 → nil（不知道，调用方就一个都不测）。
    private static func aliveProviders() -> Set<String>? {
        let since = ModelOnboardPolicy.ledgerTimestamp(Date().addingTimeInterval(-7 * 86_400))
        return withLedger { db in
            query(db, "select distinct provider from usage_events where status_code = 200 and created_at >= ?1", since, columns: 1)
                .map { Set($0.compactMap(\.first)) }
        }
    }

    private static func ledgerRows(since: String) -> [ModelOnboardPolicy.LedgerRow]? {
        withLedger { db in
            query(db, "select model, logical_model, status_code from usage_events where created_at >= ?1", since, columns: 3)?
                .map { ModelOnboardPolicy.LedgerRow(model: $0[0], logicalModel: $0[1], status: Int($0[2]) ?? 0) }
        }
    }

    // MARK: - 通知（一轮一条；只在「直连通过 + 已写入并回读确认」时发）

    private static func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }   // 没授权时弹窗那行摘要和 ccdoctor 仍然会说（PITFALLS #42）
            let content = UNMutableNotificationContent()
            content.title = gatewayVisibleText(title)
            content.body = gatewayVisibleText(body)
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "model-onboard-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }

    // MARK: - 本轮记录（只有模型名、状态和原因；不含密钥，仍按约定 600 + 过脱敏）

    /// 先把这一轮用过的密钥原文逐个抹掉，再过通用脱敏（通用规则只认已知前缀，认不全）。
    private static func scrub(_ text: String, _ secrets: [String]) -> String {
        var result = text
        for secret in secrets where secret.count >= 6 { result = result.replacingOccurrences(of: secret, with: "***") }
        return SecretRedactor.redact(result)
    }

    static func recordObject(_ round: Round, at date: Date = Date()) -> [String: Any] {
        var object: [String: Any] = [
            "schema_version": 1,
            "mode": round.mode,
            "at": ISO8601DateFormatter().string(from: date),
            "lines": round.lines.map { line -> [String: Any] in
                var item: [String: Any] = ["provider": line.provider, "listed": line.listedCount]
                if let count = line.catalogCount { item["catalog"] = count }
                if let error = line.error { item["error"] = SecretRedactor.redact(error) }
                if let discovery = line.discovery {
                    item["candidates"] = discovery.candidates
                    item["skipped"] = discovery.skipped.map { ["model": $0.model, "reason": $0.reason] }
                }
                return item
            },
            "probes": round.probes.map { probe -> [String: Any] in
                var item: [String: Any] = ["provider": probe.provider, "model": probe.model, "outcome": probe.outcome]
                if let detail = probe.detail { item["detail"] = SecretRedactor.redact(detail) }
                return item
            },
            "added": round.added.map { item -> [String: Any] in
                var object: [String: Any] = ["line": item.lineName, "model": item.model]
                if let from = item.mainFrom, let to = item.mainTo { object["main_from"] = from; object["main_to"] = to }
                return object
            },
            "would_write": round.wouldWrite.map { ["provider": $0.provider, "model": $0.model] },
            "unconfirmed": round.unconfirmed,
            "notes": round.notes.map(SecretRedactor.redact),
        ]
        if let failure = round.failure { object["failure"] = SecretRedactor.redact(failure) }
        if let aborted = round.aborted { object["aborted"] = SecretRedactor.redact(aborted) }
        return object
    }

    private static func write(_ round: Round, to path: String) {
        let object = recordObject(round)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = URL(fileURLWithPath: path)
        do {
            try data.write(to: url, options: .atomic)
            // .atomic 会按 umask 建成 644，必须显式收紧（PITFALLS #18）
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            UserDefaults.standard.set(["at": Date().timeIntervalSince1970,
                                       "error": "记录写不进 \(path)：\(error.localizedDescription)"], forKey: lastRoundKey)
            return
        }
        var trace: [String: Any] = ["at": Date().timeIntervalSince1970, "record": path, "mode": round.mode]
        if let failure = round.failure { trace["error"] = SecretRedactor.redact(failure) }
        if let aborted = round.aborted { trace["aborted"] = SecretRedactor.redact(aborted) }
        trace["candidates"] = Dictionary(round.lines.compactMap { line in
            line.discovery.map { (line.provider, $0.candidates) }
        }, uniquingKeysWith: { first, _ in first })
        trace["added"] = round.added.map { "\($0.lineName) \($0.model)" }
        UserDefaults.standard.set(trace, forKey: lastRoundKey)
    }
}
