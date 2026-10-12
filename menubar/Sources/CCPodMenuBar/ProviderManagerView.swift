import SwiftUI
import AppKit

struct ProviderConfig: Identifiable {
    var id: String { name }
    var name: String
    var baseURL: String
    var key: String
    var keyEnvName: String
    var model: String
    var rawEnv: [String: Any]
    /// 密钥是钥匙串引用（`{"$exec": …}`）而不是明文。这种线路编辑器**不显示也不改写**密钥：
    /// 显示真值会导致保存时把明文写回文件，等于把搬家白做一遍。
    var keyIsSecretRef: Bool = false
    var claudeArgs: [String]
    var gateway: String?
    var extras: [String: Any]
}

struct ProviderManagerView: View {
    @ObservedObject private var gatewayLines = GatewayLineService.shared
    @ObservedObject var gateway: CCRGatewayService
    @ObservedObject var lineCheck: LineCheckService
    @State private var providers: [ProviderConfig] = []
    @State private var editing: ProviderConfig?
    @State private var showAddSheet: Bool = false
    @State private var showImportSheet: Bool = false
    @State private var saving = false
    @State private var pendingDelete: ProviderConfig?
    @State private var errorMessage: String?
    @State private var balances: [String: BalanceInfo] = [:]
    /// 点开了报错详情的管线：报错默认收起，只挂 ⚠️，点了才展开全文
    @State private var shownProblems: Set<String> = []
    /// 优惠页地址的编辑草稿，key = cfg.name。
    /// 用字典而不是单个 @State：管线列表里多行同时可见，共用一个草稿会互相串。
    /// 键不存在 = 用户没编辑过这一行，此时直接显示已保存值（见 promoDraftBinding）。
    @State private var promoDrafts: [String: String] = [:]
    /// 线路/网关上游名 → key 指纹（多账号时对号入座）
    @State private var fingerprints: [String: String] = [:]
    /// 从弹窗「添加管线…」进来时，窗口一出现就弹添加表单
    var openAddOnAppear = false
    /// 从弹窗某条直连线路的「编辑此线路」进来时，窗口一出现就弹这条线路的编辑框
    /// （原来只打开整个管理窗口，还得自己再找那条线路，2026-10-09）
    var openEditOnAppear: String? = nil
    var onChange: (() -> Void)?
    /// 窗口已开着时再点「添加管线…」：窗口不重建，靠通知弹表单
    static let openAddNotification = Notification.Name("ccpod.providerManager.openAdd")
    /// 同上，「编辑此线路」：object = 线路名
    static let openEditNotification = Notification.Name("ccpod.providerManager.openEdit")

    private let providersDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/providers", isDirectory: true)
    }()

    var body: some View {
        VStack(spacing: 0) {
            tierCard
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 460, height: 700)
        .sheet(item: $editing) { config in
            ProviderEditView(
                config: config,
                onSave: { updated in
                    save(updated)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
        .sheet(isPresented: $showAddSheet) {
            AddProviderView(onComplete: {
                load()
                refreshBalances(force: true)
                showAddSheet = false
                onChange?()
            })
        }
        .sheet(isPresented: $showImportSheet) {
            ProviderImportView(onComplete: {
                load()
                refreshBalances(force: true)
                onChange?()
            })
        }
        .alert(item: $pendingDelete) { cfg in
            Alert(
                title: Text("删除管线 \"\(providerDisplayName(cfg.name))\"？"),
                message: Text("此操作不可撤销。配置文件将被删除。"),
                primaryButton: .destructive(Text("删除")) { delete(cfg) },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.openAddNotification)) { _ in
            showAddSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.openEditNotification)) { note in
            guard let name = note.object as? String else { return }
            load()
            editing = providers.first { $0.name == name }
        }
        .onAppear {
            if openAddOnAppear { showAddSheet = true }
            loadFingerprints()
            load()
            if let name = openEditOnAppear { editing = providers.first { $0.name == name } }
            loadCachedBalances()
            gatewayLines.refresh { load(); onChange?() }
        }
    }

    /// 全局默认档位区（B 方案）：五档映射是全局单例（profile.claudeCode），
    /// 固定常驻窗口顶部，不进 ScrollView——语义上它不属于任何单条线路。
    private var tierCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("默认档位（不点名模型时的去处）")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.85))
            }
            LineSettingsEditor(gateway: gateway, lineCheck: lineCheck, onSaved: {
                load()
                onChange?()
            })
            Text("用于新会话；已运行的会话保持原模型")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var list: some View {        ScrollView {
            VStack(spacing: 6) {
                if providers.isEmpty {
                    Text("暂无管线")
                        .foregroundColor(.secondary)
                        .padding(.top, 24)
                }
                ForEach(providers) { cfg in
                    row(cfg)
                }
                if let err = errorMessage {
                    Text(err).font(.system(size: 11)).foregroundColor(.red).padding(.top, 4)
                }
                if let err = gatewayLines.lastError {
                    Text(gatewayVisibleText(err)).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .padding(12)
        }
    }

    private func row(_ cfg: ProviderConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(providerColor(cfg.name))
                    .frame(width: 10, height: 10)
                Text(providerDisplayName(cfg.name))
                    .font(.system(size: 13, weight: .semibold))
                providerStatusView(for: cfg.name)
                Spacer()
                if cfg.extras["source"] as? String == "gateway" {
                    Text("来自网关")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                        .help("管线由网关同步，可在此设置默认模型和思考强度")
                } else {
                Button(action: { editing = cfg }) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(saving)
                .help("编辑")
                Button(action: { pendingDelete = cfg }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.red.opacity(0.85))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(saving)
                .help("删除")
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                if shownProblems.contains(cfg.name), let detail = HealthService.shared.cached(cfg.name)?.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if cfg.extras["source"] as? String == "gateway" {
                    defaultModelPicker(cfg)
                    // 优惠页只对 gateway 管线开放：PromotionService 的清单就是从
                    // GatewayLineService.readLines 建的，非 gateway 条目填了也没人抓。
                    // 与其让它填了没用，不如一开始就不显示。
                    promoURLField(cfg)
                        .padding(.top, 4)
                }
                if cfg.extras["source"] as? String != "gateway", !cfg.baseURL.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "link").font(.system(size: 10)).foregroundColor(.secondary)
                        Text(gatewayVisibleText(cfg.baseURL))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let fp = fingerprints[(cfg.extras["gateway_provider"] as? String) ?? cfg.name] {
                    HStack(spacing: 4) {
                        Image(systemName: "key.fill")
                        Text(cfg.keyIsSecretRef ? "钥匙串 · 指纹 \(fp)" : "网关 · 指纹 \(fp)")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .help("key 的 SHA256 前 6 位：同一把 key 指纹相同，用来区分同厂商的不同账号；不可还原出 key")
                } else if cfg.keyIsSecretRef {
                    HStack(spacing: 4) {
                        Image(systemName: "key.fill")
                        Text("密钥保存在钥匙串")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                } else if !cfg.key.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "key").font(.system(size: 10)).foregroundColor(.secondary)
                        Text("已配置密钥（保存时迁入钥匙串）")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                if cfg.extras["source"] as? String != "gateway", !cfg.model.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu").font(.system(size: 10)).foregroundColor(.secondary)
                        Text(gatewayModelDisplayName(cfg.model))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                if let balance = balances[cfg.name] {
                    ProviderQuotaSummaryView(balance: balance)
                        .padding(.top, 4)
                }
            }
            .padding(.leading, 18)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func defaultModelPicker(_ cfg: ProviderConfig) -> some View {
        let models = cfg.extras["gateway_models"] as? [String] ?? []
        let current = cfg.extras["gateway_model"] as? String ?? ""
        let savedEffort = cfg.extras["effort"] as? String ?? ""
        let currentEffort = GatewayLineService.effortLevels.contains(savedEffort) ? savedEffort : ""
        return VStack(alignment: .leading, spacing: 4) {
            Picker("默认模型", selection: Binding(
                get: { current },
                set: { model in
                    guard model != current, models.contains(model), !saving else { return }
                    saving = true
                    errorMessage = nil
                    gatewayLines.setDefaultModel(providerID: cfg.name, model: model) { error in
                        saving = false
                        if let error {
                            errorMessage = gatewayVisibleText(error)
                        } else {
                            load()
                            onChange?()
                        }
                    }
                }
            )) {
                if !models.contains(current) {
                    Text(current.isEmpty ? "等待模型同步" : modelDisplayName(current) + "（当前）")
                        .tag(current)
                        .disabled(true)
                }
                ForEach(models, id: \.self) { model in
                    Text(modelDisplayName(model)).tag(model).help(model)
                }
            }
            .font(.system(size: 12))
            .pickerStyle(.menu)
            .disabled(saving || gatewayLines.refreshing || models.isEmpty)
            Picker("思考强度", selection: Binding(
                get: { currentEffort },
                set: { value in
                    guard value != currentEffort, !saving else { return }
                    saving = true
                    errorMessage = nil
                    gatewayLines.setDefaultEffort(providerID: cfg.name, effort: value.isEmpty ? nil : value) { error in
                        saving = false
                        if let error {
                            errorMessage = gatewayVisibleText(error)
                        } else {
                            load()
                            onChange?()
                        }
                    }
                }
            )) {
                Text("跟随全局设置").tag("")
                ForEach(GatewayLineService.effortLevels, id: \.self) { level in
                    Text(level == "max" ? effortDisplayName(level) + "（最慢、最费额度）" : effortDisplayName(level)).tag(level)
                }
            }
            .font(.system(size: 12))
            .pickerStyle(.menu)
            .disabled(saving || gatewayLines.refreshing)
            .help("新会话启动时带 --effort，会话里仍可用 /effort 临时改；「跟随全局设置」= 不带参数，按 settings 的 effortLevel")
            Text("用于新会话；运行中的会话可在会话菜单选「重启」套用，接着原对话")
                .font(.system(size: 10)).foregroundColor(.secondary)
            if let notice = cfg.extras["model_notice"] as? String {
                Text(gatewayVisibleText(notice)).font(.system(size: 10)).foregroundColor(.orange)
            }
        }
    }

    // MARK: - 优惠页地址（优惠雷达「跟着线路走」的入口，spec §9）

    private func savedPromoURL(_ cfg: ProviderConfig) -> String {
        cfg.extras["promo_url"] as? String ?? ""
    }

    /// 当前草稿，已去首尾空白。未编辑过时等于已保存值。
    private func promoDraftValue(_ cfg: ProviderConfig) -> String {
        (promoDrafts[cfg.name] ?? savedPromoURL(cfg))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func promoDraftBinding(_ cfg: ProviderConfig) -> Binding<String> {
        Binding(
            get: { promoDrafts[cfg.name] ?? savedPromoURL(cfg) },
            set: { promoDrafts[cfg.name] = $0 }
        )
    }

    /// value 传 nil = 用输入框里的草稿；传具体值 = 无视草稿（「清除」按钮走这条）。
    /// 显式传参而不是先改 @State 再读：@State 的写虽然同步，但依赖它会让
    /// 「点了清除却没清掉」这种 bug 只在某些渲染时序下出现，查起来要命。
    private func commitPromoURL(_ cfg: ProviderConfig, value: String? = nil) {
        let saved = savedPromoURL(cfg)
        let draft = (value ?? promoDraftValue(cfg))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 没变化就不写盘：省一次串行队列往返，也省一次 spinner 闪烁
        guard draft != saved, !saving else { return }
        saving = true
        errorMessage = nil
        gatewayLines.setPromoURL(providerID: cfg.name, url: draft.isEmpty ? nil : draft) { error in
            saving = false
            if let error {
                // 文案已在 setPromoURL 里过 gatewayVisibleText；这里的报错直接露给用户看，
                // 因为「地址无效」这类话用户必须能读懂才知道怎么改（用户偏好：UI 措辞别像报错码）
                errorMessage = error
                return
            }
            promoDrafts[cfg.name] = nil   // 清草稿，让 get 回到「显示已保存值」
            load()
            onChange?()
        }
    }

    private func promoURLField(_ cfg: ProviderConfig) -> some View {
        let saved = savedPromoURL(cfg)
        let draft = promoDraftValue(cfg)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "moon.stars")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextField("优惠页地址（公开的定价 / 活动页网址）", text: promoDraftBinding(cfg))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { commitPromoURL(cfg) }
                Button("保存") { commitPromoURL(cfg) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .disabled(saving || draft == saved)
                if !saved.isEmpty {
                    Button("清除") { commitPromoURL(cfg, value: "") }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .disabled(saving)
                }
            }
            Text("填厂商公开的定价或活动页。每天 21:00 抓一次，只读、只提醒——不改你的线路，不改网关。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .help("优惠雷达：抓这一页上的「分时段定价 / 限时优惠」，每天 21:30 汇总提醒。\n"
            + "只读公开页，不发密钥、不动配置。目前只有阿里云百炼的分时段定价有规则能自动读懂；\n"
            + "别的页填了也会在面板里标「⚠️ 读不出」，不会假装没事。")
    }

    @ViewBuilder
    private func providerStatusView(for provider: String) -> some View {
        if let health = HealthService.shared.cached(provider) {
            if health.availabilityReason == .quotaExhaustedDaily {
                exhaustedBadge.help(health.availabilityReason.detailText ?? "")
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundColor(healthColor(health.status))
                    .help(health.status == .down ? (health.detail ?? "") : health.speedTooltip)
            }
            if let detail = health.detail {
                if health.status == .down || health.status == .exhausted {
                    Button {
                        if shownProblems.contains(provider) { shownProblems.remove(provider) } else { shownProblems.insert(provider) }
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                    .help(shownProblems.contains(provider) ? "收起" : "有问题，点击查看")
                } else {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .help(detail)
                }
            }
        }
    }

    // 健康灯与 popover 的体检灯同一套：SF Symbols 圆点 + 语义色
    private func healthColor(_ status: ProviderHealth) -> Color {
        switch status {
        case .ok: return .green
        case .slow: return .yellow
        case .exhausted: return .orange
        case .down: return .red
        case .unknown: return .secondary.opacity(0.5)
        }
    }

    private var exhaustedBadge: some View {
        Text("已用尽")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.12))
            .clipShape(Capsule())
    }

    private var footer: some View {
        HStack {
            Button(action: {
                gatewayLines.refresh {
                    load()
                    refreshBalances(force: true)
                    onChange?()
                }
            }) {
                Label(gatewayLines.refreshing ? "同步中…" : "刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(gatewayLines.refreshing || saving)
            .help("同步网关管线并刷新余额")
            Spacer()
            Button(action: { showImportSheet = true }) {
                Label("导入旧配置", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .disabled(saving)
            Button(action: { showAddSheet = true }) {
                Label("添加管线", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(saving)
        }
        .padding(12)
    }

    private func loadCachedBalances() {
        for provider in providers.map(\.name) {
            if let cached = BalanceService.shared.cached(provider) {
                balances[provider] = cached
            }
        }
    }

    private func refreshBalances(force: Bool = false) {
        for provider in providers.map(\.name) {
            if let cached = BalanceService.shared.cached(provider) {
                balances[provider] = cached
            }
            BalanceService.shared.fetchBalance(provider: provider, force: force) { info in
                DispatchQueue.main.async {
                    guard let info else { return }
                    balances[provider] = info
                }
            }
        }
    }

    func load() {
        providers = ProviderService().availableProviders().compactMap { name in
            parseProvider(name: name, url: providersDir.appendingPathComponent(name).appendingPathExtension("json"))
        }
    }

    private func parseProvider(name: String, url: URL) -> ProviderConfig? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // 必须按 [String: Any] 读：密钥可能是 {"$exec": …} 字典。原来强转 [String: String]，
        // 一遇到 $exec 就整体失败 → rawEnv 变空 → 保存时把 BASE_URL 和 key 一起删掉，
        // 之后 get_provider_env 只输出 unset，claude 以无 key 无 base_url 启动
        // （正是历史上"静默用掉无限额 key"那个事故的形状）。
        let rawEnv = (obj["env"] as? [String: Any]) ?? [:]
        let baseURL = SecretResolver.value(from: rawEnv["ANTHROPIC_BASE_URL"]) ?? ""
        let keyEnvName = ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_API_TOKEN"]
            .first(where: { rawEnv[$0] != nil }) ?? "ANTHROPIC_API_KEY"
        let keyIsSecretRef = (rawEnv[keyEnvName] as? [String: Any]) != nil
        // 引用不解析进 UI；旧明文也只放在 SecureField 中。
        let key = keyIsSecretRef ? "" : (SecretResolver.value(from: rawEnv[keyEnvName]) ?? "")

        let claudeArgs = (obj["claude_args"] as? [String]) ?? []
        var model = SecretResolver.value(from: rawEnv["ANTHROPIC_MODEL"]) ?? ""
        if let i = claudeArgs.firstIndex(of: "--model"), i + 1 < claudeArgs.count {
            model = claudeArgs[i + 1]
        }

        let gateway = obj["gateway"] as? String

        var extras = obj
        extras.removeValue(forKey: "env")
        extras.removeValue(forKey: "claude_args")

        return ProviderConfig(
            name: name,
            baseURL: baseURL,
            key: key,
            keyEnvName: keyEnvName,
            model: model,
            rawEnv: rawEnv,
            keyIsSecretRef: keyIsSecretRef,
            claudeArgs: claudeArgs,
            gateway: gateway,
            extras: extras
        )
    }

    private func save(_ cfg: ProviderConfig) {
        var env = cfg.rawEnv
        if cfg.baseURL.isEmpty {
            env.removeValue(forKey: "ANTHROPIC_BASE_URL")
        } else {
            env["ANTHROPIC_BASE_URL"] = cfg.baseURL
        }
        if env["ANTHROPIC_MODEL"] != nil {
            if cfg.model.isEmpty { env.removeValue(forKey: "ANTHROPIC_MODEL") }
            else { env["ANTHROPIC_MODEL"] = cfg.model }
        }
        if cfg.keyIsSecretRef && cfg.key.isEmpty {
            // 密钥在钥匙串里、用户也没填新的 → **原样保留**那个 $exec 字典。
            // 这里绝不能走 removeValue：那会把线路的密钥引用删掉，之后 claude 无 key 启动。
        } else if cfg.key.isEmpty {
            env.removeValue(forKey: cfg.keyEnvName)
        } else {
            env[cfg.keyEnvName] = cfg.key
            // env 的值现在是 Any（可能是 $exec 字典），只能按"存在与否"判断。
            // 用户既然填了明文 key，另一种 key 字段就该删掉，免得两份密钥打架。
            for otherName in ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_API_TOKEN"] where otherName != cfg.keyEnvName {
                env.removeValue(forKey: otherName)
            }
        }

        var args = cfg.claudeArgs
        if let i = args.firstIndex(of: "--model") {
            if cfg.model.isEmpty {
                args.remove(at: i)
                if i < args.count { args.remove(at: i) }
            } else if i + 1 < args.count {
                args[i + 1] = cfg.model
            } else {
                args.append(cfg.model)
            }
        } else if !cfg.model.isEmpty {
            args.append(contentsOf: ["--model", cfg.model])
        }

        var json: [String: Any] = cfg.extras
        json["env"] = env
        if !args.isEmpty { json["claude_args"] = args }

        let configToWrite = json
        saving = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ProviderImportService.write(configToWrite, line: cfg.name)
                DispatchQueue.main.async {
                    saving = false
                    errorMessage = nil
                    load()
                    refreshBalances(force: true)
                    onChange?()
                }
            } catch {
                DispatchQueue.main.async {
                    saving = false
                    errorMessage = "保存失败：\(gatewayVisibleText(error.localizedDescription))"
                }
            }
        }
    }

    private func loadFingerprints() {
        let dir = providersDir
        DispatchQueue.global(qos: .utility).async {
            let entries = KeyFingerprint.loadAll(providersDir: dir)
            var map: [String: String] = [:]
            for e in entries { map[e.line] = e.fingerprint }
            DispatchQueue.main.async { fingerprints = map }
        }
    }

    private func delete(_ cfg: ProviderConfig) {
        let url = providersDir.appendingPathComponent(cfg.name).appendingPathExtension("json")
        do {
            try FileManager.default.removeItem(at: url)
            // 只删这条线路专属的条目（ccpod-line-<名称>），且别的线路没引用它
            let service = "ccpod-line-\(cfg.name)"
            if cfg.keyIsSecretRef,
               (cfg.rawEnv[cfg.keyEnvName] as? [String: Any])?["$exec"] as? String == SecretResolver.keychainCommand(service: service),
               !providers.contains(where: { $0.name != cfg.name
                   && (($0.rawEnv[$0.keyEnvName] as? [String: Any])?["$exec"] as? String) == SecretResolver.keychainCommand(service: service) }) {
                SecretResolver.deleteKeychain(service: service)
            }
            errorMessage = nil
            balances.removeValue(forKey: cfg.name)
            load()
            onChange?()
        } catch {
            errorMessage = "删除失败: \(error.localizedDescription)"
        }
    }

    private func providerColor(_ provider: String) -> Color {
        switch provider {
        case "official": return .green
        case "easyclaude": return .blue
        case "minimax": return .orange
        case "glm": return .purple
        case "volcengine": return .red
        case "aliyun": return .brown
        case "deepseek": return .cyan
        case "kimi": return .yellow
        default: return .gray
        }
    }
}

private struct ProviderQuotaSummaryView: View {
    let balance: BalanceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = balance.status.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            ForEach(balance.primaryWindows(limit: 2)) { window in
                HStack(alignment: .center, spacing: 8) {
                    if let progress = window.progress {
                        QuotaRing(progress: progress, diameter: 24, lineWidth: 3, showPercent: true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(windowTitle(window))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(window.amountText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let lifecycle = lifecycleLabel(window) {
                        Text(lifecycle)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func resetLabel(_ date: Date) -> String {
        let remaining = max(Int(date.timeIntervalSinceNow), 0)
        let days = remaining / 86400
        let hours = (remaining % 86400) / 3600
        let minutes = (remaining % 3600) / 60
        if days > 0 { return "\(days)天\(hours)小时后重置" }
        if hours > 0 { return "\(hours)小时\(minutes)分钟后重置" }
        return "\(minutes)分钟后重置"
    }

    private func expiryLabel(_ date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return "已到期" }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfExpiryDay = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfToday, to: startOfExpiryDay).day ?? 0

        if days > 0 { return "剩余\(days)天" }
        return "今日到期"
    }

    private func lifecycleLabel(_ window: QuotaWindow) -> String? {
        expiryLabel(window.expiresAt) ?? window.resetAt.map(resetLabel)
    }

    private func windowTitle(_ window: QuotaWindow) -> String {
        switch window.period {
        case .fiveHour: return "5 小时用量"
        case .day: return "今日用量"
        case .week: return "本周用量"
        case .month: return "本月用量"
        case .unknown: return window.label.isEmpty ? "总用量" : window.label
        }
    }

    private func tint(_ progress: Double) -> Color {
        if progress >= 0.9 { return .red }
        if progress >= 0.75 { return .orange }
        return .accentColor
    }
}

private struct ProviderEditView: View {
    @State var config: ProviderConfig
    @FocusState private var focusedField: Field?
    var onSave: (ProviderConfig) -> Void
    var onCancel: () -> Void

    private enum Field: Hashable { case baseURL, apiKey, model }

    private static let presetModels: [String] = [
        "claude-opus-4-7",
        "claude-opus-4-6",
        "claude-sonnet-4-6",
        "claude-haiku-4-5",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(title: "连接") {
                        field(label: "Base URL") {
                            TextField("https://api.example.com", text: $config.baseURL)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .baseURL)
                        }
                    }

                    section(title: "鉴权") {
                        if config.keyIsSecretRef {
                            // 不写这句的话：用户看到空的 key 框会以为配置丢了，顺手粘一把进去，
                            // 保存就把明文写回 json——F1 想防的正是这个，UI 却在诱导它
                            Text("🔑 密钥保存在钥匙串。留空保留原引用，填写新值会更新钥匙串。")
                                .font(.system(size: 10.5))
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        field(label: "API Key") {
                            HStack(spacing: 6) {
                                SecureField(config.keyIsSecretRef ? "（钥匙串引用，留空即保留）" : "sk-...", text: $config.key)
                                    .focused($focusedField, equals: .apiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            }
                        }
                    }

                    section(title: "模型") {
                        field(label: "模型 ID") {
                            HStack(spacing: 6) {
                                TextField("可选, 例如 claude-opus-4-6", text: $config.model)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .focused($focusedField, equals: .model)

                                Menu {
                                    ForEach(Self.presetModels, id: \.self) { name in
                                        Button(name) { config.model = name }
                                    }
                                    Divider()
                                    Button("留空（让 provider 自行决定）") { config.model = "" }
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .frame(width: 24, height: 22)
                                        .contentShape(Rectangle())
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("从常用模型中选择")
                            }
                        }
                    }

                    metadataFooter
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }

            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("保存") { onSave(config) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
        }
        .frame(width: 440, height: 360)
        .task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            // 钥匙串线路不要把光标丢进空的 key 框：那等于催用户往里粘明文
            focusedField = config.keyIsSecretRef ? .baseURL : .apiKey
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .foregroundColor(.secondary)
            Text("编辑管线")
                .font(.system(size: 13, weight: .semibold))
            Text(providerDisplayName(config.name))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var metadataFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text("env: \(config.keyEnvName)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            if let gw = config.gateway {
                Text("·").foregroundColor(.secondary.opacity(0.5))
                Text("网关：\(gatewayVisibleText(gw))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            content()
        }
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .trailing)
            content()
        }
    }
}
