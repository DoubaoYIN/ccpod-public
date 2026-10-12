import Foundation
import UserNotifications
import Combine

/// 优惠雷达的调度与 IO 层。策略全在 `PromotionNotifyPolicy` / `PromotionSchedule`（纯函数），
/// 这里只做三件事：定位脚本、按时跑它、把结果落盘并决定发不发通知。
///
/// ⚠️ 硬约束（spec §0.3）：**只提醒**。这个类不许写 `~/.claude/providers/*.json`、
/// 不许调 ccr、不许碰 settings.json。唯一会写的文件是 `~/.claude/ccpod-promotions*.json`。
final class PromotionService: ObservableObject {

    /// 单例。跟 `GatewayLineService.shared` / `BalanceService.shared` 一致：
    /// 情报面板（独立窗口）和 popover 那一行都要读同一份 @Published，
    /// 两处各 new 一个就会出现「面板显示有优惠、菜单栏说没有」。
    static let shared = PromotionService()

    // 开发版（仓库源）在则同步到运行时副本，仓库没了副本照用。
    // 与 LineCheckService.resolveScript() 同一个套路，只是源在本仓而不是实验室仓。
    static let repoScriptPath = NSString(string: "~/Projects/ccpod/scripts/promo-fetch.py").expandingTildeInPath
    static let installedScriptPath = NSString(string: "~/.claude/bin/promo-fetch.py").expandingTildeInPath
    static let repoRulesPath = NSString(string: "~/Projects/ccpod/scripts/promo-rules.json").expandingTildeInPath
    static let installedRulesPath = NSString(string: "~/.claude/bin/promo-rules.json").expandingTildeInPath

    @Published var promotions: [Promotion] = []
    @Published var pages: [PromotionPage] = []
    @Published var lastRunAt: Date?
    @Published var running = false
    /// 系统通知权限被关。必须在 UI 上说出来，否则用户以为「今天没优惠」。
    /// 2026-10-05 实测本机出现过 `UNErrorDomain Code=1 not allowed`。
    @Published var notifyBlocked = false
    /// 为什么这一轮没情报。nil = 正常。
    @Published var unavailable: String?

    private(set) var state = PromotionState.empty
    private var schedulerTimer: Timer?
    private let queue = DispatchQueue(label: "ccpod.promotions", qos: .utility)
    private let runner = PromotionScriptRunner()

    /// 秒级检查一次的调度心跳。真正的判定在 `PromotionSchedule.due`（纯函数、可单测）。
    static let tickInterval: TimeInterval = 60

    // MARK: 脚本定位

    static func resolveScript() -> String? {
        let fm = FileManager.default
        for (repo, installed) in [(repoScriptPath, installedScriptPath),
                                  (repoRulesPath, installedRulesPath)] {
            guard fm.fileExists(atPath: installed) || fm.fileExists(atPath: repo) else { continue }
            if fm.fileExists(atPath: repo) {
                let repoNewer: Bool = {
                    guard let a = try? fm.attributesOfItem(atPath: installed),
                          let installedDate = a[.modificationDate] as? Date,
                          let repoDate = try? fm.attributesOfItem(atPath: repo)[.modificationDate] as? Date
                    else { return true }
                    return repoDate > installedDate
                }()
                if repoNewer {
                    try? fm.removeItem(atPath: installed)
                    try? fm.copyItem(atPath: repo, toPath: installed)
                }
            }
        }
        return fm.fileExists(atPath: installedScriptPath) ? installedScriptPath : nil
    }

    // MARK: 启动 / 停止

    func start(initialDelay: TimeInterval = 8) {
        stop()
        reloadFromDisk()
        refreshNotifyPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            self?.tick()
        }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        schedulerTimer = timer
    }

    func stop() {
        schedulerTimer?.invalidate()
        schedulerTimer = nil
    }

    /// 启动时先把上一轮的结果读回来：不读的话每次重启菜单栏 App 面板都是空的，
    /// 用户会以为「优惠没了」，而其实是程序还没到点跑。
    func reloadFromDisk() {
        state = PromotionStore.loadState()
        let today = PromotionSchedule.dayString(of: Date(), calendar: Self.calendar)
        if let snap = PromotionStore.load() {
            let refreshed = PromotionStore.recomputeStatus(snap.promotions, today: today)
            DispatchQueue.main.async {
                self.promotions = refreshed
                self.pages = snap.pages
            }
        }
    }

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    // MARK: 心跳

    func tick() {
        let now = Date()
        let cal = Self.calendar
        if PromotionSchedule.due(lastRunAt: state.lastRunAt, now: now,
                                 hour: PromotionSchedule.fetchHour,
                                 minute: PromotionSchedule.fetchMinute, calendar: cal) {
            runFetch(manual: false)
        }
        if PromotionSchedule.due(lastRunAt: state.lastSummaryAt, now: now,
                                 hour: PromotionSchedule.summaryHour,
                                 minute: PromotionSchedule.summaryMinute, calendar: cal) {
            sendDailySummary()
        }
    }

    // MARK: 抓取

    /// `manual` = 用户在面板上点了「立即检查」。手动触发不受 21:00 门禁限制，
    /// 但仍然会更新 lastRunAt（否则手动跑完，21:00 又跑一遍，白打一次公网）。
    func runFetch(manual: Bool) {
        guard !running else { return }
        guard let script = Self.resolveScript() else {
            DispatchQueue.main.async {
                self.unavailable = "找不到 promo-fetch.py。请先跑仓库里的 install.sh"
            }
            return
        }
        DispatchQueue.main.async { self.running = true }
        queue.async { [weak self] in
            guard let self else { return }
            // readLines 是 **static** 且要显式传目录（GatewayLineService.swift:204）。
            // 没有无参实例版本 —— 写成 GatewayLineService.shared.readLines() 编译不过。
            // providers 目录走 GatewayLineService.providersDirectory（Task 8 定义）。
            // 🔴 计划 Task 7 原稿写的 `GatewayLineService.providersDirectory` 在 Task 7 时
            //    尚不存在（跨 Task 时序依赖：Task 8 才定义它），Task 7 先内联，Task 8 收编。
            let lines = GatewayLineService.readLines(GatewayLineService.providersDirectory)
            let manifest = PromotionSchedule.buildManifest(lines: lines, state: self.state)
            let now = Date()
            let iso = Self.iso(now)
            defer { DispatchQueue.main.async { self.running = false } }

            guard !manifest.isEmpty else {
                // 一条线路都没配优惠页 ≠ 出错。要说清是「没配」，不能显示成「没优惠」。
                DispatchQueue.main.async {
                    self.unavailable = "还没有线路配置优惠页。在线路管理里填一个公开定价页 URL"
                    self.pages = []
                    self.promotions = []
                }
                self.state.lastRunAt = iso
                try? PromotionStore.saveState(self.state)
                return
            }

            let result = self.runScript(script, manifest: manifest)
            guard result.exitCode == 0 else {
                // 退出码非 0 = 脚本自己坏了（不是网断了）。这两种必须分开说，
                // 否则用户会去查网络，而真正的问题是规则文件读不了。
                let detail = SecretRedactor.redact(result.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    self.unavailable = "抓取脚本异常退出（码 \(result.exitCode)）"
                        + (detail.isEmpty ? "" : "：\(String(detail.prefix(200)))")
                }
                return
            }
            guard let decoded = self.runner.decode(raw: result.stdout) else {
                DispatchQueue.main.async {
                    self.unavailable = "抓取脚本的输出解析不了（不是合法 JSON，或缺字段）"
                }
                return
            }
            guard decoded.schema <= PromotionStore.schemaVersion else {
                // 脚本比 App 新。显式报错，不要静默显示空面板。
                DispatchQueue.main.async {
                    self.unavailable = "抓取脚本输出 schema \(decoded.schema)，"
                        + "本机 App 只认到 \(PromotionStore.schemaVersion)。请重装菜单栏 App"
                }
                return
            }

            let today = PromotionSchedule.dayString(of: now, calendar: Self.calendar)
            var pages: [PromotionPage] = []
            var promos: [Promotion] = []
            for pageResult in decoded.pages {
                pages.append(pageResult.asPage())
                promos.append(contentsOf: pageResult.promotions)
            }
            promos = PromotionStore.recomputeStatus(promos, today: today)

            // 更新指纹（下一轮判 unchanged 用）。存端走 storageKey(fromDecoded:)：
            // p.url 是 decode 时洗过一遍的产物，键必须与查端（buildManifest 的
            // storageKey(fromRaw:)）同键，否则永久 miss（见 PromotionURLContract 契约）。
            for p in pages where p.fingerprint != nil {
                self.state.fingerprints[PromotionURLContract.storageKey(fromDecoded: p.url)] = p.fingerprint
            }
            self.state.lastRunAt = iso

            // 「新活动插队」：只有本轮才出现的 id 才算新。
            let previousIDs = Set(PromotionStore.load()?.promotions.map { $0.id } ?? [])
            let fresh = promos.filter { self.isAlertableNow($0) && !previousIDs.contains($0.id) }

            let snapshot = PromotionSnapshot(schema: PromotionStore.schemaVersion,
                                             updatedAt: iso, promotions: promos, pages: pages)
            do {
                try PromotionStore.save(snapshot)
                try PromotionStore.saveState(self.state)
            } catch {
                DispatchQueue.main.async {
                    self.unavailable = "情报写不进磁盘：\(error.localizedDescription)"
                }
                return
            }

            DispatchQueue.main.async {
                self.unavailable = nil
                self.pages = pages
                self.promotions = promos
                self.lastRunAt = now
            }
            self.refreshNotifyPermission()

            // 插队通知：24h 内同一条不重复弹
            for p in fresh {
                guard PromotionNotifyPolicy.shouldQueueAlert(
                    id: p.id,
                    lastAlertedAt: self.state.lastAlertedAt[p.id].flatMap { Self.parseISO($0) },
                    now: now) else { continue }
                guard let alert = PromotionNotifyPolicy.interruptAlert(for: p, now: now) else { continue }
                self.state.lastAlertedAt[p.id] = iso
                Self.postNotification(title: alert.title, body: alert.body, tag: p.id)
            }
            try? PromotionStore.saveState(self.state)

            if manual {
                DispatchQueue.main.async { self.objectWillChange.send() }
            }
        }
    }

    private func isAlertableNow(_ p: Promotion) -> Bool {
        PromotionNotifyPolicy.isAlertable(p)
    }

    // MARK: 每日汇总

    func sendDailySummary() {
        let now = Date()
        let iso = Self.iso(now)
        guard let digest = PromotionNotifyPolicy.summary(
            promotions: promotions, pages: pages, now: now) else {
            // 没情报也没问题 → 不发。但仍然要记 lastSummaryAt，
            // 否则这一分钟里每次 tick 都会重新算一遍。
            state.lastSummaryAt = iso
            try? PromotionStore.saveState(state)
            return
        }
        state.lastSummaryAt = iso
        try? PromotionStore.saveState(state)
        refreshNotifyPermission()
        Self.postNotification(title: digest.title, body: digest.body, tag: "daily-summary")
    }

    // MARK: 子进程

    struct ScriptResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// 跑 promo-fetch.py。manifest 走 stdin（不走命令行参数：URL 可能很长，
    /// 而且命令行参数在 `ps` 里对同机所有用户可见）。
    private func runScript(_ script: String, manifest: [[String: String]]) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script, "--rules", Self.installedRulesPath]
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        do {
            try process.run()
        } catch {
            return ScriptResult(exitCode: -1, stdout: "",
                                stderr: "启动 python3 失败：\(error.localizedDescription)")
        }
        // 先写 stdin 再等退出。顺序反了会死锁：子进程在等输入，我们在等它退出。
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: []) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ScriptResult(exitCode: process.terminationStatus,
                            stdout: String(data: outData, encoding: .utf8) ?? "",
                            stderr: String(data: errData, encoding: .utf8) ?? "")
    }

    // MARK: 通知

    /// 每轮只读查一次权限，不弹授权框。渠道断了要在出事之前就让人看见。
    func refreshNotifyPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let blocked = settings.authorizationStatus == .denied
            UserDefaults.standard.set(settings.authorizationStatus.rawValue,
                                      forKey: "promotionNotifyStatus")
            DispatchQueue.main.async { self.notifyBlocked = blocked }
        }
    }

    private static func postNotification(title: String, body: String, tag: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            // 没授权就只剩 popover 那一行字。留痕，免得「没收到通知」时无从查起。
            UserDefaults.standard.set(granted, forKey: "promotionNotifyAuthorized")
            UserDefaults.standard.set(error.map { "\($0)" } ?? "", forKey: "promotionNotifyError")
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "promotion-\(tag)-\(UUID().uuidString)",
                                             content: content, trigger: nil))
        }
    }

    // MARK: 时间

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
