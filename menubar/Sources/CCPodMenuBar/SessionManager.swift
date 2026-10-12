import Foundation

struct SessionInfo: Codable {
    let pid: Int
    let tty: String
    var provider: String
    let project: String
    let terminal: String
    let started_at: String
    let num: Int?
    // 发现层补充（登记会话为 nil）：实际在用模型 + 最后活动时间（来自会话 jsonl）
    var model: String?
    var lastActive: Date?

    var sessionNumber: Int { num ?? 0 }

    var projectName: String {
        (project as NSString).lastPathComponent
    }

    var isAlive: Bool {
        kill(pid_t(pid), 0) == 0
    }

    /// 有没有真实终端：登记表写不出 tty 时给 "unknown"，发现层拿 ps 的 `??`（无 TTY）或 `?`（取不到）。
    /// 只有 true 的行才有窗口可以切过去。
    var hasTerminal: Bool {
        !(tty.isEmpty || tty == "??" || tty == "?" || tty == "unknown")
    }

    // ccgo bash 的直接父进程正常是 zsh/login；终端窗口被关、shell 退出后，
    // ccgo 会被 launchd（pid=1）收养。直接 ppid==1 即孤儿。
    // 注意：不能爬整条 PPID 链——Ghostty 这类 GUI 进程自身的 ppid 也是 1。
    var isOrphan: Bool {
        guard isAlive else { return false }
        return SessionInfo.directPPID(of: pid_t(pid)) == 1
    }

    private static func directPPID(of pid: pid_t) -> pid_t {
        procInfo(of: pid)?.ppid ?? -1
    }

    /// 进程组号。ccgo 包装进程是组长（pgid == 自己的 pid），它启动的 claude 是同组子进程。
    static func processGroup(of pid: pid_t) -> pid_t? {
        procInfo(of: pid)?.pgid
    }

    /// claude 原生写的 pid→sessionId 映射（`~/.claude/sessions/<claude进程pid>.json`）。
    /// 注意 key 是 **claude 进程**的 pid，不是 ccgo 包装进程的 pid。
    static func claudeSessionID(pid: Int) -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else {
            return nil
        }
        return sessionID
    }

    /// session-hud 双源合成（与 ~/.claude/bin/hud CLI 同一规则）：
    /// 源A = ~/.claude/sessions/<claudePid>.json 的 status/updatedAt（CC 原生，秒级实时）；
    /// 源B = /tmp/claude-tab-state/<tty小名>.json 的 state/task/tool/titleTs（一期 hook 写）。
    /// 卡死 = busy 且两源最后活动都超过 10 分钟。超长工具会误报——⚠️ 是警示不是判决。
    static func hudState(claudePid: Int, tty: String) -> SessionHudState? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var ccStatus = ""
        var ccUpdated: Double = 0
        var sessionStart: Double = 0
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude/sessions/\(claudePid).json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            ccStatus = obj["status"] as? String ?? ""
            ccUpdated = (obj["updatedAt"] as? Double ?? 0) / 1000
            sessionStart = (obj["startedAt"] as? Double ?? 0) / 1000
        }
        var state = "", task = "", tool = ""
        var titleTs: Double = 0
        // 登记表存的是全路径 /dev/ttys00X，hook 文件按小名 ttys00X 归档——取小名再拼路径。
        let ttyName = (tty as NSString).lastPathComponent
        if !ttyName.isEmpty, ttyName != "??",
           let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/claude-tab-state/\(ttyName).json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // 护栏：条子最后写入早于本会话启动 = 同一 tty 上个会话的残留，不采信
            // （死人不留新条子；sessionStart 缺失时按 0 处理 = 老版本 CC 不加护栏）。
            // +5s 容差：SessionStart hook 落盘可能略早于 pid-file 注册（启动竞态，实测亚秒级），
            // 没有它会把本会话自己的第一张条子误判成残留。
            let hookTs = max(obj["ts"] as? Double ?? 0, obj["titleTs"] as? Double ?? 0)
            if sessionStart == 0 || hookTs + 5 >= sessionStart {
                state = obj["state"] as? String ?? ""
                task = obj["task"] as? String ?? ""
                tool = obj["tool"] as? String ?? ""
                titleTs = obj["titleTs"] as? Double ?? 0
            }
        }
        guard !state.isEmpty || !ccStatus.isEmpty else { return nil }
        let glyph: String
        switch state {
        // start = 刚开会话停在输入框，与终端标题（session-hud v3）一致算等输入
        case "idle", "start": glyph = "⏸"
        case "notify": glyph = "🔔"
        case "work": glyph = "●"
        // waiting = 停下等用户（权限确认/对话框/输入，claude.exe $Gm 取证）→ 与 hook 的 notify 同义
        default: glyph = ccStatus == "busy" ? "●" : (ccStatus == "waiting" ? "🔔" : (ccStatus == "idle" ? "⏸" : "❓"))
        }
        let lastTs = max(titleTs, ccUpdated)
        let isStuck = ccStatus == "busy" && Date().timeIntervalSince1970 - lastTs > 600
        return SessionHudState(glyph: isStuck ? "⚠️" : glyph, task: task, tool: tool,
                               lastTs: Date(timeIntervalSince1970: lastTs), isStuck: isStuck)
    }

    /// session-hud hook 给这条 tty 的分屏写的标题（`/tmp/claude-tab-state/<tty小名>.json` 的 `title`）。
    /// Ghostty 的分屏没有 tty 属性，切窗口只能拿这个名字去对。路径规则与 `hudState` 同一处维护（PITFALLS #39）。
    static func hookTitle(tty: String) -> String? {
        let ttyName = (tty as NSString).lastPathComponent
        guard !ttyName.isEmpty, ttyName != "??",
              let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/claude-tab-state/\(ttyName).json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = obj["title"] as? String, !title.isEmpty else { return nil }
        return title
    }

    private static func procInfo(of pid: pid_t) -> (ppid: pid_t, pgid: pid_t)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let r = mib.withUnsafeMutableBufferPointer { buf -> Int32 in
            sysctl(buf.baseAddress, u_int(buf.count), &info, &size, nil, 0)
        }
        if r != 0 || size == 0 { return nil }
        return (info.kp_eproc.e_ppid, info.kp_eproc.e_pgid)
    }
}

extension SessionManager {
    func nextSessionNumber() -> Int {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let counterURL = home
            .appendingPathComponent(".claude")
            .appendingPathComponent("ccpod-session-counter")
        var counter = 0
        if let str = try? String(contentsOf: counterURL, encoding: .utf8),
           let val = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
            counter = val
        }
        return counter + 1
    }
}

/// 会话 HUD 一行数据（session-hud 项目）：/tmp/claude-tab-state/<tty>.json（hook 写的
/// task/tool/state/titleTs）+ ~/.claude/sessions/<pid>.json 的原生 status/updatedAt 合成。
struct SessionHudState {
    let glyph: String      // 终端字符：● 工作 / ⏸ 等输入 / 🔔 需确认 / ⚠️ 疑似卡死 / ❓ 不明
    let task: String
    let tool: String       // 空串 = 无工具信息
    let lastTs: Date       // 双源取 max 的最后活动时间
    let isStuck: Bool      // busy 且静默超 10 分钟（与 hud CLI 同一规则）
}

/// 主线程读的**不可变快照**。轮询在 stateQueue 上算完再整体抛过来，UI 永不与后台队列
/// 共享可变容器。早先是后台并发队列写 Array/Dictionary、主线程裸读同一份 —— Swift 容器
/// 不允许一边写一边读，撞上就是 EXC_BAD_ACCESS（菜单栏无预兆重启），一直没崩只是运气。
struct SessionSnapshot {
    /// 登记表里的会话（ccpod 启动 / 已收编）
    var registered: [SessionInfo] = []
    /// 会话卡要显示的全部行（登记 + 发现，已按 pid 去重：SwiftUI 的 ForEach 用 pid 当 id，
    /// 重复 id 行为未定义）
    var rows: [SessionInfo] = []
    /// pid → 对话标题
    var titles: [Int: String] = [:]
    /// pid → claude 会话 id（重命名要用；来自 ~/.claude/sessions/<claude真身pid>.json）
    var sessionIDs: [Int: String] = [:]
    /// pid → 会话 HUD 状态（session-hud；登记行与发现行都有）
    var hud: [Int: SessionHudState] = [:]
    /// 登记表读/解析异常；非 nil 必须在 UI 里说出来，别让用户对着空列表猜
    var warning: String?
}

final class SessionManager {
    /// 所有可变状态只在这个串行队列上读写（含 ps/lsof 子进程与读 jsonl 这些重活）。
    /// 主线程只读 `snapshot`，所以**永远不会被轮询阻塞**。
    private let stateQueue = DispatchQueue(label: "ccpod.session-manager")

    /// 只在主线程读写
    private(set) var snapshot = SessionSnapshot()

    var onChange: (() -> Void)?

    // ── 以下状态一律只在 stateQueue 上访问 ──
    private var registered: [SessionInfo] = []
    /// 非 ccpod 启动的存活 claude 进程（直接运行 claude / claude -r），只读展示
    private var discovered: [SessionInfo] = []
    private var titlesByPid: [Int: String] = [:]
    private var sessionIDsByPid: [Int: String] = [:]
    private var hudByPid: [Int: SessionHudState] = [:]
    private var registryError: String?
    /// 本轮判定该从登记表里删掉的 pid（死进程 / 重复收编行 / 无终端后台进程）。
    /// 写回时只删这些、其余以磁盘为准 —— 见 `updateRegistryFile` 的并发说明。
    private var stalePids: Set<Int> = []

    private let sessionsURL: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var cleanupTimer: DispatchSourceTimer?
    private var lastSessionFingerprint: String = ""

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsURL = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("ccpod-sessions.json")
    }

    func start() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.reloadLocked()
            // 先抛一份"只有登记表"的快照：重发现（每会话 2×ps+lsof，外加首轮对无标题会话
            // 逐段放大回扫 jsonl）可能要一秒以上，否则启动后立刻打开弹窗会先闪一下
            // "没有存活的 claude 进程"——正是被投诉过两次的那个空态
            self.publishLocked(notify: true)
            self.discoverProcesses()
            self.lastSessionFingerprint = self.sessionFingerprint(self.allSessionsLocked())
            self.watchFile()
            self.startCleanupTimer()
            // 必须 notify：start() 是 async 的，调用方紧接着的 refreshVM() 读到的还是空快照，
            // 不通知一次的话首屏会一直空着，要等 5s 后指纹变化才刷新
            self.publishLocked(notify: true)
        }
    }

    func stop() {
        // async 而非 sync：sync 是排队屏障，会等完整轮轮询（每会话 2×ps+lsof + 读 jsonl），
        // 退出时就是几百毫秒到数秒的卡死感；与"锁被卡住"叠加时更糟。
        // 进程马上就退，DispatchSource 与 fd 由系统回收，不依赖这里跑完。
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.fileSource?.cancel()
            self.fileSource = nil
            self.dirSource?.cancel()
            self.dirSource = nil
            self.cleanupTimer?.cancel()
            self.cleanupTimer = nil
            // 不在这里 close(fd)：关闭由各 source 的 cancel handler 负责（它们捕获了自己那个 fd），
            // 这里再关一次就是 double close，可能关掉别的模块刚拿到的同号 fd
            self.fd = -1
        }
    }

    /// 任意线程可调：异步刷一次状态，刷完通过 onChange 通知 UI 重读快照。
    /// **不用 stateQueue.sync** —— sync 是排队屏障，主线程会等完整轮轮询跑完
    /// （每会话 2×ps + 1×lsof，再加 jsonl 尾窗读取，几百毫秒起步），撞上就是一次可感知的卡顿；
    /// 与"锁被别的进程卡住"叠加时更会变成永久冻住。doClose 要的"那一行立刻消失"由 notify 保证。
    func reload() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.reloadLocked()
            self.publishLocked(notify: true)
        }
    }

    /// 任意线程可调：立刻跑一轮完整发现（不等 5s 定时器）。改名成功后用，
    /// 让新标题马上出现，而不是让用户盯着旧标题猜"到底成没成"。
    func refreshNow() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.reloadLocked()
            self.discoverProcesses()
            self.publishLocked(notify: true)
        }
    }

    /// 任意线程可调：把一条已不代表真实会话的登记行清掉（进程退出后 pid 被别的进程捡走的场景）。
    /// 走与轮询同一把锁 + 以磁盘为基准合并，所以不会顺手抹掉 ccgo 刚登记的行。
    func dropStaleRow(pid: Int) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.registered.removeAll { $0.pid == pid }
            self.stalePids.insert(pid)
            _ = self.withRegistryLock { self.mergeRegistryLocked() }
            self.publishLocked(notify: true)
        }
    }

    /// 只在 stateQueue 上调用：算好快照抛到主线程
    private func publishLocked(notify: Bool) {
        let snap = makeSnapshotLocked()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = snap
            if notify { self.onChange?() }
        }
    }

    private func makeSnapshotLocked() -> SessionSnapshot {
        var seen = Set<Int>()
        return SessionSnapshot(
            registered: registered,
            rows: allSessionsLocked().filter { seen.insert($0.pid).inserted },
            titles: titlesByPid,
            sessionIDs: sessionIDsByPid,
            hud: hudByPid,
            warning: registryError
        )
    }

    private func allSessionsLocked() -> [SessionInfo] {
        let pids = Set(registered.map { $0.pid })
        return registered + discovered.filter { !pids.contains($0.pid) }
    }

    /// 只在 stateQueue 上调用
    private func reloadLocked() {
        guard let data = try? Data(contentsOf: sessionsURL) else {
            registryError = FileManager.default.fileExists(atPath: sessionsURL.path)
                ? "登记表读不出来（保留内存中 \(registered.count) 行，不写回）" : nil
            return
        }
        guard let decoded = try? JSONDecoder().decode([SessionInfo].self, from: data) else {
            registryError = "登记表解析失败（保留内存中 \(registered.count) 行，不写回）"
            return
        }
        registryError = nil
        let alive = decoded.filter { $0.isAlive }
        let kept = pruneAdopted(alive)
        // 记下本轮该从磁盘删掉的 pid：写回时只删这些，其余一律以磁盘为准（见 updateRegistryFile）
        stalePids = Set(decoded.map { $0.pid }).subtracting(kept.map { $0.pid })
        registered = kept
    }

    /// 自愈：把不该进登记表的收编条目清出去，让"登记号"只对应真实对话。两种脏数据
    /// （都是早期版本留下的存量，新逻辑只防新增、不清旧账，所以每次读表都过一遍）：
    /// 1. ccgo 包装进程的 claude 子进程被当成"直接启动"收编 → 同一个对话占两行
    ///    （保留 terminal != "adopted" 的登记行，丢掉与它同进程组的收编行）
    /// 2. 无 TTY 的后台进程（子 agent / 脚本里的 claude -p）被收编 → 白烧永久登记号
    ///    （它们仍会由发现层以「后台」只读行展示，不会消失）
    /// 清理结果由 cleanupAndNotify 的计数比对写回文件。
    private func pruneAdopted(_ list: [SessionInfo]) -> [SessionInfo] {
        let launcherPids = Set(list.filter { $0.terminal != "adopted" }.map { pid_t($0.pid) })
        return list.filter { session in
            guard session.terminal == "adopted" else { return true }
            if session.tty == "??" || session.tty.isEmpty { return false }
            guard !launcherPids.isEmpty,
                  let group = SessionInfo.processGroup(of: pid_t(session.pid)) else { return true }
            return !launcherPids.contains(group)
        }
    }

    /// 指纹要带上模型与标题：快照改成"算好再抛主线程"之后，只有指纹变了才会通知 UI 刷新，
    /// 否则会话里 /model 切换、标题生成这些变化都不会反映到界面上。
    /// 不含 lastActive（活跃会话每轮都在变，会让 UI 每 5s 无谓刷新；相对时间 SwiftUI 自己会走）。
    private func sessionFingerprint(_ sessions: [SessionInfo]) -> String {
        sessions
            .map { "\($0.pid)|\($0.provider)|\($0.project)|\($0.tty)|\($0.model ?? "")|\(titlesByPid[$0.pid] ?? "")" }
            .sorted()
            .joined(separator: "\n")
    }

    // MARK: - 进程发现：扫描所有存活的 claude 进程（登记表 pid 去重）

    // 会话标题（titlesByPid）不写进 SessionInfo／登记表：标题会被 Claude 重新生成，
    // 每轮按 mtime 缓存重取即可。

    /// 只在 stateQueue 上调用
    private func discoverProcesses() {
        let own = Int(getpid())
        let claudePids = Self.listClaudePids().filter { Int($0) != own }
        // 进程组 → 组里那个 claude 进程。ccgo 包装进程是组长，登记在案的却是包装进程的 pid，
        // 真身是同组的 claude 子进程；要拿它的 pid 才能查到 sessionId。
        var groupToClaude: [pid_t: pid_t] = [:]
        for pid in claudePids {
            guard let group = SessionInfo.processGroup(of: pid) else { continue }
            // 同组里可能有多个 claude 前缀进程（子 agent 也是独立的 claude 进程）。
            // 认"有 pid→sessionId 映射"的那个——那才是交互会话本体；并列时取 pid 小的（先启动的）。
            // 随便挑一个会让这一行显示别的对话的标题和模型。
            let mapped = SessionInfo.claudeSessionID(pid: Int(pid)) != nil
            if let existing = groupToClaude[group] {
                let existingMapped = SessionInfo.claudeSessionID(pid: Int(existing)) != nil
                if (mapped && !existingMapped) || (mapped == existingMapped && pid < existing) {
                    groupToClaude[group] = pid
                }
            } else {
                groupToClaude[group] = pid
            }
        }
        let registeredPids = Set(registered.map { $0.pid })
        // 同一进程组只算一个对话：不按进程组去重，同一个对话会出现两行——登记行 +
        // 被子进程冒充的"直接启动"收编行（实测 4 个对话显示了 7 行）。
        let registeredGroups = Set(registered.compactMap { SessionInfo.processGroup(of: pid_t($0.pid)) })
        var newTitles: [Int: String] = [:]
        var newSessionIDs: [Int: String] = [:]
        var newHud: [Int: SessionHudState] = [:]
        var resolvedPids: Set<Int> = []
        discovered = claudePids
            .filter { pid in
                let p = Int(pid)
                guard !registeredPids.contains(p) else { return false }
                if let group = SessionInfo.processGroup(of: pid), registeredGroups.contains(group) {
                    return false
                }
                return true
            }
            .compactMap { Self.describe(pid: $0) }
            .map { info in
                var info = info
                // 真实在用模型 = 该对话 jsonl 的尾部记录（env 只是启动时默认，会话内 /model 切换后 env 不变）
                if let detail = resolveSessionDetail(project: info.project, pid: info.pid) {
                    resolvedPids.insert(info.pid)
                    if !detail.model.isEmpty {
                        info.model = detail.model
                        info.lastActive = detail.lastActive
                        if detail.model.contains("/") {
                            info.provider = String(detail.model.prefix(while: { $0 != "/" }))
                        }
                    }
                    if let title = detail.title { newTitles[info.pid] = title }
                }
                if let sid = SessionInfo.claudeSessionID(pid: info.pid) { newSessionIDs[info.pid] = sid }
                if let hud = SessionInfo.hudState(claudePid: info.pid, tty: info.tty) { newHud[info.pid] = hud }
                return info
            }
        // ccpod 启动的登记会话同样补标题/模型，让每一行都能和 claude --resume 列表对上。
        // 用同组的 claude 子进程 pid 去查（登记表里存的是包装进程 pid，它没有 sessionId 映射）。
        for session in registered {
            let claudePid = groupToClaude[pid_t(session.pid)].map { Int($0) } ?? session.pid
            guard let detail = resolveSessionDetail(project: session.project, pid: claudePid) else { continue }
            resolvedPids.insert(claudePid)
            if let title = detail.title { newTitles[session.pid] = title }
            if let sid = SessionInfo.claudeSessionID(pid: claudePid) { newSessionIDs[session.pid] = sid }
            if let hud = SessionInfo.hudState(claudePid: claudePid, tty: session.tty) { newHud[session.pid] = hud }
        }
        titlesByPid = newTitles
        sessionIDsByPid = newSessionIDs
        hudByPid = newHud

        // 清掉已退出进程的缓存，菜单栏常驻运行否则会无界增长
        detailCache = detailCache.filter { resolvedPids.contains($0.key) }
        let livePaths = Set(detailCache.values.map { $0.path })
        noTitleScannedSize = noTitleScannedSize.filter { livePaths.contains($0.key) }
    }

    /// 上一轮已见过的收编候选 pid。登记号是永久的，不能被短命进程烧掉
    /// （实测：两个后台子 agent 在 8 分钟内烧掉 6 个号，登记表却始终是 4 行）。
    private var adoptionCandidates: Set<Int> = []

    /// 收编：给直接启动的会话分配登记号并写入登记表，使其获得完整外观与
    /// 可用管理（关闭 / 新窗口继承切线）。自动批准依赖启动时环境变量，收编会话不可用。
    private func adoptDiscovered() {
        // 无 TTY 的不是"用户的对话"，是别的会话的后台工人（子 agent / SDK / 脚本里的
        // claude -p）：只展示、永不收编。真有终端的也要连续两轮都在才收编，
        // 这样一次性 claude -p 不会占用登记号。
        let candidates = discovered.filter { $0.tty != "??" && !$0.tty.isEmpty }
        let seen = Set(candidates.map { $0.pid })
        let toAdopt = candidates.filter { adoptionCandidates.contains($0.pid) }
        adoptionCandidates = seen
        guard !toAdopt.isEmpty else { return }

        // 分配登记号 + 写登记表必须在**同一个 flock 临界区**内完成，而且要用 ccgo 那把锁
        // （scripts/lib/common.sh 的 register_session 锁的就是 ccpod-session-counter.lock）。
        // 早先菜单栏不拿锁、还按内存快照整份覆盖：ccgo 恰好在 discoverProcesses 跑子进程的
        // 那几十~几百毫秒里登记了会话，就会被抹掉 —— 表现为会话身份在"登记/直接启动/已收编"
        // 之间跳变、编号重分配。
        var newEntries: [SessionInfo] = []
        // 顺序很重要：**先把行写进登记表，成功了才推进计数器**。反过来的话，一旦登记表这轮拒写
        // （磁盘读不出），计数器已经前进 → 白烧一个永久号，而且内存里那行下轮会被磁盘覆盖丢掉，
        // 该会话就会"已收编→直接启动→再收编+1"跳变。
        let merged = withRegistryLock { () -> Bool in
            // 计数器读不出就本轮不收编：宁可晚一轮，也不铸出重复登记号
            guard var counter = readCounter() else { return false }
            // 双保险：即使计数器落后于表内实际号，也不发出已存在的号
            counter = max(counter, registered.compactMap { $0.num }.max() ?? 0)
            for info in toAdopt {
                counter += 1
                newEntries.append(SessionInfo(pid: info.pid, tty: info.tty, provider: info.provider,
                                              project: info.project, terminal: "adopted",
                                              started_at: info.started_at, num: counter,
                                              model: info.model, lastActive: info.lastActive))
            }
            guard mergeRegistryLocked(adding: newEntries) else { return false }
            writeCounter(counter)
            return true
        } ?? false
        guard merged else { return }
        registered.append(contentsOf: newEntries)
        // 只摘掉已收编的；后台进程和"才见到第一轮"的候选要留在 discovered 里继续展示，
        // 否则它们会消失一轮（5s）再冒出来，看起来像闪退
        let adoptedPids = Set(newEntries.map { $0.pid })
        discovered.removeAll { adoptedPids.contains($0.pid) }
    }

    // MARK: - 登记表读写（与 ccgo 共用一把 flock）

    private var counterURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ccpod-session-counter")
    }

    /// ccgo 锁的是 `<counter>.lock`（scripts/lib/common.sh 里的 `counter_path + ".lock"`）。
    /// 这里必须用同一路径，否则两边各锁各的等于没锁。
    /// ⚠️ 不可嵌套调用：flock 按 fd 计，同线程拿两个 fd 会自己等自己。
    /// 返回 nil = 没拿到锁、本轮没执行 body（调用方要能容忍"这轮不写"）。
    private func withRegistryLock<T>(_ body: () -> T) -> T? {
        let lockFD = open(counterURL.path + ".lock", O_RDWR | O_CREAT | O_APPEND, 0o600)
        // 连锁文件都开不了：退化成无锁写（与改造前同级，不会更糟）
        guard lockFD >= 0 else { return body() }
        // **绝不无限等锁**：持锁进程卡住时（ccgo 被 SIGSTOP、python 卡死），无限 flock 会冻住
        // stateQueue；主线程一旦有 sync 进这个队列就跟着冻 → 整个菜单栏 beachball 且无法退出。
        // 有界重试约 2s，拿不到就放弃本轮（5s 后下一轮再试），登记表最坏晚一轮收敛。
        var acquired = false
        for _ in 0..<20 {
            if flock(lockFD, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
            usleep(100_000)
        }
        guard acquired else { close(lockFD); return nil }
        let result = body()
        flock(lockFD, LOCK_UN)
        close(lockFD)
        return result
    }

    /// 返回 nil = 计数器文件存在但读不出/内容损坏。这种情况下**不能当成 0**：
    /// 那会铸出表里已有的登记号（界面出现两个 #1，而按号索引的状态会串），
    /// 且 ccgo 侧对同样情形是报错拒绝的（common.sh 的 read_counter）。
    private func readCounter() -> Int? {
        guard let text = try? String(contentsOf: counterURL, encoding: .utf8) else {
            return FileManager.default.fileExists(atPath: counterURL.path) ? nil : 0
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return Int(trimmed)
    }

    private func writeCounter(_ value: Int) {
        try? "\(value)".write(to: counterURL, atomically: true, encoding: .utf8)
    }

    /// 只在 flock 临界区内调用：**以磁盘为基准**合并写回——只删 stalePids、只加 adding，
    /// 其余一律保留。用内存快照整份覆盖正是丢写的根源。
    /// 返回 false = 这轮没写成（调用方据此决定是否推进计数器等后续动作）
    @discardableResult
    private func mergeRegistryLocked(adding: [SessionInfo] = []) -> Bool {
        guard let onDiskOrNone = readRegistryFromDisk() else {
            // 磁盘上读不出来（损坏 / 瞬时 IO 错误 / 文件还不存在）。
            // 文件已存在却读不出来时**绝不写**：拿内存快照覆盖正是"清空登记表"那个老毛病，
            // 宁可这一轮不写，等下一轮读得到再说。
            if FileManager.default.fileExists(atPath: sessionsURL.path) { return false }
            var fresh = registered
            let have = Set(fresh.map { $0.pid })
            fresh.append(contentsOf: adding.filter { !have.contains($0.pid) })
            return writeRegistryAtomic(fresh)
        }
        var onDisk = onDiskOrNone
        if !stalePids.isEmpty {
            onDisk.removeAll { stalePids.contains($0.pid) }
            stalePids = []
        }
        let have = Set(onDisk.map { $0.pid })
        onDisk.append(contentsOf: adding.filter { !have.contains($0.pid) })
        return writeRegistryAtomic(onDisk)
    }

    /// 原子写：先写同目录临时文件再 rename，避免读到半截 JSON
    @discardableResult
    private func writeRegistryAtomic(_ list: [SessionInfo]) -> Bool {
        guard let data = try? JSONEncoder().encode(list) else { return false }
        let tmp = sessionsURL.deletingLastPathComponent()
            .appendingPathComponent("ccpod-sessions.tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.moveItem(at: tmp, to: sessionsURL)
            return true
        } catch {
            do {
                try data.write(to: sessionsURL, options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }

    private func readRegistryFromDisk() -> [SessionInfo]? {
        guard let data = try? Data(contentsOf: sessionsURL),
              let decoded = try? JSONDecoder().decode([SessionInfo].self, from: data) else { return nil }
        return decoded
    }

    // jsonl mtime 未变则走缓存，避免 5s 轮询反复读大文件
    private var detailCache: [Int: (mtime: Date, path: String, model: String, lastActive: Date, title: String?)] = [:]
    /// 已整文件回扫过、确认没有 ai-title 的 jsonl（key = 路径，value = 当时文件大小）
    private var noTitleScannedSize: [String: Int] = [:]

    private func resolveSessionDetail(project: String, pid: Int) -> (model: String, lastActive: Date, title: String?)? {
        let fm = FileManager.default
        // Claude Code 的项目目录 slug 把 / . _ 空格 一律换成 "-"（实证：~/.claude/projects 下
        // 0 个目录含 "." 或 "_"，而 /Users/yourname/Projects/demo_project 对应
        // -Users-matthew-Projects-demo-project）。只换 "/" 会让带下划线/点号的项目
        // 查不到 jsonl——模型与标题会静默变成空。
        let slug = project
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        // 优先用 claude 原生写的 pid→sessionId 映射，精确定位"这一个对话"的 jsonl。
        // 只按"项目目录下 mtime 最新的那个"会让同项目并开的两个会话显示同一个标题/模型/
        // 活动时间（A 活跃时 A 的 jsonl 恒为最新，B 行就成了 A 的镜像）。
        var target: URL?
        if let sessionID = SessionInfo.claudeSessionID(pid: pid) {
            let exact = dir.appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: exact.path) { target = exact }
        }
        if target == nil {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                return nil
            }
            target = entries.filter { $0.pathExtension == "jsonl" }.max(by: { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            })
        }
        guard let file = target,
              let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return nil
        }
        if let cached = detailCache[pid], cached.mtime == mtime, cached.path == file.path {
            return (cached.model, cached.lastActive, cached.title)
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // 模型名每条 assistant 记录里都有，小窗口就够；会话标题（ai-title）是全文散点写入的
        // （实测 31MB 的会话只有 122 条，平均 256KB 一条），尾部小窗口经常抓不到，所以按
        // 64K → 1M → 8M 逐段放大回扫。claude-rename 改名时会把全文所有 ai-title 写成同一个
        // 标题，所以"最后一条"就是当前标题。
        var model = ""
        var title: String?
        // 负缓存：整文件回扫过一遍仍无 ai-title 的会话，之后只看 64K 尾窗。
        // 否则活跃会话每 5s 轮询都要把大文件整个重读一遍（实测 1MB 的无标题会话就 escal 到 8M 窗）。
        // 这样安全是因为 ai-title 随会话推进不断追加，一旦生成必落在尾部窗口里。
        // 但文件又长出 1MB 以上时要再回扫一次：ai-title 的间隔实测可达 256KB
        // （31MB 的会话里只有 122 条），只看 64K 尾窗可能迟迟等不到刚生成的标题。
        let escalate = (noTitleScannedSize[file.path]).map { size - $0 > 1_048_576 } ?? true
        for window in [65_536, 1_048_576, 8_388_608] where window == 65_536 || escalate {
            guard let text = Self.readTail(of: file, size: size, window: window) else { break }
            // "<synthetic>" 是 Claude Code 给合成消息写的占位模型名，不是真模型
            if model.isEmpty {
                model = Self.lastString(forKey: "\"model\":\"", in: text, rejecting: ["<synthetic>"]) ?? ""
            }
            if title == nil { title = Self.lastTitle(in: text) }
            if title != nil || window >= size { break }
        }
        if title != nil {
            noTitleScannedSize.removeValue(forKey: file.path)
        } else if escalate {
            // 只有真做了整文件回扫才推进基线；否则每轮刷新会让"长出 1MB 再扫"永远不触发
            noTitleScannedSize[file.path] = size
        }
        detailCache[pid] = (mtime, file.path, model, mtime, title)
        return (model, mtime, title)
    }

    /// 读文件尾部 window 字节，并丢掉可能从行中间起头的第一段残行。
    /// 解码必须用 String(decoding:as:)：窗口起点常落在中文的多字节序列中间，
    /// 而 String(data:encoding:.utf8) 遇到这种情况会**整块返回 nil**
    /// （实测 demo_project 那个会话因此模型和标题全取不到）。
    private static func readTail(of file: URL, size: Int, window: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        if size > window { try? handle.seek(toOffset: UInt64(size - window)) }
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        guard let newline = text.firstIndex(of: "\n") else { return text }
        return String(text[text.index(after: newline)...])
    }

    /// 会话标题。Claude Code 有两种标题记录，显示优先级 **customTitle > aiTitle**
    /// （取自 CLI 二进制里的 `agentName || customTitle || aiTitle || summary || firstPrompt`）：
    ///   `{"type":"custom-title","customTitle":"…","sessionId":"…"}` ← 用户/工具设定
    ///   `{"type":"ai-title","aiTitle":"…","sessionId":"…"}`         ← Claude 自动生成
    /// 只认这两种记录**所在的那一行**，不能全文搜 key——会话正文里出现这个词就会被
    /// 误当成标题（实测：一个 grep 过 aiTitle 的会话正文里有 18 处，全文搜必错）。
    private static func lastTitle(in text: String) -> String? {
        recordValue(type: "custom-title", key: "customTitle", in: text)
            ?? recordValue(type: "ai-title", key: "aiTitle", in: text)
    }

    /// 取最后一条 `{"type":"<type>", … "<key>":"<value>" …}` 记录的值（同一行内查找）。
    private static func recordValue(type: String, key: String, in text: String) -> String? {
        let marker = "\"type\":\"\(type)\""
        var upper = text.endIndex
        while let typeRange = text.range(of: marker, options: [.backwards], range: text.startIndex..<upper) {
            let head = text[text.startIndex..<typeRange.lowerBound]
            let lineStart = head.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let lineEnd = text.range(of: "\n", range: typeRange.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
            let line = String(text[lineStart..<lineEnd])
            if let keyRange = line.range(of: "\"\(key)\":\""),
               let value = jsonString(at: keyRange.upperBound, in: line) {
                return value
            }
            upper = typeRange.lowerBound
        }
        return nil
    }

    /// 取 text 里最后一次出现的 `"key":"value"`；rejecting 里的取值跳过、继续往前找。
    private static func lastString(forKey key: String, in text: String, rejecting: Set<String> = []) -> String? {
        var upper = text.endIndex
        while let keyRange = text.range(of: key, options: [.backwards], range: text.startIndex..<upper) {
            if let value = jsonString(at: keyRange.upperBound, in: text), !rejecting.contains(value) {
                return value
            }
            upper = keyRange.lowerBound
        }
        return nil
    }

    /// 从 start（紧跟开引号之后）按 JSON 规则读一个字符串值，反转义并 trim。
    /// 标题可能含中文、引号、\uXXXX；claude-rename 等长改写时用空格补齐，故必须 trim。
    private static func jsonString(at start: String.Index, in text: String) -> String? {
        var idx = start
        var out = ""
        var escaped = false
        while idx < text.endIndex {
            let c = text[idx]
            if escaped {
                escaped = false
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "u":
                    let from = text.index(after: idx)
                    if let to = text.index(from, offsetBy: 4, limitedBy: text.endIndex),
                       let code = UInt32(text[from..<to], radix: 16),
                       let scalar = Unicode.Scalar(code) {
                        out.append(Character(scalar))
                        idx = to
                        continue
                    }
                    out.append("u")
                default: out.append(c)
                }
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                break
            } else {
                out.append(c)
            }
            idx = text.index(after: idx)
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func listClaudePids() -> [pid_t] {
        // macOS 坑：3 元素 mib + nil 缓冲探测会 ENOENT；必须预分配缓冲循环 ENOMEM。
        // 进程真名是 "claude.exe"（node CLI 被改名），用前缀匹配。
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 1 << 16
        var buf = [kinfo_proc]()
        var ok = false
        for _ in 0..<8 {
            buf = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            var sz = size
            if sysctl(&mib, 3, &buf, &sz, nil, 0) == 0 {
                size = sz
                ok = true
                break
            }
            guard errno == ENOMEM else { return [] }
            size *= 2
        }
        guard ok else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var result: [pid_t] = []
        for i in 0..<count where buf[i].kp_proc.p_pid > 0 {
            let name = withUnsafeBytes(of: buf[i].kp_proc.p_comm) { b -> String in
                let end = b.firstIndex(of: 0) ?? b.count
                return String(decoding: b[..<end], as: UTF8.self)
            }
            if name.hasPrefix("claude") { result.append(buf[i].kp_proc.p_pid) }
        }
        return result
    }

    private static func describe(pid: pid_t) -> SessionInfo? {
        // 活性：kill(pid, 0) 由 SessionInfo.isAlive 兜底；此处取 tty/启动时间/项目目录/线路
        guard let meta = runTool("/bin/ps", ["-o", "tty=", "-o", "lstart=", "-p", String(pid)])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !meta.isEmpty else { return nil }
        let metaParts = meta.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tty = metaParts.first ?? "?"
        let startedAt = metaParts.dropFirst().joined(separator: " ")

        var provider = "—"
        if let envLine = runTool("/bin/ps", ["eww", "-p", String(pid)]) {
            if let range = envLine.range(of: "ANTHROPIC_BASE_URL=") {
                let value = String(envLine[range.upperBound...].prefix { !$0.isWhitespace })
                if value.contains("127.0.0.1") || value.contains("localhost") {
                    provider = "CCR"
                } else {
                    provider = value
                        .replacingOccurrences(of: "https://", with: "")
                        .replacingOccurrences(of: "http://", with: "")
                }
            }
        }
        let project = cwdOf(pid: pid) ?? "?"
        return SessionInfo(pid: Int(pid), tty: tty, provider: provider,
                           project: project, terminal: "—", started_at: startedAt, num: nil)
    }

    private static func cwdOf(pid: pid_t) -> String? {
        guard let out = runTool("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]) else { return nil }
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            let path = line.dropFirst()
            if path.hasPrefix("/") { return String(path) }
        }
        return nil
    }

    private static func runTool(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private func startCleanupTimer() {
        // 定时器直接挂在 stateQueue 上：轮询的重活（ps/lsof 子进程、读 jsonl）全在队列里跑，
        // 主线程只读 snapshot，不会被它阻塞
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.cleanupAndNotify()
        }
        timer.resume()
        cleanupTimer = timer
    }

    /// 只在 stateQueue 上调用（定时器就挂在这个队列上）
    private func cleanupAndNotify() {
        reloadLocked()
        discoverProcesses()
        adoptDiscovered()
        let fingerprint = sessionFingerprint(allSessionsLocked())
        let changed = fingerprint != lastSessionFingerprint
        lastSessionFingerprint = fingerprint
        // 只有确实要清脏行、或内存与磁盘的 pid 集合不一致时才写回。每 5s 无脑写会触发
        // 文件监听的 rename 事件 → 重建 watcher，白白放大竞态。
        // 写回一律走 flock + 以磁盘为基准合并，不再用内存快照整份覆盖（那是丢写的根源）。
        let diskPids = readRegistryFromDisk().map { Set($0.map { $0.pid }) }
        if !stalePids.isEmpty || diskPids != Set(registered.map { $0.pid }) {
            _ = withRegistryLock { mergeRegistryLocked() }   // 拿不到锁就跳过，下一轮再收敛
        }
        publishLocked(notify: changed)
    }

    private func watchFile() {
        // fd 的关闭权归 cancel handler（它捕获自己那个 fd 值）。这里不能再 close(fd)：
        // writeSessionsFile 每次原子替换都会触发 rename 事件 → 重建 watcher，
        // 而旧 source 的 cancel handler 在别的队列上晚一步执行、读的是**已被换成新值的**
        // self.fd → 把新 fd 关掉（use-after-close）：监听悄悄失灵，且 fd 号被后续
        // FileHandle/socket 复用后会收到随机伪事件。
        fileSource?.cancel()
        fileSource = nil
        fd = -1        // 关闭由 cancel handler 负责（它捕获了自己那个 fd）；这里只清队列内的记录

        let path = sessionsURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            watchDir()
            return
        }

        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedFD,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: .global()
        )
        // [weak source]：handler 强捕获 source 会形成 retain cycle，每次重建 watcher 泄漏一个
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            // source.data 要在 handler 里就地读，别带进 async 块（那时 source 可能已重建）
            let needsRewatch = source.data.contains(.delete) || source.data.contains(.rename)
            self.stateQueue.async {
                self.reloadLocked()
                self.publishLocked(notify: true)
                if needsRewatch { self.watchFile() }
            }
        }
        // cancel handler 在 .global() 上执行，**不碰 self.fd**（那是 stateQueue 的状态，
        // 跨队列读写就是数据竞争）；它只关自己捕获的那个 fd
        source.setCancelHandler {
            close(watchedFD)
        }
        source.resume()
        fileSource = source
        // 文件监听已建立，目录监听（仅用于等文件出现）可以撤了，否则 ~/.claude 下
        // 每次写事件都会重复触发重建，放大竞态
        dirSource?.cancel()
        dirSource = nil
    }

    private func watchDir() {
        let dirPath = sessionsURL.deletingLastPathComponent().path
        let dirFD = open(dirPath, O_EVTONLY)
        guard dirFD >= 0 else { return }
        fd = dirFD
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: [.write], queue: .global()
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.stateQueue.async {
                guard FileManager.default.fileExists(atPath: self.sessionsURL.path) else { return }
                self.watchFile()
                self.reloadLocked()
                self.publishLocked(notify: true)
            }
        }
        source.setCancelHandler {
            close(dirFD)                           // 同上：只关自己捕获的 fd，不碰队列内状态
        }
        source.resume()
        dirSource = source
    }
}
