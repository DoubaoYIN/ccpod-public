import Foundation
import UserNotifications

// LineCheckService — 线路体检（B 路线③）。
// 只消费实验室资产 line-check.py 的 --json 机器接口，不复制体检逻辑
// （分层管线见 model-gateway/docs/architecture.md：实验室产出，产品表面化）。
final class LineCheckService: ObservableObject {
    struct LineRow: Identifiable {
        let name: String
        let level: String      // G / Y / R
        let note: String?      // 第一条非绿消息（截断展示）
        /// true = 网关本体/settings 检查块的合成行（非 provider，无额度/用量/测通）
        let isCheckBlock: Bool
        /// 合成行的显示名；provider 行为 nil（走 gatewayProviderGroupDisplayName）
        let displayName: String?
        /// 合成行的「去哪修」；provider 行为 nil（它们有自己的「设置」入口）
        let fix: LineCheckFixAdvice?
        var id: String { name }

        init(name: String, level: String, note: String?, isCheckBlock: Bool = false, displayName: String? = nil,
             fix: LineCheckFixAdvice? = nil) {
            self.name = name
            self.level = level
            self.note = note
            self.isCheckBlock = isCheckBlock
            self.displayName = displayName
            self.fix = fix
        }
    }

    private struct Payload: Decodable {
        let schemaVersion: Int?
        let counts: [String: Int]
        let overall: String
        let providers: [Provider]
        let gateway: [Msg]?    // 网关本体检查（计入 counts，但原来 UI 无行 → 黄计数找不到归属）
        let settings: [Msg]?   // settings.json 检查（同上）
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case counts, overall, providers, gateway, settings
        }
        struct Provider: Decodable {
            let name: String
            let level: String
            let msgs: [Msg]?
        }
        struct Msg: Decodable {
            let level: String
            let msg: String
        }
    }

    /// 本版认识的最大 --json 接口版本。脚本输出更高版本 = 接口已不兼容演进，显式报错而非静默白屏。
    /// nil（旧脚本无版本字段）按兼容处理：当前字段尚未有不兼容变更，正常展示。
    static let supportedSchemaVersion = 1

    static let scriptPath = NSString(string: "~/projects/model-gateway/scripts/line-check.py").expandingTildeInPath
    // 产品运行时副本：实验室源在则自动同步，实验室没了副本照用（解耦跨仓库依赖）
    static let installedPath = NSString(string: "~/.claude/bin/line-check.py").expandingTildeInPath

    @Published var lines: [LineRow] = []
    @Published var counts: [String: Int] = [:]
    @Published var checkedAt: Date?
    @Published var unavailable: String?
    @Published var running = false
    // 行内动作：测通 / 用量
    @Published var probing: Set<String> = []
    @Published var probeResults: [String: String] = [:]
    @Published var usageTexts: [String: String] = [:]
    private var resolvedScript: String?

    /// 解析脚本位置：实验室源（开发版）较新则同步到产品副本；返回实际可执行路径。
    static func resolveScript() -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: scriptPath) {
            let labNewer: Bool = {
                guard let attributes = try? fm.attributesOfItem(atPath: installedPath),
                      let installedDate = attributes[.modificationDate] as? Date,
                      let labDate = try? fm.attributesOfItem(atPath: scriptPath)[.modificationDate] as? Date
                else { return true }
                return labDate > installedDate
            }()
            if labNewer {
                try? fm.removeItem(atPath: installedPath)
                try? fm.copyItem(atPath: scriptPath, toPath: installedPath)
            }
            return installedPath
        }
        return fm.fileExists(atPath: installedPath) ? installedPath : nil
    }

    func refresh() {
        guard !running else { return }
        // 演示数据（仅实机走查用）：变量存在就只认它，读不出来明说原因，绝不悄悄退回真实体检——
        // 否则走查时分不清眼前是哪份数据。
        if let fixture = LineCheckFixture.path(in: ProcessInfo.processInfo.environment) {
            unavailable = nil
            running = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                switch Self.loadFixture(path: fixture) {
                case .failure(let reason): self?.publish(unavailable: reason.text)
                case .success(let payload): self?.apply(payload, demo: true)
                }
            }
            return
        }
        guard let script = Self.resolveScript() else {
            unavailable = "未找到 line-check.py（实验室路径与产品副本均不存在）"
            return
        }
        resolvedScript = script
        unavailable = nil
        running = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runScript()
        }
    }

    private func runScript() {
        let payload: Payload
        switch Self.fetchStatic(script: resolvedScript ?? Self.installedPath) {
        case .failure(let reason): publish(unavailable: reason.text); return
        case .success(let p): payload = p
        }
        apply(payload, demo: false)
    }

    /// demo = 演示数据：每一行的名字后面都标「（演示数据）」，不会被当成真实体检结果。
    private func apply(_ payload: Payload, demo: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.counts = payload.counts
            var rows = payload.providers.map { p in
                LineRow(name: p.name, level: p.level,
                        note: (p.msgs?.first { $0.level != "G" }?.msg).map { gatewayVisibleText($0) },
                        displayName: demo ? LineCheckFixture.label(gatewayProviderGroupDisplayName(p.name)) : nil)
            }
            // 计数与可见行对账：counts 含 gateway/settings 两块，原来 UI 只渲染 provider 行，
            // 网关/settings 的非绿消息"有计数无行"（🟡1 找不到黄点的根因）。
            // 给含非绿消息的块补合成行；全绿不补，保持区面干净。
            for (msgs, id, label) in [(payload.gateway, "check:gateway", "网关本体"),
                                      (payload.settings, "check:settings", "settings.json")] as [([Payload.Msg]?, String, String)] {
                guard let msgs, let firstBad = msgs.first(where: { $0.level != "G" }) else { continue }
                let level = msgs.contains { $0.level == "R" } ? "R" : "Y"
                // note 与灯色配套：红就行别配黄消息——优先第一条 R，没有 R 才用第一条非绿
                let noteMsg = msgs.first { $0.level == "R" }?.msg ?? firstBad.msg
                // 修复建议用原始消息算；展示用的文字替换会把命令里的 ccr 也换掉（com.matthew.网关-gateway）
                rows.append(LineRow(name: id, level: level,
                                    note: gatewayVisibleText(LineCheckFixPolicy.messageWithoutCommand(noteMsg)),
                                    isCheckBlock: true, displayName: demo ? LineCheckFixture.label(label) : label,
                                    fix: LineCheckFixPolicy.advice(block: id, rawMessage: noteMsg)))
            }
            self.lines = rows
            self.checkedAt = Date()
        }
    }

    private func publish(unavailable reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.running = false
            self?.unavailable = gatewayVisibleText(reason)
        }
    }

    private struct FetchError: Error { let text: String }

    /// 静态体检（同步，后台线程调用）。手动「重新体检」与周期实测共用，取线路名单也走这里。
    private static func fetchStatic(script: String) -> Result<Payload, FetchError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script, "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(FetchError(text: "无法启动 python3：\(error.localizedDescription)"))
        }
        // 20s 看门狗：静态体检正常 <1s，超时按失败处理
        let timedOut = AtomicFlag()
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 20)
        watchdog.setEventHandler { [weak process] in
            timedOut.set()
            process?.terminate()
        }
        watchdog.resume()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        watchdog.cancel()
        process.waitUntilExit()

        // 原来判 `terminationStatus != 9`，但 terminate() 发的是 SIGTERM(15) 不是 SIGKILL(9)，
        // 所以超时永远落到下面的 JSON 解析分支，被误报成"脚本版本可能过旧"——把人引向错误方向。
        // 改成看门狗自己记账（跨线程，用锁），再按"被信号杀死"兜底。
        if timedOut.isSet || process.terminationReason == .uncaughtSignal {
            return .failure(FetchError(text: "体检超时（>20s）或被信号中止，已停止"))
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return .failure(FetchError(text: "体检输出解析失败（脚本版本可能过旧，需含 --json）"))
        }
        if let v = payload.schemaVersion, v > Self.supportedSchemaVersion {
            return .failure(FetchError(text: "体检接口 v\(v) 高于本版 ccpod 支持（v\(Self.supportedSchemaVersion)），请升级 ccpod"))
        }
        return .success(payload)
    }

    /// 演示数据：与 line-check.py --json 同一份结构、同一个解码器。
    private static func loadFixture(path: String) -> Result<Payload, FetchError> {
        guard let data = FileManager.default.contents(atPath: path) else {
            return .failure(FetchError(text: "演示数据读不到：\(path)（\(LineCheckFixture.envKey) 指向的文件不存在或无权读取）"))
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return .failure(FetchError(text: "演示数据解析失败：\(path)（要和 line-check.py --json 的输出同结构）"))
        }
        return .success(payload)
    }

    // MARK: - 行内测通（line-check.py --probe <名称> --json，与实验室深检同源）
    // 注意：探测会向该线路每个模型发一次 max_tokens=8 的真实请求（按量线路有微小花费）。

    func probe(name: String) {
        guard !probing.contains(name) else { return }
        guard let script = Self.resolveScript() else {
            probeResults[name] = "未找到 line-check.py"
            return
        }
        probing.insert(name)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Self.runProbe(name: name, script: script)
            DispatchQueue.main.async {
                self.probing.remove(name)
                self.probeResults[name] = gatewayVisibleText(result.text)
            }
        }
    }

    private static func runProbe(name: String, script: String) -> (verdict: LineProbeVerdict, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script, "--probe", name, "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (.unsure, "无法启动 python3") }
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 120)   // 探测含逐模型真实请求，放宽到 120s
        watchdog.setEventHandler { [weak process] in process?.terminate() }
        watchdog.resume()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        watchdog.cancel()
        process.waitUntilExit()
        // 脚本按子串匹配名称（probe "kimi" 会连 "kimi-intl" 一起测），所以按全名挑，不取第一个
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let provider = payload.providers.first(where: { $0.name == name }) ?? payload.providers.first else {
            return (.unsure, "探测输出解析失败")
        }
        let messages = provider.msgs ?? []
        let verdict = LineAutoProbePolicy.verdict(msgs: messages.map { ($0.level, $0.msg) })
        // 原来只要有消息就当失败展示，[1M] 后缀这种静态提示会把「全部 200」显示成一行黄字
        if verdict == .pass { return (.pass, "✅ 探测通过") }
        let shown = messages.filter { $0.msg.hasPrefix("probe ") }
        return (verdict, (shown.isEmpty ? messages : shown).prefix(2).map { $0.msg }.joined(separator: "；"))
    }

    // MARK: - 存量线路周期实测（第 3 层防线，判定规则见 LineAutoProbePolicy）
    // 静态体检只看配置，看不出「上游挂了」（2026-10-05 静态全绿时 yescode 探测 403）；
    // 只有真实请求能证明线路通。每轮 = 每条线路每个模型一次 max_tokens=8 的请求，按量线路有微小花费。

    @Published var autoProbedAt: Date?
    @Published var autoProbeSummary: String?
    /// 系统通知被关（2026-10-05 实测本机就是：UNErrorDomain Code=1 not allowed）→ 提醒只剩 popover 这一行，UI 要明说
    @Published var notifyBlocked = false
    private var autoProbeTimer: Timer?
    private var autoProbeEnabled = false
    private var autoProbeRunning = false
    static let autoProbeBaselineKey = "lineAutoProbeBaseline"   // [线路名: LineProbeVerdict.rawValue]
    static let autoProbeLastRoundKey = "lineAutoProbeLastRound" // 上一轮留痕，`defaults read com.ccpod.menubar` 可查
    private static let autoProbeAlertPrefix = "自动实测失败："

    func startAutoProbe(initialDelay: TimeInterval, interval: TimeInterval) {
        stopAutoProbe()
        autoProbeEnabled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            self?.runAutoProbe()
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.runAutoProbe()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoProbeTimer = timer
    }

    func stopAutoProbe() {
        autoProbeEnabled = false
        autoProbeTimer?.invalidate()
        autoProbeTimer = nil
    }

    /// 主线程调用。逐条串行测（不并发打网关）；一轮最坏 = 线路数 × 120s 看门狗。
    func runAutoProbe() {
        guard autoProbeEnabled, !autoProbeRunning, let script = Self.resolveScript() else { return }
        autoProbeRunning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var results: [(name: String, verdict: LineProbeVerdict, text: String)] = []
            var failure: String?
            switch Self.fetchStatic(script: script) {
            case .failure(let reason): failure = reason.text
            case .success(let payload):
                for provider in payload.providers {
                    let r = Self.runProbe(name: provider.name, script: script)
                    results.append((provider.name, r.verdict, r.text))
                }
            }
            // 顺带做一轮新模型自动上架（发现 → 直连实测 → 通过才写网关，全程有上限约束）
            let onboardSummary = ModelOnboardService.discoverRound().summary
            DispatchQueue.main.async {
                self?.finishAutoProbe(results, failure: failure)
                if let onboardSummary {
                    self?.autoProbeSummary = [self?.autoProbeSummary, gatewayVisibleText(onboardSummary)]
                        .compactMap { $0 }.joined(separator: "；")
                }
            }
        }
    }

    private func finishAutoProbe(_ results: [(name: String, verdict: LineProbeVerdict, text: String)], failure: String?) {
        autoProbeRunning = false
        autoProbedAt = Date()
        let defaults = UserDefaults.standard
        if let failure {
            // 连线路名单都拿不到 = 体检脚本/网关配置层面的问题，手动体检会显示原因；这里只留痕不提醒
            autoProbeSummary = "自动实测未执行：\(gatewayVisibleText(failure))"
            defaults.set(["at": Date().timeIntervalSince1970, "error": gatewayVisibleText(failure)],
                         forKey: Self.autoProbeLastRoundKey)
            return
        }
        let old = defaults.dictionary(forKey: Self.autoProbeBaselineKey) as? [String: String] ?? [:]
        var baseline: [String: String] = [:]   // 只保留现存线路，删掉的线路不留幽灵基线
        var newlyFailed: [String] = []
        var previouslyPassing = 0
        for r in results {
            let previous = old[r.name].flatMap(LineProbeVerdict.init(rawValue:))
            if previous == .pass { previouslyPassing += 1 }
            if LineAutoProbePolicy.shouldAlert(previous: previous, current: r.verdict) {
                newlyFailed.append(r.name)
                probeResults[r.name] = gatewayVisibleText(Self.autoProbeAlertPrefix + r.text)
            } else if r.verdict == .pass, probeResults[r.name]?.hasPrefix(Self.autoProbeAlertPrefix) == true {
                probeResults[r.name] = nil   // 恢复了就撤掉自己挂的红字（手动测通的结果不碰）
            }
            if let next = LineAutoProbePolicy.nextBaseline(previous: previous, current: r.verdict) {
                baseline[r.name] = next.rawValue
            }
        }
        defaults.set(baseline, forKey: Self.autoProbeBaselineKey)
        let passed = results.filter { $0.verdict == .pass }.count
        autoProbeSummary = "自动实测 \(passed)/\(results.count) 通"
        defaults.set(["at": Date().timeIntervalSince1970,
                      "verdicts": Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0.verdict.rawValue) }),
                      "alerted": newlyFailed],
                     forKey: Self.autoProbeLastRoundKey)
        // 每轮查一次通知权限（只读，不弹授权框），通知渠道断了要在出事之前就让人看见
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let blocked = settings.authorizationStatus == .denied
            UserDefaults.standard.set(settings.authorizationStatus.rawValue, forKey: "lineAutoProbeNotifyStatus") // 1=denied 2=authorized
            DispatchQueue.main.async { self.notifyBlocked = blocked }
        }
        if let alert = LineAutoProbePolicy.alert(newlyFailed: newlyFailed.map(gatewayProviderGroupDisplayName),
                                                 previouslyPassing: previouslyPassing) {
            Self.postNotification(title: alert.title, body: alert.body)
        }
    }

    private static func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            // 没授权就只剩 popover 行内那行字；留痕里记一笔，免得「没收到通知」时无从查起
            UserDefaults.standard.set(granted, forKey: "lineAutoProbeNotifyAuthorized")
            UserDefaults.standard.set(error.map { "\($0)" } ?? "", forKey: "lineAutoProbeNotifyError")
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = gatewayVisibleText(title)
            content.body = gatewayVisibleText(body)
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "line-auto-probe-\(UUID().uuidString)",
                                             content: content, trigger: nil))
        }
    }

    // MARK: - 行内用量（CCR getUsageStats RPC，今日，按 provider 过滤）

    func usage(name: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let text: String
            if let state = CCRConfigService.serviceState() {
                text = (try? CCRConfigService.usageToday(provider: name, state: state)) ?? "用量获取失败"
            } else {
                text = "读不到网关运行信息"
            }
            DispatchQueue.main.async {
                self.usageTexts[name] = gatewayVisibleText(text)
            }
        }
    }
}

/// 跨线程的一次性标志：看门狗在它自己的队列上写，体检线程在 waitUntilExit 之后读
private final class AtomicFlag {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
