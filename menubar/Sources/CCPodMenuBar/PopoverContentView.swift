import SwiftUI

final class PopoverViewModel: ObservableObject {
    @Published var providers: [String] = []
    @Published var projects: [ProjectInfo] = []
    @Published var terminals: [String] = []
    @Published var sessions: [SessionInfo] = []
    /// 会话标题（custom-title / ai-title），key = pid。登记会话与收编会话都有。
    @Published var sessionTitles: [Int: String] = [:]
    @Published var sessionHud: [Int: SessionHudState] = [:]
    /// pid → claude 会话 id。有这个才显示重命名按钮（改标题要按 id 定位会话文件）
    @Published var sessionIDs: [Int: String] = [:]
    var onRename: ((SessionInfo) -> Void)?
    /// 登记表读/解析异常。非 nil 时要在会话卡里说出来——这个产品已经因为
    /// "空状态不解释原因"被投诉过两次，不能再让用户猜。
    @Published var registryWarning: String?

    @Published var selectedProvider: String = ""
    @Published var selectedProject: String = ""
    @Published var selectedTerminal: String = ""

    @Published var balances: [String: BalanceInfo] = [:]
    @Published var healthStates: [String: HealthInfo] = [:]
    var onShowProviderManager: (() -> Void)?
    var onSpeedTest: (() -> Void)?
    var onManageProjects: (() -> Void)?
    var onShowErrorDiagnosis: (() -> Void)?

    var onLaunch: ((String, String, String) -> Void)?
    var onSwitch: ((SessionInfo, String) -> Void)?
    var onRecover: ((SessionInfo, String) -> Void)?
    var onClose: ((SessionInfo) -> Void)?

    var onQuit: (() -> Void)?



    func refresh(providerService: ProviderService, projectManager: ProjectManager, sessionManager: SessionManager, refreshRemote: Bool = false) {
        providers = providerService.availableProviders()
        projects = projectManager.recentProjects()
        terminals = TerminalRegistry.shared.adapters.map { $0.name }
        // 只读主线程快照：SessionManager 的可变状态全在它的串行队列上，
        // 这里不碰任何共享容器（rows 已在队列内按 pid 去重）
        let snap = sessionManager.snapshot
        sessions = snap.rows
        sessionTitles = snap.titles
        sessionHud = snap.hud
        sessionIDs = snap.sessionIDs
        registryWarning = snap.warning


        if selectedProvider.isEmpty || !providers.contains(selectedProvider) {
            selectedProvider = providerService.resolvedPipeline(selectedProvider, from: providers)
                ?? providerService.preferredLaunchProvider(from: providers)
        }
        if selectedProject.isEmpty || !projects.contains(where: { $0.path == selectedProject }) {
            selectedProject = projects.first?.path ?? ""
        }
        if selectedTerminal.isEmpty || !terminals.contains(selectedTerminal) {
            // 默认跟随 TerminalRegistry 的默认终端（iTerm2）
            selectedTerminal = TerminalRegistry.shared.defaultAdapter.name
        }

        loadCachedBalances()
        loadCachedHealth()
        if refreshRemote {
            refreshBalances(force: true)
            refreshHealth(force: true)
        }
    }

    func loadCachedHealth() {
        for provider in providers {
            if let cached = HealthService.shared.cached(provider) {
                healthStates[provider] = cached
            }
        }
    }

    func refreshHealth(force: Bool = false) {
        for p in providers {
            HealthService.shared.check(p, force: force)
        }
    }

    func refreshSelectedProvider() {
        guard !selectedProvider.isEmpty else { return }
        refreshQuota(name: selectedProvider)
        HealthService.shared.check(selectedProvider, force: true)
    }

    /// CCR 上游管线名（体检行）。额度按它们存，gw-* 启动项经 gateway_provider 映射到同一份。
    var quotaLineNames: [String] = []

    /// 一份结果写到 quota key 本身 + 所有映射到它的 gw-* 启动项（主线程调用）。
    func apply(name: String, info: BalanceInfo) {
        var next = balances
        next[name] = info
        for provider in providers where BalanceService.shared.quotaKey(for: provider) == name {
            next[provider] = info
        }
        balances = next
    }

    func loadCachedBalances() {
        for name in Set(providers + quotaLineNames) {
            if let cached = BalanceService.shared.cached(name) {
                balances[name] = cached
            }
        }
    }

    func fetchQuotaIfMissing(name: String) {
        BalanceService.shared.fetchBalance(provider: name, force: false) { [weak self] info in
            DispatchQueue.main.async {
                guard let self, let info else { return }
                self.apply(name: name, info: info)
            }
        }
    }

    /// 强制查一条（📊 展开区的 ↻）。
    func refreshQuota(name: String) {
        BalanceService.shared.fetchBalance(provider: name, force: true) { [weak self] info in
            DispatchQueue.main.async {
                guard let self, let info else { return }
                self.apply(name: name, info: info)
            }
        }
    }

    func refreshBalances(force: Bool = false) {
        for provider in Set(providers + quotaLineNames) {
            BalanceService.shared.fetchBalance(provider: provider, force: force) { [weak self] info in
                DispatchQueue.main.async {
                    guard let self, let info else { return }
                    self.apply(name: BalanceService.shared.quotaKey(for: provider), info: info)
                }
            }
        }
    }


}

struct PopoverContentView: View {
    @ObservedObject var vm: PopoverViewModel
    @ObservedObject var gateway: CCRGatewayService
    @ObservedObject var lineCheck: LineCheckService
    @ObservedObject var sleepSwitch: SleepSwitchService = .shared
    @State private var expandedProvider: String?
    @State private var hoveredLine: String?
    // 弹窗每次打开都会新建这个 View，@State 会被重置。
    // 管线区默认折叠（用户要求"自动折叠"，8 条展开太高）；会话区记住上次的选择（落 UserDefaults）。
    @State private var linesCollapsed = true
    @AppStorage("popover.sessionsCollapsed") private var sessionsCollapsed = false
    @State private var scrollContentHeight: CGFloat = 0

    var onRefresh: (() -> Void)?
    var onOpenProviderSettings: ((String) -> Void)?

    /// 上半区（网关/管线/会话）最多占多高。超过就在区内滚动，
    /// 否则弹窗会比屏幕还高、顶部被推出屏幕（2026-10-01 实测 1630pt，屏幕 982pt）。
    private var maxScrollHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(screen - 390, 240)  // 390 ≈ 启动区 + 保持唤醒卡 + 底栏 + 弹窗边距
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    gatewaySection
                    lineCheckSection
                    sessionsSection
                }
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ScrollContentHeightKey.self, value: geo.size.height)
                })
            }
            .frame(height: min(max(scrollContentHeight, 1), maxScrollHeight))
            .onPreferenceChange(ScrollContentHeightKey.self) { scrollContentHeight = $0 }
            launcherSection
            sleepSwitchSection
            quitSection
        }
        .padding(12)
        .frame(width: 360, alignment: .topLeading)
        .fixedSize()
        .onAppear { syncQuotaLines(lineCheck.lines.filter { !$0.isCheckBlock }.map(\.name)) }
        .onChange(of: lineCheck.lines.filter { !$0.isCheckBlock }.map(\.name)) { names in syncQuotaLines(names) }
    }

    /// 体检行名 = CCR 上游管线名 = 额度 quota key。有缓存只读缓存；从没查过的才查一次
    /// （刚启动时定时器要 5 分钟后才跑，不补这一下管线区会空着）。之后由定时器/↻ 负责。
    /// 直连线路（deepseek 等）不在体检行里，但会话/启动区要用它们的余额，一并补查。
    private func syncQuotaLines(_ names: [String]) {
        guard vm.quotaLineNames != names else { return }
        vm.quotaLineNames = names
        vm.loadCachedBalances()
        var keys = Set(names)
        keys.formUnion(vm.providers.map { BalanceService.shared.quotaKey(for: $0) })
        for name in keys where vm.balances[name] == nil {
            vm.fetchQuotaIfMissing(name: name)
        }
    }

    // 线路体检（B 路线③，消费 line-check.py --json，只读）
    private var lineCheckSection: some View {
        sectionCard {
            collapsibleHeader("管线", icon: "list.bullet.rectangle", collapsed: $linesCollapsed) {
                if !lineCheck.lines.isEmpty {
                    HStack(spacing: 5) {
                        Text("\(lineCheck.lines.filter { !$0.isCheckBlock }.count) 条")
                        // 计数为 0 的不画：「黄 0」摆在那儿会被读成有黄灯
                        ForEach(["G", "Y", "R"].filter { (lineCheck.counts[$0] ?? 0) > 0 }, id: \.self) { lv in
                            HStack(spacing: 1) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundColor(lineLevelColor(lv))
                                Text("\(lineCheck.counts[lv] ?? 0)")
                            }
                        }
                    }
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                }
            }
            if !linesCollapsed {
                if let reason = lineCheck.unavailable {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if lineCheck.lines.isEmpty {
                        Text("体检中…")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    VStack(spacing: 1) {
                        ForEach(lineCheck.lines) { row in
                            lineRow(row)
                        }
                    }
                    .padding(.horizontal, -6)
                    HStack(spacing: 12) {
                        Button {
                            lineCheck.refresh()
                            onRefresh?()
                        } label: {
                            Label(lineCheck.running ? "体检中…" : "重新体检", systemImage: "stethoscope")
                        }
                        .disabled(lineCheck.running)
                        Button {
                            vm.onShowProviderManager?()
                        } label: {
                            Label("管线管理", systemImage: "slider.horizontal.3")
                        }
                        Spacer()
                        if let at = lineCheck.checkedAt {
                            Text(at, style: .relative)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                    // 按钮行塞不下第二个时间，周期实测单独一行
                    if let summary = lineCheck.autoProbeSummary, let at = lineCheck.autoProbedAt {
                        (Text(summary + " · ") + Text(at, style: .time)
                         + Text(lineCheck.notifyBlocked ? " · 系统通知已关，出事只在这里显示" : ""))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                            .lineLimit(1)
                            .help("每 6 小时经网关给每条线路的每个模型发一次极小的真实请求（max_tokens=8，按量线路有微小花费）。"
                                  + "只在「上次通、这次确定失败」时发通知；从没通过的线路不提醒——"
                                  + "只认 Claude Code 客户端的网关（如 AIGoCode、Yescode）这种探测本来就过不了，不代表线路坏了。")
                    }
                }
            }
        }
    }

    /// 一条管线 = 一行：体检灯 · 名字 …… 额度短标签 ›。点行展开套餐详情、今日用量和操作。
    @ViewBuilder
    private func lineRow(_ row: LineCheckService.LineRow) -> some View {
        let expanded = expandedProvider == row.name
        let balance = vm.balances[row.name]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundColor(lineLevelColor(row.level))
                Text(row.displayName ?? gatewayProviderGroupDisplayName(row.name))
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if lineCheck.probing.contains(row.name) {
                    ProgressView().controlSize(.mini)
                }
                if let balance {
                    HStack(spacing: 4) {
                        if balance.status == .ok, let progress = balance.tightestWindow?.progress {
                            QuotaRing(progress: progress, diameter: 10, lineWidth: 2)
                        }
                        Text(balance.shortText)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundColor(quotaTone(balance))
                            .lineLimit(1)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedProvider = expanded ? nil : row.name
                }
                if !expanded, !row.isCheckBlock, lineCheck.usageTexts[row.name] == nil {
                    lineCheck.usage(name: row.name)
                }
            }
            .help(balance?.summaryLine() ?? row.note ?? "")

            if lineCheck.probing.contains(row.name) || lineCheck.probeResults[row.name] != nil {
                Text(lineCheck.probing.contains(row.name)
                     ? "测通中…（逐模型真实请求，最长约 2 分钟）"
                     : (lineCheck.probeResults[row.name] ?? ""))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }

            if expanded {
                lineDetail(row, balance: balance)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(expanded ? 0.05 : (hoveredLine == row.name ? 0.035 : 0)))
        )
        .onHover { inside in
            if inside { hoveredLine = row.name } else if hoveredLine == row.name { hoveredLine = nil }
        }
    }

    private func lineDetail(_ row: LineCheckService.LineRow, balance: BalanceInfo?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note = row.note {
                Text("体检：\(note)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 检查块合成行（网关本体/settings）没有额度、用量、测通和线路设置，只展示体检结论
            if !row.isCheckBlock {
                LineQuotaDetail(balance: balance) {
                    vm.refreshQuota(name: row.name)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("今日网关用量")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(lineCheck.usageTexts[row.name] ?? "获取中…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button {
                        lineCheck.probe(name: row.name)
                    } label: {
                        Label("测通", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(lineCheck.probing.contains(row.name))
                    .help("向该线路发真实探测（按量线路有微小花费）")
                    Button {
                        onOpenProviderSettings?(row.name)
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    Spacer()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            } else if let advice = row.fix {
                CheckBlockFixView(advice: advice, consoleAvailable: gateway.consoleURL != nil) {
                    lineCheck.refresh()
                    onRefresh?()
                }
            }
        }
    }

    /// 合成行（网关本体 / settings.json）的「去哪修」。只画真能做到的动作；做不到就只有说明和「重新体检」。
    private struct CheckBlockFixView: View {
        let advice: LineCheckFixAdvice
        let consoleAvailable: Bool
        let recheck: () -> Void
        @State private var copied = false

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(advice.hint)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .copyCommand(let command) = advice.fix {
                    Text(command)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    switch advice.fix {
                    case .copyCommand(let command):
                        Button {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(command, forType: .string)
                        } label: {
                            Label(copied ? "已复制" : "复制命令", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .help("只复制，不替你执行；粘到终端里运行")
                    case .openGatewayConsole:
                        if consoleAvailable {
                            Button {
                                CCRGatewayService.openConsole()
                            } label: {
                                Label("打开网关控制台", systemImage: "slider.horizontal.3")
                            }
                        } else {
                            Text("现在读不到网关控制台的地址，没法从这里打开")
                                .foregroundColor(.secondary)
                        }
                    case .revealFile(let path):
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        } label: {
                            Label("在访达中显示", systemImage: "folder")
                        }
                        .help(path)
                    case .none:
                        EmptyView()
                    }
                    Button(action: recheck) {
                        Label("重新体检", systemImage: "stethoscope")
                    }
                    Spacer()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            }
        }
    }

    /// 会话状态灯：SF Symbol 名（系统原生图标，零版权风险；语义与终端字符 ● 🔔 ⏸ ⚠️ ❓ 一一对应）
    private func hudSymbolName(_ hud: SessionHudState) -> String {
        if hud.isStuck { return "exclamationmark.triangle.fill" }
        switch hud.glyph {
        case "●": return "circle.fill"          // 正在干活
        case "🔔": return "bell.fill"           // 举手等你
        case "⏸": return "pause.circle"        // 闲着等活
        default: return "questionmark.circle"   // 读不懂
        }
    }

    private func hudSymbolColor(_ hud: SessionHudState) -> Color {
        if hud.isStuck { return .orange }
        switch hud.glyph {
        case "●": return .green
        case "🔔": return .yellow
        default: return .secondary
        }
    }

    /// 管线体检灯（G/Y/R → 圆点配色）
    private func lineLevelColor(_ level: String) -> Color {
        switch level {
        case "G": return .green
        case "Y": return .yellow
        case "R": return .red
        default: return .secondary.opacity(0.5)
        }
    }

    private func quotaTone(_ balance: BalanceInfo) -> Color {
        switch balance.status {
        case .ok:
            if balance.isExhausted { return .red }
            if let progress = balance.tightestWindow?.progress, progress >= 0.75 { return .orange }
            return .secondary
        case .failed:
            return .orange
        default:
            return .secondary.opacity(0.6)
        }
    }

    /// 可折叠卡片的标题行：整行可点（原来只有 10pt 的小箭头能点）。
    private func collapsibleHeader(_ title: String, icon: String, trailing: String,
                                   collapsed: Binding<Bool>) -> some View {
        collapsibleHeader(title, icon: icon, collapsed: collapsed) {
            Text(trailing)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }

    /// ViewBuilder 版：trailing 需要彩色圆点等富内容时用（调用方自行排版上色）。
    private func collapsibleHeader<Trailing: View>(_ title: String, icon: String,
                                                   collapsed: Binding<Bool>,
                                                   @ViewBuilder trailing: () -> Trailing) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { collapsed.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                sectionHeader(title, icon: icon)
                Spacer()
                trailing()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(collapsed.wrappedValue ? 0 : 90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed.wrappedValue ? "展开" : "折叠")
    }

    // CCR 网关状态（只读，B 路线①）：正常时只占一行
    private var gatewaySection: some View {
        sectionCard {
            HStack(spacing: 6) {
                sectionHeader("网关", icon: "bolt.horizontal")
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundColor(gateway.status == .running ? .green
                                     : (gateway.status == .down ? .red : .secondary.opacity(0.5)))
                Text(gateway.status == .running ? "运行中" : (gateway.status == .down ? "离线" : "检测中…"))
                    .font(.system(size: 12))
                    .foregroundColor(gateway.status == .down ? .red : .secondary)
                if let ms = gateway.latencyMs {
                    Text("\(ms)ms")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    gateway.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.secondary)
                }
                .help("重新检测")
                if gateway.consoleURL != nil {
                    Button {
                        CCRGatewayService.openConsole()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.secondary)
                    }
                    .help("打开网关控制台")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            if gateway.status == .down {
                if let err = gateway.lastError {
                    Text("失败原因：\(gatewayVisibleText(err))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("会话暂时无法连接 API，系统会尝试重新启动网关。稍后可点击 ↻ 重新检测。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.85))
        }
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .frame(width: 32, alignment: .trailing)
    }

    private var launcherSection: some View {
        sectionCard {
            sectionHeader("启动新会话", icon: "play.circle")

            HStack(spacing: 6) {
                formLabel("管线")
                ProviderDropdown(
                    providers: vm.providers,
                    balances: vm.balances,
                    healthStates: vm.healthStates,
                    selected: $vm.selectedProvider
                )
                .frame(minWidth: 0, maxWidth: .infinity)
                providerActionsMenu
            }

            HStack(spacing: 6) {
                formLabel("项目")
                Picker("", selection: $vm.selectedProject) {
                    ForEach(vm.projects, id: \.path) { proj in
                        Text(proj.name).tag(proj.path)
                    }
                }
                .labelsHidden()
                Button(action: { vm.onManageProjects?() }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("管理项目名称与目录")
            }

            HStack(spacing: 6) {
                formLabel("终端")
                Picker("", selection: $vm.selectedTerminal) {
                    ForEach(vm.terminals, id: \.self) { t in
                        Text(t).tag(t)
                    }
                }
                .labelsHidden()
            }

            HStack {
                Spacer()
                launchActionButton
            }
        }
        .font(.system(size: 13))
    }

    private var providerActionsMenu: some View {
        Menu {
            Button(action: { vm.refreshSelectedProvider() }) {
                Label("刷新当前管线", systemImage: "arrow.clockwise")
            }
            Button(action: { vm.onSpeedTest?() }) {
                Label("线路测速", systemImage: "gauge.with.dots.needle.33percent")
            }
            Divider()
            Button(action: { vm.onShowProviderManager?() }) {
                Label("管线管理", systemImage: "slider.horizontal.3")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("管线操作")
    }

    private var launchActionButton: some View {
        Button(action: triggerLaunch) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 12))
                Text("启动")
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(width: 96, height: 22)
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("启动一个新 Claude 会话")
    }

    private func triggerLaunch() {
        vm.onLaunch?(vm.selectedProvider, vm.selectedProject, vm.selectedTerminal)
    }

    private var sessionsSection: some View {
        sectionCard {
            collapsibleHeader("会话", icon: "bolt.horizontal.circle",
                              trailing: "\(vm.sessions.count) 个", collapsed: $sessionsCollapsed)
            if !sessionsCollapsed {
            if let warning = vm.registryWarning {
                // 读不到/解析不了登记表时明说原因，别让用户对着空列表猜
                Text("⚠️ \(warning)")
                    .font(.system(size: 10.5))
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }
            if vm.sessions.isEmpty {
                Text(vm.registryWarning == nil ? "没有存活的 claude 进程" : "（登记表不可用，暂时列不出会话）")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            // ⚠️ 疑似卡死的行置顶，其余保持原序（稳定排序）
            let orderedSessions = vm.sessions.sorted { a, b in
                let sa = vm.sessionHud[a.pid]?.isStuck ?? false
                let sb = vm.sessionHud[b.pid]?.isStuck ?? false
                return sa && !sb
            }
            ForEach(Array(orderedSessions.enumerated()), id: \.element.pid) { idx, session in
                let isAdopted = session.terminal == "adopted"
                let title = vm.sessionTitles[session.pid]
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(providerColor(session.provider))
                        .frame(width: 3)
                        .padding(.vertical, 2)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(session.num != nil ? "#\(session.sessionNumber)" : "pid \(session.pid)")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.85))

                            // 标题优先：让人一眼把这行对上 claude --resume 里的对话；
                            // 还没生成 ai-title 的新会话退回项目名。
                            Text(title ?? session.projectName)
                                .font(.system(size: 13, weight: title != nil ? .medium : .regular))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(title != nil ? "对话：\(title!)\n项目：\(session.project)" : session.project)

                            if session.num == nil {
                                // 无 TTY = 别的会话的后台工人（子 agent / 脚本里的 claude -p），
                                // 不是可以走进去操作的对话，所以措辞和来源都分开写清楚
                                let headless = session.tty == "??" || session.tty.isEmpty
                                Text(headless ? "后台" : "直接启动")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                                    .help(headless
                                          ? "没有终端的 claude 进程：通常是某个会话派生的子 agent，或脚本里的 claude -p。只展示、不收编，免得白占永久登记号"
                                          : "此会话是你在终端直接运行 claude 启动的，没有 ccpod 登记号（所以显示 pid），也只能查看不能管理；要用切线路等功能，请从 ccpod 启动会话")
                            } else if isAdopted {
                                Text("已收编")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                                    .help("原本直接启动的会话已被 ccpod 收编：可关闭、可「新窗口继承」切线")
                            }

                            Spacer()

                            if vm.sessionIDs[session.pid] != nil {
                                Button(action: { vm.onRename?(session) }) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary.opacity(0.65))
                                        .padding(4)                 // 放大命中区：图标本体只有十来像素，
                                        .contentShape(Rectangle())  // 差一两像素就点空（用户投诉过）
                                }
                                .buttonStyle(.plain)
                                .help("重命名这个对话（写进会话记录，claude --resume 列表同步变化）")
                            }

                            if session.num != nil {
                                Button(action: { vm.onClose?(session) }) {
                                    Image(systemName: session.isOrphan ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(session.isOrphan ? .orange : .secondary.opacity(0.5))
                                }
                                .buttonStyle(.plain)
                                .help(session.isOrphan ? "🧟 清理孤儿会话 #\(session.sessionNumber)（终端已关，进程仍在）" : "关闭 #\(session.sessionNumber)")
                            }
                        }

                        // session-hud：任务/工具/状态实时行（一期 hook 数据）
                        if let hud = vm.sessionHud[session.pid] {
                            HStack(spacing: 6) {
                                // SF Symbols：系统原生、风格统一；语义与终端字符一一对应（hud.glyph 留在 help 里）
                                Image(systemName: hudSymbolName(hud))
                                    .font(.system(size: 10))
                                    .foregroundColor(hudSymbolColor(hud))
                                Text(hud.tool.isEmpty ? hud.task : "\(hud.task) · \(hud.tool)")
                                    .font(.system(size: 11))
                                    .foregroundColor(hud.isStuck ? .orange : .secondary.opacity(0.85))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(hud.lastTs, style: .relative)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                            .help(hud.isStuck
                                  ? "⚠️ busy 但双源最后活动都很久没有更新：疑似卡死（也可能是超长工具在跑，警示非判决）"
                                  : "session-hud：\(hud.glyph) \(hud.task)\(hud.tool.isEmpty ? "" : " · \(hud.tool)")")
                        }

                    if session.num == nil {
                        HStack(spacing: 8) {
                            if title != nil {
                                Text(session.projectName)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary.opacity(0.8))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(-1)
                            }
                            Text(providerDisplayName(session.provider))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(Capsule())
                            if let model = session.model {
                                Text(gatewayModelDisplayName(model))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            if let at = session.lastActive {
                                Text(at, style: .relative)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.7))
                            }
                        }
                    } else {
                    HStack(spacing: 8) {
                        if title != nil {
                            Text(session.projectName)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.8))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(-1)
                        }
                        Menu {
                            ForEach(vm.providers, id: \.self) { p in
                                if !isAdopted {
                                    Button("切换到 \(providerDisplayName(p))") {
                                        if p != session.provider {
                                            vm.onSwitch?(session, p)
                                        }
                                    }
                                }
                                Button("新窗口继承到 \(providerDisplayName(p))") {
                                    vm.onRecover?(session, p)
                                }
                            }
                        } label: {
                            Text(providerDisplayName(session.provider))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(Capsule())
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        // 只给查得到的线路标额度；"官网查看/未接入"在会话里是噪音
                        if let bal = vm.balances[session.provider], bal.status == .ok {
                            HStack(spacing: 4) {
                                if let progress = bal.tightestWindow?.progress {
                                    QuotaRing(progress: progress, diameter: 10, lineWidth: 2)
                                }
                                Text(bal.shortText)
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundColor(quotaTone(bal))
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                    }
                    }

                    }
                    .padding(.leading, 8)
                }
                .padding(.vertical, 2)
                if idx < vm.sessions.count - 1 {
                    Divider().padding(.vertical, 1)
                }
            }
            }
        }
    }






    // 合盖保持唤醒（2026-10-06）：三态——unavailable 给授权入口，off/on 是开关。
    // 状态真源在 pmset，弹窗每次打开由 StatusController 调 refresh() 对账。
    private var sleepSwitchSection: some View {
        sectionCard {
            HStack(spacing: 8) {
                sectionHeader("合盖保持唤醒", icon: "battery.100.bolt")
                Spacer()
                switch sleepSwitch.state {
                case .unavailable:
                    Button {
                        sleepSwitch.provision { _ in }
                    } label: {
                        Label(sleepSwitch.busy ? "授权中…" : "一键授权", systemImage: "lock.shield")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                    .disabled(sleepSwitch.busy)
                    .help("首次使用需要一次性授权（安装 helper + 免密规则 + 看门狗）")
                    Button {
                        sleepSwitch.copyManualCommand()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("复制手动安装命令（终端执行）")
                case .off, .on:
                    Toggle("", isOn: Binding(
                        get: { sleepSwitch.state == .on },
                        set: { sleepSwitch.setOn($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(sleepSwitch.busy)
                    .help("开启后合盖不睡眠、不断网；电量过低时自动恢复")
                }
            }
            if sleepSwitch.state == .on {
                Text("合盖后系统保持联网。电量低于 20% 时自动关闭并通知。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var quitSection: some View {
        VStack(spacing: 6) {
            Divider().padding(.horizontal, 4)
            HStack {
                Button(action: { vm.onShowErrorDiagnosis?() }) {
                    Label("错误诊断", systemImage: "stethoscope")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("粘贴 API 错误返回，AI 给出中文解读")
                Spacer()
                Button(action: { vm.onQuit?() }) {
                    Label("退出 ccpod", systemImage: "power")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func providerColor(_ provider: String) -> Color {
        switch provider {
        case "official": return .green
        case "easyclaude": return .blue
        case "minimax": return .orange
        case "glm": return .purple
        case "volcengine": return .red
        case "tencent": return .blue
        case "aliyun": return .brown
        case "deepseek": return .cyan
        case "kimi": return .yellow
        default: return .gray
        }
    }



}

struct ProviderDropdown: View {
    let providers: [String]
    let balances: [String: BalanceInfo]
    let healthStates: [String: HealthInfo]
    @Binding var selected: String

    @State private var showMenu: Bool = false

    var body: some View {
        Button(action: { showMenu.toggle() }) {
            HStack(spacing: 8) {
                statusRing(for: selected, diameter: 18, lineWidth: 2.5)
                Text(providerDisplayName(selected))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                if let summary = quickSummary(for: selected) {
                    Text(summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(providers, id: \.self) { p in
                    ProviderDropdownRow(
                        name: p,
                        displayName: providerDisplayName(p),
                        balance: balances[p],
                        health: healthStates[p],
                        selected: selected == p
                    ) {
                        selected = p
                        showMenu = false
                    }
                    if p != providers.last {
                        Divider().padding(.horizontal, 8)
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(width: 300)
        }
    }

    @ViewBuilder
    private func statusRing(for provider: String, diameter: CGFloat, lineWidth: CGFloat) -> some View {
        let bal = balances[provider]
        let exhausted = healthStates[provider]?.availabilityReason == .quotaExhaustedDaily
            || (bal?.tightestWindow?.progress ?? 0) >= 1
        ZStack {
            if let progress = bal?.tightestWindow?.progress {
                QuotaRing(progress: progress, diameter: diameter, lineWidth: lineWidth)
            } else {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
                    .frame(width: diameter, height: diameter)
            }
            if exhausted {
                Image(systemName: "xmark")
                    .font(.system(size: diameter * 0.55, weight: .bold))
                    .foregroundColor(.red)
            }
        }
    }

    private func quickSummary(for provider: String) -> String? {
        guard let bal = balances[provider], let win = bal.tightestWindow else { return nil }
        let expiry = expiryShortText(win.expiresAt)
        return [win.summaryText, expiry].compactMap { $0 }.joined(separator: " · ")
    }

    private func expiryShortText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return "已到期" }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfExpiryDay = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfToday, to: startOfExpiryDay).day ?? 0

        if days > 0 { return "\(days)天" }
        return "今日到期"
    }
}

struct ProviderDropdownRow: View {
    let name: String
    let displayName: String
    let balance: BalanceInfo?
    let health: HealthInfo?
    let selected: Bool
    let onTap: () -> Void

    @State private var hovered: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    if let progress = balance?.tightestWindow?.progress {
                        QuotaRing(progress: progress, diameter: 22, lineWidth: 2.8, showPercent: true)
                    } else {
                        Circle()
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 2.8)
                            .frame(width: 22, height: 22)
                        Text("—").font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                    if exhausted {
                        Circle().fill(Color.red.opacity(0.18)).frame(width: 22, height: 22)
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundColor(.primary)
                    Text(detailText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(exhausted ? .red : .secondary)
                }

                Spacer(minLength: 4)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var exhausted: Bool {
        if health?.availabilityReason == .quotaExhaustedDaily { return true }
        if let p = balance?.tightestWindow?.progress, p >= 1 { return true }
        return false
    }

    private var detailText: String {
        if exhausted { return "已用尽" }
        if let message = balance?.status.message { return message }
        if let win = balance?.tightestWindow {
            let expiry = expiryShortText(win.expiresAt)
            return [win.label + " " + win.amountText, expiry].compactMap { $0 }.joined(separator: " · ")
        }
        if let bal = balance, bal.remaining > 0 {
            return String(format: "剩余 $%.1f", bal.remaining)
        }
        return "无每日额度数据"
    }

    private func expiryShortText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return "已到期" }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfExpiryDay = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfToday, to: startOfExpiryDay).day ?? 0

        if days > 0 { return "\(days)天" }
        return "今日到期"
    }
}


/// 管线展开区：套餐现状（全部窗口、续费日、更新时间、↻ 强制刷新）。
private struct LineQuotaDetail: View {
    let balance: BalanceInfo?
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("套餐现状")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                if let balance, !balance.planName.isEmpty {
                    Text(balance.planName)
                        .font(.system(size: 10))
                        .foregroundColor(.primary.opacity(0.8))
                }
                Spacer()
                if let balance {
                    Text(updatedText(balance.updatedAt))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("立即重新查询额度")
            }
            if let balance {
                if let detail = balance.planDetail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = balance.status.message {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(balance.windows) { window in
                    HStack(spacing: 6) {
                        if let progress = window.progress {
                            QuotaRing(progress: progress, diameter: 16, lineWidth: 2.2)
                        }
                        Text(window.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(minWidth: 40, alignment: .leading)
                        Text(window.amountText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer(minLength: 4)
                        if window.total > 0, let reset = window.resetAt, reset > Date() {
                            Text(QuotaAdapters.resetPhrase(reset))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if let renew = renewText(balance) {
                    Text(renew)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("还没有额度数据，点 ↻ 查询")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.leading, 17)
    }

    private func renewText(_ balance: BalanceInfo) -> String? {
        guard let renew = balance.renewAt else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                   to: Calendar.current.startOfDay(for: renew)).day ?? 0
        let verb = balance.autoRenew ? "自动续费" : "到期"
        return "\(fmt.string(from: renew)) \(verb)（剩 \(max(days, 0)) 天）"
    }

    private func updatedText(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚更新" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前更新" }
        return "\(seconds / 3600) 小时前更新"
    }
}

struct QuotaRing: View {
    let progress: Double
    var diameter: CGFloat = 16
    var lineWidth: CGFloat = 2.5
    var showPercent: Bool = false

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(tint(clamped), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: clamped)
            if showPercent {
                Text("\(Int(clamped * 100))")
                    .font(.system(size: max(diameter * 0.38, 8), weight: .semibold, design: .rounded))
                    .foregroundColor(tint(clamped))
                    .monospacedDigit()
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func tint(_ p: Double) -> Color {
        if p >= 0.9 { return .red }
        if p >= 0.75 { return .orange }
        return .accentColor
    }
}

private struct ScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
