import SwiftUI

// ProviderEditorView — 单条线路的条目编辑（类 CC Switch 每条目设置）。
// 编辑 api_base_url / api_key / models 列表，经 CCR 管理 RPC（saveConfig）保存，
// daemon 写自己的库——ccpod 只是第二个界面，不是第二个写入方。
// v1 边界：provider 名称是路由主键（provider/model），不可改；新增/删除线路仍在 CCR 控制台。
//
// 模型区（2026-10-02 重构）：结构化行列表替代"一行一个"文本框。
// - 🔄 拉取模型：GET 上游 /v1/models（ModelCatalogFetcher），拉到 ≠ 能调用，仅同步目录；
// - 徽标：🔒 档位/线路默认引用（禁删）⚠️ 历史 alias 引用（可删但警告）🟢 新发现 ⚫ 上游未返回 🟡 超代建议；
// - 护栏是保存时的硬约束（重算于最新配置），不只是 UI 禁用——防"编辑器开着时档位被改"的竞态。
struct ProviderEditorView: View {
    let providerName: String
    var onSaved: () -> Void

    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var revealKey = false
    @State private var status: String?
    @State private var busy = false
    @State private var loaded = false
    @State private var config: [String: Any]?
    /// 打开（或上次保存）时网关里的样子：保存时只把相对它的改动叠加到新鲜配置上（EditorDelta）
    @State private var openedModels: [String] = []
    @State private var openedURL = ""
    @State private var openedKey = ""

    @State private var rows: [ModelRow] = []
    @State private var fetching = false
    @State private var fetchNote: String?
    @State private var manualModel = ""
    @State private var probing = false
    @State private var probeDone = 0
    @State private var probeTotal = 0

    /// 前门可用性对照状态（ModelProber 结果的行内映射）
    private enum ProbeState: Equatable {
        case untested, probing
        case usable(mappedTo: String?)   // mappedTo 非空 = 端点实际路由到了别的模型
        case rejected(String)            // 明确不可用（附原因）
        case unverifiable(String)        // 无法从 ccpod 判定（⚠️ ≠ 不可用）

        var isUsable: Bool {
            if case .usable = self { return true }
            return false
        }
        var isRejected: Bool {
            if case .rejected = self { return true }
            return false
        }
        var isUnverifiable: Bool {
            if case .unverifiable = self { return true }
            return false
        }
    }

    private struct ModelRow: Identifiable {
        let id: String               // 模型裸名
        var keep: Bool               // 勾=保留/新增进配置；不勾=从配置删除
        var isNew = false            // 🟢 本次拉取新发现
        var missingUpstream = false  // ⚫ 上游成功返回的列表里没有（仅拉取成功后才置位）
        var stale = false            // 🟡 超代建议清理
        var lockReason: String?      // 非空 → 禁删（Toggle 禁用）
        var warnReason: String?      // 非空 → 警告但可删（历史 alias 引用）
        var probe: ProbeState = .untested
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !loaded {
                Text(busy ? "读取配置中…" : (status ?? ""))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 6) {
                    Text("URL")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 34, alignment: .leading)
                    TextField("https://…", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
                HStack(spacing: 6) {
                    Text("Key")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 34, alignment: .leading)
                    if revealKey {
                        TextField("sk-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    } else {
                        SecureField("sk-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                    Button {
                        revealKey.toggle()
                    } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                modelSection
                HStack(spacing: 10) {
                    Button {
                        save()
                    } label: {
                        Label(busy ? "保存中…" : "保存本条", systemImage: "checkmark.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(busy || fetching || probing ? .secondary : .accentColor)
                    .disabled(busy || fetching || probing)
                    if let status {
                        Text(status)
                            .font(.system(size: 10))
                            .foregroundColor(status.hasPrefix("✅") ? .green : .secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .padding(.leading, 14)
        .onAppear {
            if !loaded && !busy { load() }
        }
    }

    // MARK: - 模型区

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("模型")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                if rows.contains(where: { $0.stale && $0.keep && $0.lockReason == nil }) {
                    Button("按建议清理") { applyPruneSuggestions() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                        .help("取消勾选所有未锁定的 🟡 超代模型（保存时才真正生效）")
                }
                Button {
                    fetchModels()
                } label: {
                    Label(fetching || probing ? "获取中…" : "获取可用模型", systemImage: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(fetching || probing || busy ? .secondary : .accentColor)
                .disabled(fetching || probing || busy)
                .help("拉取上游名单，再逐个在本线路端点实测：只有真通的才进列表（每模型一发最小请求，约几十 token）")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach($rows) { row in
                        modelRow(row)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 200)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
            HStack(spacing: 6) {
                TextField("手动添加模型名", text: $manualModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { addManual() }
                Button("＋") { addManual() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                    .disabled(manualModel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let fetchNote {
                Text(fetchNote)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("能不能用只看本线路端点（前门）的实测：✅ 才进列表；❌ 与 ⚠️ 未通过验证的一律剔除")
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modelRow(_ row: Binding<ModelRow>) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: row.keep)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(row.wrappedValue.lockReason != nil)
            Text(row.wrappedValue.id)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            badges(for: row.wrappedValue)
        }
    }

    @ViewBuilder
    private func badges(for row: ModelRow) -> some View {
        switch row.probe {
        case .probing:
            badge("⏳ 验证中…")
        case .usable(let mapped):
            badge(mapped.map { "✅ 可用（实为 \($0)）" } ?? "✅ 可用")
        case .rejected(let reason):
            badge("❌ \(reason)")
        case .unverifiable(let reason):
            badge("⚠️ \(reason)")
        case .untested:
            EmptyView()
        }
        if let lock = row.lockReason {
            badge("🔒 \(lock)")
        } else if let warn = row.warnReason {
            badge("⚠️ \(warn)")
        }
        if row.isNew { badge("🟢 新发现") }
        if row.missingUpstream { badge("⚫ 上游未返回") }
        if row.stale && row.lockReason == nil { badge("🟡 建议清理") }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundColor(.secondary)
            .lineLimit(1)
    }

    // MARK: - 标注（护栏 + 超代建议）

    /// 重算每行的 🔒/⚠️/🟡 标注。config 用最近一次 fetchConfig 的快照；
    /// 保存时会用新鲜配置再算一次（硬约束在那边）。
    private func annotate(rows: [ModelRow], config: [String: Any], fetched: [String]) -> [ModelRow] {
        let guardrail = ModelGuardrail.evaluate(provider: providerName, config: config)
        let stale = ModelPruneAdvisor.staleSuggestions(rows.map(\.id), fetched: fetched)
        return rows.map { row in
            var annotated = row
            annotated.stale = stale.contains(annotated.id)
            annotated.lockReason = guardrail.locked[annotated.id]
            annotated.warnReason = guardrail.warned[annotated.id]
            if annotated.lockReason != nil { annotated.keep = true }
            return annotated
        }
    }

    // MARK: - 拉取 / 手动添加 / 清理

    private func fetchModels() {
        fetching = true
        fetchNote = "拉取模型目录中…"
        // 用输入框当前值（用户可能刚换 key），不是 load 时的快照
        let url = baseURL, key = apiKey
        let currentRows = rows
        let snapshot = config
        ModelCatalogFetcher.fetch(baseURL: url, apiKey: key) { outcome in
            guard let fetched = outcome.models else {
                fetchNote = "❌ \(outcome.message)"
                fetching = false
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var merged = currentRows
                let fetchedSet = Set(fetched)
                for index in merged.indices {
                    merged[index].missingUpstream = !fetchedSet.contains(merged[index].id)
                }
                let existing = Set(merged.map(\.id))
                let newOnes = fetched.filter { !existing.contains($0) }
                merged.append(contentsOf: newOnes.map { ModelRow(id: $0, keep: true, isNew: true) })
                if let snapshot {
                    merged = annotate(rows: merged, config: snapshot, fetched: fetched)
                }
                let catalogNote = newOnes.isEmpty
                    ? "目录共 \(fetched.count) 个模型，无新增"
                    : "目录共 \(fetched.count) 个模型，新发现 \(newOnes.count) 个"
                DispatchQueue.main.async {
                    rows = merged
                    fetching = false
                    // 目录到手后逐个在前门验证可用性（目录 ∩ 前门实测 = 可用模型）
                    startProbing(baseURL: url, apiKey: key, catalogNote: catalogNote)
                }
            }
        }
    }

    /// 并发 4 逐个探测（每模型一发最小请求，真实消耗几十 token——所以只由按钮手动触发）。
    /// rows 只在主线程变更；新行探测失败默认取消勾选（不进配置），已有行只标注不动勾选。
    private func startProbing(baseURL: String, apiKey: String, catalogNote: String) {
        let targets = rows.map(\.id)
        guard !targets.isEmpty else { fetchNote = catalogNote; return }
        probing = true
        probeDone = 0
        probeTotal = targets.count
        for index in rows.indices { rows[index].probe = .probing }
        fetchNote = "\(catalogNote)；验证可用性 0/\(targets.count)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let group = DispatchGroup()
            let gate = DispatchSemaphore(value: 4)
            for model in targets {
                gate.wait()
                group.enter()
                ModelProber.probe(baseURL: baseURL, apiKey: apiKey, model: model) { status in
                    DispatchQueue.main.async {
                        applyProbe(model: model, status: status)
                        group.leave()
                        gate.signal()
                    }
                }
            }
            group.notify(queue: .main) {
                probing = false
                // 用户规则（2026-10-02）：只有 ✅ 前门实测能用的才进列表；
                // ❌ 不可用和 ⚠️ 试不出来的都按不能用处理——新发现的直接剔除，
                // 已有的取消勾选（保存后移出；被档位/线路默认锁住的除外，护栏兜底）。
                let newUsable = rows.filter { $0.isNew && $0.probe.isUsable }.count
                let droppedRejected = rows.filter { $0.isNew && $0.probe.isRejected }.count
                let droppedUnclear = rows.filter { $0.isNew && $0.probe.isUnverifiable }.count
                rows.removeAll { $0.isNew && !$0.probe.isUsable }
                var existingDropped = 0
                for index in rows.indices where !rows[index].isNew && !rows[index].probe.isUsable
                    && rows[index].lockReason == nil {
                    rows[index].keep = false
                    existingDropped += 1
                }
                var note = "\(catalogNote)；对照完成：新进列表 \(newUsable) 个 ✅"
                let dropped = droppedRejected + droppedUnclear
                if dropped > 0 { note += "；剔除 \(dropped) 个（❌ \(droppedRejected) / ⚠️ \(droppedUnclear)）" }
                if existingDropped > 0 { note += "；已有 \(existingDropped) 个未通过验证已取消勾选" }
                fetchNote = note
            }
        }
    }

    private func applyProbe(model: String, status: ModelProber.Status) {
        guard let index = rows.firstIndex(where: { $0.id == model }) else { return }
        switch status {
        case .usable:
            rows[index].probe = .usable(mappedTo: nil)
        case .usableMapped(let actual):
            rows[index].probe = .usable(mappedTo: actual)
        case .rejected(let reason):
            rows[index].probe = .rejected(reason)
        case .unverifiable(let reason):
            rows[index].probe = .unverifiable(reason)
        }
        if rows[index].isNew && !status.isUsable { rows[index].keep = false }
        probeDone += 1
        if probing { fetchNote = fetchNote?.replacingOccurrences(
            of: #"验证可用性 \d+/\d+"#, with: "验证可用性 \(probeDone)/\(probeTotal)",
            options: .regularExpression) }
    }

    private func addManual() {
        let name = manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !rows.contains(where: { $0.id == name }) else { return }
        var next = rows
        next.append(ModelRow(id: name, keep: true))
        if let config {
            next = annotate(rows: next, config: config, fetched: [])
        }
        rows = next
        manualModel = ""
    }

    private func applyPruneSuggestions() {
        for index in rows.indices where rows[index].stale && rows[index].lockReason == nil {
            rows[index].keep = false
        }
    }

    // MARK: - 读取 / 保存（通路不变：getConfig → 只合并本条 → saveConfig）

    private func load() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let state = CCRConfigService.serviceState() else {
                    throw NSError(domain: "provider-editor", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "读不到网关运行信息（网关未运行？）"])
                }
                let config = try CCRConfigService.fetchConfig(state: state)
                guard let providers = config["Providers"] as? [[String: Any]],
                      let entry = providers.first(where: { ($0["name"] as? String) == providerName }) else {
                    throw NSError(domain: "provider-editor", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "配置里找不到线路 \(gatewayProviderDisplayName(providerName))"])
                }
                let models = (entry["models"] as? [Any])?.compactMap { $0 as? String } ?? []
                let initialRows = annotate(rows: models.map { ModelRow(id: $0, keep: true) },
                                           config: config, fetched: [])
                DispatchQueue.main.async {
                    baseURL = entry["api_base_url"] as? String ?? ""
                    apiKey = entry["api_key"] as? String ?? ""
                    openedURL = baseURL
                    openedKey = apiKey
                    openedModels = models
                    rows = initialRows
                    self.config = config
                    loaded = true
                    busy = false
                }
            } catch {
                DispatchQueue.main.async {
                    status = "❌ \(gatewayVisibleText(error.localizedDescription))"
                    busy = false
                }
            }
        }
    }

    private func save() {
        busy = true
        status = nil
        let keptModels = rows.filter(\.keep).map(\.id)
        let opened = openedModels
        let urlEdit = EditorDelta.field(opened: openedURL, edited: baseURL)
        let keyEdit = EditorDelta.field(opened: openedKey, edited: apiKey)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let state = CCRConfigService.serviceState() else {
                    throw NSError(domain: "provider-editor", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "网关未运行，无法保存"])
                }
                // 保存时**重新取一次**网关配置，只把本窗口里的改动叠加上去（EditorDelta）。
                // 原来把窗口里的整份清单 / 地址 / key 写回：窗口开着期间别处的改动会被静默回滚
                // （新加的模型被抹掉、删掉的被复活、轮换过的 key 被改回旧的）。
                let config0 = try CCRConfigService.fetchConfig(state: state)
                var config = config0
                guard var providers = config["Providers"] as? [[String: Any]],
                      let index = providers.firstIndex(where: { ($0["name"] as? String) == providerName }) else {
                    throw NSError(domain: "provider-editor", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "配置里找不到线路 \(gatewayProviderDisplayName(providerName))"])
                }
                let freshModels = (providers[index]["models"] as? [Any])?.compactMap { $0 as? String } ?? []
                let delta = EditorDelta.models(opened: opened, kept: keptModels, fresh: freshModels)
                guard delta.changed || urlEdit != nil || keyEdit != nil else {
                    DispatchQueue.main.async {
                        status = "没有改动，没写网关"
                        busy = false
                    }
                    return
                }
                let finalURL = urlEdit ?? (providers[index]["api_base_url"] as? String ?? "")
                let finalKey = keyEdit ?? (providers[index]["api_key"] as? String ?? "")
                guard !finalURL.isEmpty, !finalKey.isEmpty else {
                    throw NSError(domain: "provider-editor", code: 5,
                                  userInfo: [NSLocalizedDescriptionKey: "URL / Key 不能为空"])
                }
                guard !delta.write.isEmpty else {
                    throw NSError(domain: "provider-editor", code: 6,
                                  userInfo: [NSLocalizedDescriptionKey: "至少保留一个模型"])
                }
                // 护栏硬约束：用**新鲜**配置重算，只查本次真正要删的（本窗口拉取后没勾选的新行不算删除）。
                let guardrail = ModelGuardrail.evaluate(provider: providerName, config: config0)
                let blocked = delta.removed.filter { guardrail.locked[$0] != nil }
                guard blocked.isEmpty else {
                    let reasons = blocked.map { "「\($0)」\(guardrail.locked[$0] ?? "")" }.joined(separator: "；")
                    throw NSError(domain: "provider-editor", code: 7,
                                  userInfo: [NSLocalizedDescriptionKey: "\(reasons)，已取消保存"])
                }
                if let urlEdit { providers[index]["api_base_url"] = urlEdit }
                if let keyEdit { providers[index]["api_key"] = keyEdit }
                providers[index]["models"] = delta.write
                config["Providers"] = providers
                _ = try CCRConfigService.rpc(method: "saveConfig", args: [config], state: state)
                let savedConfig = config
                DispatchQueue.main.async {
                    var note = "✅ 已保存，网关已更新线路配置"
                    if !delta.keptElsewhere.isEmpty {
                        note += "（窗口开着时别处新加的 \(delta.keptElsewhere.count) 个模型也一并留着：\(delta.keptElsewhere.joined(separator: "、"))）"
                    }
                    status = note
                    busy = false
                    // 界面以实际写入的清单为准，避免「显示的」与「网关里的」不一致
                    let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    let rebuilt = delta.write.map { id -> ModelRow in
                        var row = byID[id] ?? ModelRow(id: id, keep: true)
                        row.keep = true
                        row.isNew = false
                        row.missingUpstream = false
                        return row
                    }
                    rows = annotate(rows: rebuilt, config: savedConfig, fetched: [])
                    self.config = savedConfig
                    openedModels = delta.write
                    openedURL = finalURL
                    openedKey = finalKey
                    baseURL = finalURL
                    apiKey = finalKey
                    onSaved()
                }
            } catch {
                DispatchQueue.main.async {
                    status = "❌ \(gatewayVisibleText(error.localizedDescription))"
                    busy = false
                }
            }
        }
    }
}
