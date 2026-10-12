import AppKit
import SwiftUI

final class StatusController: NSObject {
    private var statusItem: NSStatusItem?
    let sessionManager = SessionManager()
    private let providerService = ProviderService()
    private let projectManager = ProjectManager()
    let gatewayService = CCRGatewayService()
    let lineCheckService = LineCheckService()
    /// 优惠雷达。单例，popover 摘要行和面板窗口读同一份 @Published。
    let promotionService = PromotionService.shared
    private var promotionRadarWindow: NSWindow?
    private var popover: NSPopover?
    // 常驻自管外点兜底监视器（#265 第二脏源）：句柄只在 start() 装一次、stop() 卸，
    // 弹窗生命周期内不装不卸——从构造上消除漏挂/重复挂/卸载时序三类风险。
    private var outsideMonitorGlobal: Any?
    private var outsideMonitorLocal: Any?
    private let vm = PopoverViewModel()
    private var projectManagerWindow: NSWindow?
    private var providerManagerWindow: NSWindow?
    private var speedTestWindow: NSWindow?
    private var errorDiagnosisWindow: NSWindow?
    private var providerSettingsWindow: NSWindow?
    private var balanceAutoRefreshTimer: Timer?
    private var balanceAutoRefreshEnabled = false

    private let initialBalanceAutoRefreshDelay: TimeInterval = 5 * 60
    private let balanceAutoRefreshInterval: TimeInterval = 60 * 60
    // 存量线路周期实测：真实请求有微小花费，6 小时一轮足够在「开新会话前」发现上游挂掉；
    // 首轮错开余额刷新（5 分钟）。defaults 里的 lineAutoProbeInitialDelaySeconds 只供验证时缩短首轮等待。
    private let lineAutoProbeInterval: TimeInterval = 6 * 60 * 60
    private var lineAutoProbeInitialDelay: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "lineAutoProbeInitialDelaySeconds")
        return override > 0 ? override : 10 * 60
    }

    func start() {
        // 可变宽度：有会话时图标右边带个数字
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.idleIcon
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "ccpod"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        sessionManager.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.updateBadge()
                self?.refreshVM()
            }
        }
        sessionManager.start()

        providerService.onChange = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateBadge()
                self?.refreshVM()
            }
        }
        providerService.start()

        gatewayService.start()

        projectManager.onChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshVM() }
        }
        projectManager.start()

        vm.onLaunch = { [weak self] provider, project, terminal, model, effort in
            self?.closePopoverNow()
            self?.doLaunch(provider: provider, project: project, terminalName: terminal, model: model, effort: effort)
        }
        vm.onSwitch = { [weak self] session, target in
            self?.closePopoverNow()
            self?.doSwitch(session: session, target: target)
        }
        vm.onRecover = { [weak self] session, target in
            self?.closePopoverNow()
            self?.doRecoverInNewWindow(session: session, target: target)
        }
        vm.onClose = { [weak self] session in
            self?.doClose(session: session)
        }
        vm.onRename = { [weak self] session in
            self?.closePopoverNow()
            self?.doRename(session: session)
        }
        vm.onFocus = { [weak self] session in
            self?.closePopoverNow()
            self?.doFocus(session: session)
        }
        vm.onQuit = {
            NSApp.terminate(nil)
        }
        vm.onShowProviderManager = { [weak self] in
            self?.closePopoverNow()
            self?.showProviderManagerWindow()
        }
        vm.onAddProvider = { [weak self] in
            self?.closePopoverNow()
            self?.showProviderManagerWindow(openAdd: true)
        }
        vm.onEditDirectLine = { [weak self] name in
            self?.closePopoverNow()
            self?.showProviderManagerWindow(openEdit: name)
        }
        vm.onSpeedTest = { [weak self] in
            self?.closePopoverNow()
            self?.showSpeedTestWindow()
        }
        vm.onManageProjects = { [weak self] in
            self?.closePopoverNow()
            self?.showProjectManagerWindow()
        }
        vm.onShowErrorDiagnosis = { [weak self] in
            self?.closePopoverNow()
            self?.showErrorDiagnosisWindow()
        }
        vm.onShowPromotionRadar = { [weak self] in
            self?.closePopoverNow()
            self?.showPromotionRadarWindow()
        }

        BalanceService.shared.onUpdate = { [weak self] name, info in
            DispatchQueue.main.async {
                self?.vm.apply(name: name, info: info)
            }
        }
        HealthService.shared.onUpdate = { [weak self] name, info in
            DispatchQueue.main.async {
                guard let self else { return }
                var next = self.vm.healthStates
                next[name] = info
                self.vm.healthStates = next
            }
        }

        // 保持唤醒开关状态联动菜单栏 ⚡ 徽章；启动时先对一次账
        SleepSwitchService.shared.onChange = { [weak self] in
            self?.updateBadge()
        }
        SleepSwitchService.shared.refresh()

        updateBadge()
        startBalanceAutoRefresh()
        lineCheckService.startAutoProbe(initialDelay: lineAutoProbeInitialDelay, interval: lineAutoProbeInterval)
        lineCheckService.startRoutingLeakWatch(interval: 30 * 60)
        // 优惠雷达：60 秒心跳，真正的到点判定在 PromotionSchedule.due（纯函数、已单测）。
        // initialDelay 8 秒是让开机时的网关刷新、余额拉取先落地，别抢同一批 IO。
        promotionService.start(initialDelay: 8)

        installOutsideFallbackMonitors()
        vm.onPickerChanged = { [weak self] in
            // 选择事件在 NSMenu tracking loop 内触发；异步一拍等 tracking 收尾后复位 key——
            // tracking 会让 popover 窗口失 key（click-through，第一下白点，#265 层3/D6 实测）。
            DispatchQueue.main.async {
                self?.popover?.contentViewController?.view.window?.makeKey()
            }
        }
    }

    func stop() {
        // 常驻外点兜底监视器唯一卸载点（见 installOutsideFallbackMonitors）
        if let g = outsideMonitorGlobal { NSEvent.removeMonitor(g) }
        if let l = outsideMonitorLocal { NSEvent.removeMonitor(l) }
        outsideMonitorGlobal = nil
        outsideMonitorLocal = nil
        stopBalanceAutoRefresh()
        lineCheckService.stopAutoProbe()
        promotionService.stop()
        sessionManager.stop()
        providerService.stop()
        projectManager.stop()
        gatewayService.stop()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    /// 需要立刻让出焦点的动作（launch/切换/重命名/聚焦/开窗）前同步关弹窗。
    /// animates=true 时 close() 是异步动画：动画期间 isShown 仍 true、系统 transient
    /// 外点监视器未卸载，此时抢焦点会把 popover 打成半死态——外点关失效（持久）+
    /// show 失效（isShown 卡 true 让 togglePopover 误落 close 分支，分钟级自愈）。
    /// 详见 .local/notes-281/265-bug-popover-close-report.md（#265）。
    private func closePopoverNow() {
        guard let pop = popover else { return }   // 局部强引用：close 完成前对象必不被 ARC 释放
        pop.animates = false   // 必须在 close() 前：动画开关在 close 调用瞬间被读取
        pop.close()            // animates=false ⇒ 同步完成：isShown 立即 false，监视器正常卸载
        popover = nil          // close 后才断引用：期间读到 self.popover 的代码看到的仍是已关实例
    }

    /// 常驻自管外点兜底（#265 第二脏源）：弹窗内 NSMenu tracking（Picker/Menu 的真实鼠标
    /// 事件路径）会杀死系统 transient 外点监视器——实测恢复 key 后外点仍不关，监视器死
    /// 独立于 key 态（fix-plan2.md §1 轮 G7）。系统监视器活着时本兜底零干扰：0.4s 延迟内
    /// 系统已带动画关弹窗，isShown=false 兜底不触发；死了则兜底同步关。
    /// start() 唯一安装点，幂等 guard 防重复；无常态卸载（仅 stop()）。
    private func installOutsideFallbackMonitors() {
        guard outsideMonitorGlobal == nil, outsideMonitorLocal == nil else { return }
        outsideMonitorGlobal = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.handleOutsideClick(event, source: .otherApp)
        }
        outsideMonitorLocal = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.handleOutsideClick(event, source: .ownApp)
            return event   // 只观察不吞事件：内部按钮/Picker 点击照常分发
        }
    }

    private func handleOutsideClick(_ event: NSEvent, source: PopoverClickClassifier.Source) {
        guard let pop = popover, pop.isShown else { return }   // 无弹窗不管
        guard let win = pop.contentViewController?.view.window else { return }
        // 外点 = 点击目标不属于弹窗自己的界面树（窗口父子链），不看矩形也不猜层级。
        // 旧判据「落在弹窗矩形外 + 层级 != 101」把线路下拉（挂在弹窗下的独立子窗口、
        // 层级 25、矩形在弹窗外）判成了外点：点一下线路，0.4s 后主弹窗被关（2026-10-10）。
        // 判定规则与实测依据见 PopoverClickClassifier。
        let ew = event.window
        let outside = PopoverClickClassifier.isOutside(
            source: source,
            hasWindow: ew != nil,
            inPopoverFamily: ew.map { PopoverClickClassifier.inFamily($0, of: win) { $0.parent } } ?? false,
            windowLevel: ew?.level.rawValue ?? 0
        )
        guard outside else { return }
        // 延迟兜底：给系统监视器 0.4s 先按原动画关；实例同一性 guard 防止用户
        // 0.4s 内已重开新弹窗时被误关（连点多次外点亦幂等）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.popover === pop, pop.isShown else { return }
            self.closePopoverNow()
        }
    }

    @objc private func togglePopover() {
        if let popover = popover, popover.isShown {
            popover.close()
            return
        }
        refreshVM()
        gatewayService.refresh()
        lineCheckService.refresh()
        SleepSwitchService.shared.refresh()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        let hosting = NSHostingController(rootView: PopoverContentView(vm: vm, gateway: gatewayService, lineCheck: lineCheckService, onRefresh: { [weak self] in
            self?.refreshVM()
        }, onOpenProviderSettings: { [weak self] name in
            self?.openProviderSettings(name: name)
        }))
        // 弹窗尺寸跟随 SwiftUI 内容：折叠/展开管线、额度数据到达后高度要跟着变，
        // 只在打开时取一次 fittingSize 会留白或截断。
        hosting.sizingOptions = [.preferredContentSize]
        let size = hosting.view.fittingSize
        pop.contentSize = NSSize(width: max(size.width, 320), height: size.height)
        pop.contentViewController = hosting
        popover = pop

        if let button = statusItem?.button {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func refreshVM() {
        vm.refresh(providerService: providerService, projectManager: projectManager, sessionManager: sessionManager)
    }

    /// 线路设置独立窗口（B 路线④的弹窗形态）：复用单窗口，切线路只换内容。
    private func openProviderSettings(name: String) {
        closePopoverNow()
        let editor = ProviderEditorView(providerName: name, onSaved: { [weak self] in
            self?.lineCheckService.refresh()
            // 模型列表可能变了：同步 gw-*.json 的 gateway_models/model_notice
            GatewayLineService.shared.refresh()
        })
        if let window = providerSettingsWindow {
            window.title = "线路设置 · \(gatewayProviderDisplayName(name))"
            window.contentViewController = NSHostingController(rootView: editor.padding(14).frame(width: 400))
            // 替换 contentViewController 不保证窗口自适应，显式复位尺寸
            window.setContentSize(NSSize(width: 400, height: 500))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "线路设置 · \(gatewayProviderDisplayName(name))"
        window.contentViewController = NSHostingController(rootView: editor.padding(14).frame(width: 400))
        window.minSize = NSSize(width: 400, height: 440)
        window.isReleasedWhenClosed = false
        window.center()
        providerSettingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startBalanceAutoRefresh() {
        stopBalanceAutoRefresh()
        balanceAutoRefreshEnabled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + initialBalanceAutoRefreshDelay) { [weak self] in
            guard let self, self.balanceAutoRefreshEnabled else { return }
            self.refreshActiveBalances()
        }
        let timer = Timer(timeInterval: balanceAutoRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshActiveBalances()
        }
        RunLoop.main.add(timer, forMode: .common)
        balanceAutoRefreshTimer = timer
    }

    private func stopBalanceAutoRefresh() {
        balanceAutoRefreshEnabled = false
        balanceAutoRefreshTimer?.invalidate()
        balanceAutoRefreshTimer = nil
    }

    private func refreshActiveBalances() {
        // 活跃会话的管线 + CCR 全部上游管线（有适配器的约 4-5 个请求/小时；fixed 规则不发请求）
        BalanceService.shared.refreshKnown(providers: activeBalanceProviders(), includeGatewayLines: true)
    }

    private func activeBalanceProviders() -> [String] {
        var providers = Set<String>()
        if let current = providerService.currentProvider(), !current.isEmpty {
            providers.insert(current)
        }
        for session in sessionManager.snapshot.registered where !session.provider.isEmpty {
            providers.insert(session.provider)
        }
        providers.remove("official")
        return Array(providers).sorted()
    }

    // MARK: - Badge

    private func updateBadge() {
        let sessions = sessionManager.snapshot.registered
        let tooltip: String
        if sessions.isEmpty {
            tooltip = "ccpod"
        } else if sessions.count == 1 {
            let s = sessions[0]
            tooltip = "ccpod #\(s.sessionNumber) \(providerDisplayName(s.provider)) · \(s.projectName)"
        } else {
            let nums = sessions.map { "#\($0.sessionNumber)" }.joined(separator: " ")
            tooltip = "ccpod \(sessions.count) 个会话 · \(nums)"
        }
        // 图标双态（2026-10-06 头脑风暴后方案 E1，用户选定）：
        // 会话数从菜单栏砍掉（用户：点开弹窗看就够）；唤醒态用橙色实心——
        // 18px 画布上任何叠加小元素（圆点/闪电/数字）都没有可读性，颜色是唯一远可辨的信号。
        let awake = SleepSwitchService.shared.state == .on
        statusItem?.button?.attributedTitle = NSAttributedString(string: "")
        statusItem?.button?.image = awake ? Self.awakeIcon : Self.idleIcon
        statusItem?.button?.toolTip = tooltip + (awake ? " · 保持唤醒中" : "")
        updateStatusFile(sessions)
    }

    /// 常态图标：描边 terminal（template，跟随菜单栏深浅色）
    private static let idleIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "ccpod")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    /// 保持唤醒开启：琥珀色实心 terminal（非 template 彩色，一眼可见「正在耗电」）
    private static let awakeIcon: NSImage = {
        let side: CGFloat = 18
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            let img = NSImage(systemSymbolName: "terminal.fill",
                              accessibilityDescription: "ccpod · 保持唤醒中")?
                .withSymbolConfiguration(config)
            let s = img?.size ?? .zero
            img?.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2,
                                 width: s.width, height: s.height))
            NSColor.systemOrange.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
    }()

    private func updateStatusFile(_ sessions: [SessionInfo]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let statusURL = home.appendingPathComponent(".claude/ccpod-status.txt")
        let text: String
        if sessions.isEmpty {
            text = "⚪ ccpod"
        } else {
            text = sessions.map { "\(badgeEmoji($0.provider)) #\($0.sessionNumber) \(providerDisplayName($0.provider))·\($0.projectName)" }.joined(separator: " | ")
        }
        try? text.write(to: statusURL, atomically: true, encoding: .utf8)
    }

    private func badgeEmoji(_ provider: String) -> String {
        switch provider {
        case "official": return "🟢"
        case "easyclaude": return "🔵"
        case "minimax": return "🟠"
        case "glm": return "🟣"
        case "volcengine": return "🔴"
        case "aliyun": return "🟤"
        case "deepseek": return "🔷"
        case "kimi": return "🟡"
        default: return "⚪"
        }
    }

    // MARK: - Provider Manager Window

    private func showProviderManagerWindow(openAdd: Bool = false, openEdit: String? = nil) {
        if let w = providerManagerWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if openAdd { NotificationCenter.default.post(name: ProviderManagerView.openAddNotification, object: nil) }
            if let openEdit { NotificationCenter.default.post(name: ProviderManagerView.openEditNotification, object: openEdit) }
            return
        }
        let view = ProviderManagerView(gateway: gatewayService, lineCheck: lineCheckService, openAddOnAppear: openAdd,
                                       openEditOnAppear: openEdit, onChange: { [weak self] in
            self?.refreshVM()
        })
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "管线管理"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 460, height: 700))
        window.minSize = NSSize(width: 460, height: 560)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        providerManagerWindow = window
    }

    private func showSpeedTestWindow() {
        if let w = speedTestWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SpeedTestView()
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "线路测速"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 480))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        speedTestWindow = window
    }

    private func showPromotionRadarWindow() {
        if let w = promotionRadarWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = PromotionRadarView()
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "优惠雷达"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 540, height: 600))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        promotionRadarWindow = window
    }


    private func showErrorDiagnosisWindow() {
        if let w = errorDiagnosisWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // 弹窗「线路状态」里挂 ⚠️ 的都收进来：网关线路的测通失败（不以 ✅ 开头）+ 直连线路的状态异常。
        // 原来只收测通失败，直连线路的 ⚠️ 在这里看不到（2026-10-09 线路状态审查）
        var problems: [(name: String, error: String)] = lineCheckService.probeResults
            .filter { !$0.value.text.isEmpty && !$0.value.text.hasPrefix("✅") }
            .map { (gatewayProviderGroupDisplayName($0.key), $0.value.displayText) }
        for id in vm.directLines {
            guard let health = HealthService.shared.cached(id),
                  health.status == .down || health.status == .exhausted else { continue }
            // 会被「填入诊断」发给诊断模型，过一遍脱敏（测通结果在 LineCheckService 里已经过了）
            problems.append(("\(providerDisplayName(id))（直连）",
                             "\(gatewayVisibleText(health.detail ?? "线路不可用"))（\(AgeText.ago(health.checkedAt))检查）"))
        }

        let hosting = NSHostingController(rootView: ErrorDiagnosisView(autoDetectedErrors: problems))
        let window = NSWindow(contentViewController: hosting)
        window.title = "错误诊断"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 560))
        window.minSize = NSSize(width: 560, height: 420)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        errorDiagnosisWindow = window
    }

    // MARK: - Launch

    private func doLaunch(provider: String, project: String, terminalName: String,
                          model: String? = nil, effort: String? = nil) {
        let registry = TerminalRegistry.shared
        let adapter = registry.adapters.first { $0.name == terminalName }
            ?? registry.defaultAdapter

        let ccgoPath = locateCCGo()
        // 启动表单选的模型 / 思考强度只带进这一次的命令（LaunchOptions）
        let command = LaunchOptions.ccgoArguments(ccgo: ccgoPath, provider: provider, project: project,
                                                  model: model, effort: effort)
            .map { shellQuote($0) }.joined(separator: " ")
        let projectName = (project as NSString).lastPathComponent
        let num = sessionManager.nextSessionNumber()
        let title = "#\(num) \(providerDisplayName(provider)) · \(projectName)"

        DispatchQueue.global().async { [weak self] in
            do {
                try adapter.openNewWindow(command: command, title: title)
            } catch {
                DispatchQueue.main.async { self?.showError(error) }
            }
        }
    }

    // MARK: - Switch

    /// 正在切线的登记号（只在主线程读写）。切线第一步就不可逆，同一会话不许并发发起两次。
    private var switchesInFlight = Set<Int>()

    private func doSwitch(session: SessionInfo, target: String) {
        // 收编会话（直接启动）没有 ccgo 的 pending 重启机制，就地切换会杀掉会话且无法恢复——
        // 统一路由到"新窗口继承"（resume 同一会话 + 新线路）。
        if session.terminal == "adopted" {
            doRecoverInNewWindow(session: session, target: target)
            return
        }
        let num = session.sessionNumber
        guard !switchesInFlight.contains(num) else { return }
        switchesInFlight.insert(num)
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.switchesInFlight.remove(num) } }
            let claudeDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude")
            // 按**登记号**命名，不按 pid：pid 是系统临时号会被复用，残留的 pending 文件
            // 会让日后某个撞号的 ccgo 在退出时读到它、莫名其妙换线并 resume 到别的会话
            // （现网就有一个残留了 4 个月的 pending-113.json）。登记号单调、永不复用。
            let pendingFile = claudeDir.appendingPathComponent("ccpod-pending-\(session.sessionNumber).json")
            var payload = ["provider": target, "project": session.project,
                           "num": String(session.sessionNumber), "pid": String(session.pid)]
            guard let sessionID = self.resolveClaudeSessionID(for: session) else {
                DispatchQueue.main.async {
                    self.showError(TerminalAdapterError.scriptFailed("无法找到 #\(session.sessionNumber) 的 Claude sessionId"))
                }
                return
            }
            if target == session.provider {
                payload["sessionId"] = sessionID
            } else if let handoffDir = self.createHandoff(
                session: session,
                target: target,
                sessionID: sessionID
            ) {
                payload["handoffDir"] = handoffDir
                payload["sourceSessionId"] = sessionID
                payload["sourceProvider"] = session.provider
                payload["switchMode"] = "handoff"
            } else {
                DispatchQueue.main.async {
                    self.showError(TerminalAdapterError.scriptFailed("无法生成跨线路 handoff"))
                }
                return
            }

            do {
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: pendingFile, options: .atomic)
            } catch {
                DispatchQueue.main.async { self.showError(error) }
                return
            }

            let recovery: String
            if let dir = payload["handoffDir"] {
                recovery = "ccgo \(self.shellQuote(target)) \(self.shellQuote(session.project)) --handoff \(self.shellQuote(dir))"
            } else {
                recovery = "ccgo \(self.shellQuote(target)) \(self.shellQuote(session.project)) --resume \(self.shellQuote(sessionID))"
            }
            guard let claudePID = self.findClaudePID(onTTY: session.tty) else {
                // 以前这里静默跳过：请求文件留在盘上，会话哪天退出就哪天被莫名换线
                try? FileManager.default.removeItem(at: pendingFile)
                self.reportSwitchFailure(num: num, reason: "在该终端里找不到 claude 进程，本次切换已取消。", recovery: nil)
                return
            }
            kill(pid_t(claudePID), SIGTERM)
            self.verifySwitch(session: session, oldClaudePID: claudePID, pendingFile: pendingFile, recovery: recovery)
        }
    }

    /// 发起者自己确认结果：请求被消费 + 该终端里跑着一个**新的** claude 才算成功。
    /// 重启沿用包装脚本的 pid（exec），登记表行不变，所以判据看的是终端里的 claude 换没换人。
    /// 在后台线程阻塞轮询（调用方已在 global 队列），超时即报错并收走请求文件。
    private func verifySwitch(session: SessionInfo, oldClaudePID: Int, pendingFile: URL, recovery: String) {
        let deadline = Date().addingTimeInterval(25)
        var outcome = SwitchOutcome.pending
        while outcome == .pending {
            Thread.sleep(forTimeInterval: 0.5)
            let current = findClaudePID(onTTY: session.tty)
            outcome = SwitchOutcome.judge(
                requestFileExists: FileManager.default.fileExists(atPath: pendingFile.path),
                oldClaudeAlive: kill(pid_t(oldClaudePID), 0) == 0,
                newClaudeOnTTY: current != nil && current != oldClaudePID,
                timedOut: Date() >= deadline
            )
        }
        DispatchQueue.main.async { self.sessionManager.refreshNow() }
        guard let reason = outcome.failureText else { return }
        // 失败就收走请求：留着它，这个号的会话日后退出时会被莫名其妙地换线
        try? FileManager.default.removeItem(at: pendingFile)
        reportSwitchFailure(num: session.sessionNumber, reason: reason, recovery: recovery)
    }

    private func reportSwitchFailure(num: Int, reason: String, recovery: String?) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "#\(num) 切换线路没有成功"
            var text = reason
            if let recovery {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(recovery, forType: .string)
                text += "\n\n会话内容没有丢。在任意终端粘贴下面这行即可接回（已复制到剪贴板）：\n\n\(recovery)"
            }
            alert.informativeText = text
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func createHandoff(session: SessionInfo, target: String, sessionID: String) -> String? {
        let script = locateCCHandoff()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: script)
        process.arguments = [
            "--session-id", sessionID,
            "--project", session.project,
            "--source-provider", session.provider,
            "--target-provider", target,
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            DispatchQueue.main.async {
                self.showError(TerminalAdapterError.scriptFailed(stderr.isEmpty ? "cchandoff 失败" : stderr))
            }
            return nil
        }
        let path = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func doRecoverInNewWindow(session: SessionInfo, target: String) {
        guard let sessionID = resolveClaudeSessionID(for: session) else {
            showError(TerminalAdapterError.scriptFailed("无法找到 #\(session.sessionNumber) 的 Claude sessionId"))
            return
        }

        let registry = TerminalRegistry.shared
        let adapter = registry.adapters.first { $0.identifier == session.terminal || $0.name == session.terminal }
            ?? registry.defaultAdapter

        let ccgoPath = locateCCGo()
        let title = "#\(session.sessionNumber) \(providerDisplayName(target)) · \(session.projectName)"

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let command: String
            if target == session.provider {
                command = "CCPOD_REUSE_NUM=\(session.sessionNumber) \(self.shellQuote(ccgoPath)) \(self.shellQuote(target)) \(self.shellQuote(session.project)) --resume \(self.shellQuote(sessionID))"
            } else if let handoffDir = self.createHandoff(session: session, target: target, sessionID: sessionID) {
                command = "CCPOD_REUSE_NUM=\(session.sessionNumber) \(self.shellQuote(ccgoPath)) \(self.shellQuote(target)) \(self.shellQuote(session.project)) --handoff \(self.shellQuote(handoffDir))"
            } else {
                DispatchQueue.main.async {
                    self.showError(TerminalAdapterError.scriptFailed("无法生成跨线路 handoff"))
                }
                return
            }
            do {
                try adapter.openNewWindow(command: command, title: title)
            } catch {
                DispatchQueue.main.async { self.showError(error) }
            }
        }
    }

    // MARK: - Close

    private func doClose(session: SessionInfo) {
        // 杀之前必须验明正身：pid 是系统发的临时号，进程一退就会被别的进程捡走，
        // 而登记行最长会残留一个清理周期（5s）。这期间点"关闭"，kill(-pgid) 会打掉
        // 一个无辜的进程组 —— 不可逆、会丢用户工作。
        guard isStillOurProcess(session) else {
            sessionManager.dropStaleRow(pid: session.pid)
            showError(TerminalAdapterError.scriptFailed(
                "会话 #\(session.sessionNumber) 已经退出了，登记行已清理。\n"
                + "pid \(session.pid) 现在属于别的进程（或已空闲），没有发送任何信号。"))
            refreshVM()
            updateBadge()
            return
        }
        // Terminate the whole ccgo process group. Killing only the wrapper can
        // leave Claude attached to an invisible PTY, which keeps the registry
        // looking alive even after the Ghostty surface is gone.
        terminateSessionProcessGroup(pid: pid_t(session.pid), signal: SIGTERM)
        // Nudge a refresh so the row disappears promptly; the 5s cleanup timer
        // also catches it, but this is snappier.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sessionManager.reload()
            self?.refreshVM()
            self?.updateBadge()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            // SIGKILL 前**再验一次**：这 1.5s 里进程可能已退出且 pid 被复用，
            // 而 SIGKILL 不可挽回
            guard self.isStillOurProcess(session) else { return }
            self.terminateSessionProcessGroup(pid: pid_t(session.pid), signal: SIGKILL)
            DispatchQueue.main.async {
                self.sessionManager.reload()
                self.refreshVM()
                self.updateBadge()
            }
        }
    }

    /// 这个 pid 现在还是"我们登记的那个会话"吗？
    ///
    /// 先决条件：**TTY 必须一致**（登记表里 ccgo 写的是 `/dev/ttys003`、发现层写的是 `ttys000`，
    /// 所以两边都去掉 `/dev/` 再比）。pid 被复用到别的终端上的概率远高于复用到同一个终端。
    /// 再按强度取判据：
    /// ① 进程环境里的 `CCPOD_SESSION_NUM` 与登记号一致 → 确定是自己；是别的号 → 确定不是
    ///    （实测：claude 子进程能读到这个变量，**ccgo 包装 bash 读不到** —— macOS 的 `ps eww`
    ///    对部分进程不给环境，所以这条只能当"有就用"的强判据，不能当唯一判据）
    /// ② 取不到环境时看命令行形态：包装行是 `bash /…/ccgo <provider> <project>`（含 "ccgo"），
    ///    收编行是 `claude …`（可执行名以 claude 开头，注意真名可能是 claude.exe）
    /// 任一步取不到信息就当作"不是自己"——宁可不杀，也不能杀掉无辜进程组。
    private func isStillOurProcess(_ session: SessionInfo) -> Bool {
        guard kill(pid_t(session.pid), 0) == 0 else { return false }
        guard let probe = Self.probeProcess(pid: session.pid) else { return false }
        let norm: (String) -> String = { $0.replacingOccurrences(of: "/dev/", with: "") }
        guard norm(probe.tty) == norm(session.tty) else { return false }
        if session.terminal != "adopted" {
            // ccgo 包装行：环境里的登记号是最强判据（注意包装 bash 自己的环境 ps eww 常常读不到，
            // 只有它 fork 出来的 claude 子进程读得到，所以这条只能"有就用"）；
            // 读不到就退到命令行形态 `bash /…/ccgo <provider> <project>`
            if let envNum = probe.sessionNum { return envNum == session.sessionNumber }
            // 不能只用 contains("ccgo")：同一个终端上 `vim scripts/ccgo.sh`、`grep ccgo …`
            // 都会命中。要求某个参数的**文件名**正好是 ccgo（包装行长这样：
            // `bash /Users/…/.local/bin/ccgo <provider> <project>`）
            return probe.command.split(separator: " ").contains {
                ($0 as NSString).lastPathComponent == "ccgo"
            }
        }
        // 收编行：登记号是 ccpod **事后分配**的，进程环境里可能带着别的会话号
        // （从某个 ccpod 会话里 shell-out 直接跑 claude 就会继承那个号）。
        // 所以这里绝不拿 env 的号当否定判据，否则这类会话永远关不掉、还会被反复删行+重新收编烧号。
        // 只认"可执行名以 claude 开头"（basename，兼容真名 claude.exe）+ 上面已前置校验的 TTY。
        let executable = probe.command.split(separator: " ").first
            .map { ($0 as NSString).lastPathComponent } ?? ""
        return executable.hasPrefix("claude")
    }

    fileprivate struct ProcessProbe {
        let command: String
        let tty: String
        let sessionNum: Int?
    }

    fileprivate static func probeProcess(pid: Int) -> ProcessProbe? {
        // ⚠️ command 与 tty **必须分两次 ps 调用**：同时请求两列时 macOS 的 ps 会把 command
        // 截断到 16 字符（实测 `ps -o command= -o tty=` 只给 "bash /Users/matt"，加 -ww 也没用；
        // 单独 `ps -o command=` 才是完整命令行）。截断会让"命令行含 ccgo"这个判据永远不成立，
        // 于是所有 ccgo 启动的会话验身全失败、关闭按钮全线失效——这个 bug 被正反用例测试当场抓到。
        guard let command = runPS(["-o", "command=", "-p", String(pid)])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return nil }
        let tty = runPS(["-o", "tty=", "-p", String(pid)])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var sessionNum: Int?
        if let env = runPS(["eww", "-p", String(pid)]),
           let range = env.range(of: "CCPOD_SESSION_NUM=") {
            let value = String(env[range.upperBound...].prefix { !$0.isWhitespace })
            sessionNum = Int(value)
        }
        return ProcessProbe(command: command, tty: tty, sessionNum: sessionNum)
    }

    private static func runPS(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Focus

    /// 把会话所在的终端分屏/窗口切到前台。
    /// 登记行知道自己在哪个终端（ccgo 按 TERM_PROGRAM 写的 iterm2/ghostty/terminal），先问它；
    /// 收编行/直接启动行的 terminal 字段是 "adopted"/"—"，不知道在哪，就把其余**在运行的**终端轮一遍
    /// （没在跑的不问：`tell application` 会把它拉起来）。tty 在每个终端里都唯一，先命中先停。
    private func doFocus(session: SessionInfo) {
        guard session.hasTerminal else {
            showError(TerminalAdapterError.scriptFailed(
                "这个进程没有终端（tty \(session.tty)），没有窗口可以切过去。"))
            return
        }
        let hint = SessionFocusHint(title: SessionInfo.hookTitle(tty: session.tty),
                                    projectPath: session.project)
        let registry = TerminalRegistry.shared
        let preferred = registry.adapters.filter { $0.identifier == session.terminal }
        let others = registry.adapters.filter { $0.identifier != session.terminal }
        // runningApplications 在主线程读，再把名单带到后台去跑脚本
        let candidates = (preferred + others).filter { $0.isRunning }
        let label = session.num != nil ? "#\(session.sessionNumber)" : "pid \(session.pid)"
        guard !candidates.isEmpty else {
            showError(TerminalAdapterError.scriptFailed(
                "iTerm2、Ghostty、Terminal 都没在运行，找不到 \(label) 的窗口。"))
            return
        }
        DispatchQueue.global().async { [weak self] in
            var failures: [String] = []
            for adapter in candidates {
                do {
                    if try adapter.focusSession(tty: session.tty, hint: hint) { return }
                } catch {
                    failures.append("\(adapter.name)：\(error)")
                }
            }
            let searched = candidates.map { $0.name }.joined(separator: "、")
            var message = "在 \(searched) 里没找到 \(label) 的分屏（\(session.tty)）。\n"
                + "窗口可能已经关掉了；如果它在 Ghostty 里，分屏标题得先由 session-hud hook 写过一次才认得出来。"
            if !failures.isEmpty { message += "\n\n脚本报错：\n" + failures.joined(separator: "\n") }
            DispatchQueue.main.async { self?.showError(TerminalAdapterError.scriptFailed(message)) }
        }
    }

    // MARK: - Rename

    /// 重命名对话：调用 `~/.claude/bin/claude-rename`，它往会话 jsonl 追加一条
    /// `custom-title` 记录（Claude Code 自己的 saveCustomTitle 做法，优先级高于 ai-title，
    /// 活跃会话也只追加不改写字节，所以安全）。留空 = 让工具依据对话内容自动生成。
    /// 自动生成标题要调网关，最长可能几十秒；期间不给第二次点击留口子
    /// （两次 claude-rename 并发 append 同一个 jsonl 虽然安全，但标题会变成"后写的那次"，
    /// 与用户意图不符）
    private var renameInFlight = false

    private func doRename(session: SessionInfo) {
        guard !renameInFlight else { return }
        guard let sessionID = sessionManager.snapshot.sessionIDs[session.pid] else {
            showError(TerminalAdapterError.scriptFailed(
                "找不到这个会话的 id（它可能刚退出），没法改名"))
            return
        }
        let script = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/bin/claude-rename").path
        guard FileManager.default.isExecutableFile(atPath: script) else {
            showError(TerminalAdapterError.scriptFailed(
                "找不到改名工具：\(script)\n重装 ccpod（./install.sh）可以补上"))
            return
        }
        let current = sessionManager.snapshot.titles[session.pid] ?? ""

        let alert = NSAlert()
        alert.messageText = "重命名对话"
        alert.informativeText = (current.isEmpty ? "这个对话还没有标题。" : "当前标题：\(current)")
            + "\n留空点「自动生成」= 依据对话内容生成；改名后 claude --resume 列表同步变化。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "自动生成")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = current
        field.placeholderString = "新标题（留空 = 自动生成）"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        let auto = response == .alertSecondButtonReturn
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !auto && title.isEmpty { return }

        // 手动标题作为参数传；自动生成则不带标题参数
        var arguments = [sessionID]
        if !auto { arguments.append(title) }

        renameInFlight = true
        DispatchQueue.global().async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: script)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    self?.renameInFlight = false
                    self?.showError(error)
                }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.renameInFlight = false
                if process.terminationStatus != 0 {
                    self.showError(TerminalAdapterError.scriptFailed(
                        output.isEmpty ? "改名失败（退出码 \(process.terminationStatus)）" : output))
                    return
                }
                // 立刻跑一轮完整发现，让新标题当场出现，而不是等 ≤5s 的轮询
                // （用户对"操作完看不到反馈"已经投诉过多次）
                self.sessionManager.refreshNow()
            }
        }
    }

    private func terminateSessionProcessGroup(pid: pid_t, signal: Int32) {
        let pgid = getpgid(pid)
        if pgid > 1 {
            kill(-pgid, signal)
        }
        kill(pid, signal)
    }

    // MARK: - Helpers

    private func locateCCGo() -> String {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/ccgo").path,
            "/usr/local/bin/ccgo",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "ccgo"
    }

    private func locateCCHandoff() -> String {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/cchandoff").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Projects/ccpod/scripts/cchandoff.py").path,
            "/usr/local/bin/cchandoff",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "cchandoff"
    }

    private func shellQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private func showError(_ err: Error) {
        let alert = NSAlert()
        alert.messageText = "ccpod 操作失败"
        alert.informativeText = gatewayVisibleText(String(describing: err))
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func findClaudePID(onTTY tty: String) -> Int? {
        let ttyShort = tty.replacingOccurrences(of: "/dev/", with: "")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-t", ttyShort, "-o", "pid,comm"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("claude") || trimmed.contains(" claude") {
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                if let pidStr = parts.first, let pid = Int(pidStr) {
                    return pid
                }
            }
        }
        return nil
    }

    private func resolveClaudeSessionID(for session: SessionInfo) -> String? {
        guard let claudePID = findClaudePID(onTTY: session.tty) else { return nil }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(claudePID).json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = obj["sessionId"] as? String,
              !sessionID.isEmpty else {
            return nil
        }
        return sessionID
    }

    private func showProjectManagerWindow() {
        if let window = projectManagerWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = ProjectManagerView(manager: projectManager, onAdd: { [weak self] in
            self?.showAddProjectDialog()
        })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "项目管理"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 500))
        window.minSize = NSSize(width: 540, height: 360)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        projectManagerWindow = window
    }

    private func showAddProjectDialog() {
        let panel = NSOpenPanel()
        panel.title = "选择项目目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            projectManager.addManualProject(path: url.path)
            refreshVM()
        }
    }

}
