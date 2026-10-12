import SwiftUI

struct AddProviderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTemplate: ProviderTemplate?
    @State private var selectedPlanIndex = 0
    /// 🔑 说明是否展开（默认收起；换厂商、换计费模式都重新收起）
    @State private var keyNoteExpanded = false
    @State private var fieldValues: [String: String] = [:]
    @State private var customName: String = ""
    /// 用户手改过名称后，切换计费模式不再覆盖它
    @State private var nameEdited = false
    /// 已有 key 的指纹（后台加载），用于提示"同一把 key / 同厂商另一把 key"（多账号预案）
    @State private var existingKeys: [KeyFingerprint.Entry] = []
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var savingStage: String?
    var onComplete: (() -> Void)?

    private let templates = ProviderTemplate.builtIn
    private let providersDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/providers", isDirectory: true)
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let tpl = selectedTemplate {
                formSection(tpl)
            } else {
                templateList
            }
        }
        .frame(width: 340, height: 440)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            let dir = providersDir
            DispatchQueue.global(qos: .utility).async {
                let entries = KeyFingerprint.loadAll(providersDir: dir)
                DispatchQueue.main.async { existingKeys = entries }
            }
        }
    }

    private var header: some View {
        HStack {
            if selectedTemplate != nil {
                Button(action: { selectedTemplate = nil; fieldValues = [:]; errorMessage = nil }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
            Text(selectedTemplate?.displayName ?? "添加线路")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
        }
        .padding(12)
    }

    private var templateList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(ProviderTemplate.Category.allCases, id: \.rawValue) { cat in
                    let items = templates.filter { $0.category == cat }
                    if !items.isEmpty {
                        Text(cat.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                        ForEach(items, id: \.id) { tpl in
                            Button(action: {
                                selectedTemplate = tpl
                                selectedPlanIndex = 0
                                keyNoteExpanded = false
                                nameEdited = false
                                customName = tpl.id == "relay" ? "" : suggestedID(tpl, planIndex: 0)
                                fieldValues = tpl.plans.first?.defaultModel.map { ["model": $0] } ?? [:]
                                errorMessage = nil
                            }) {
                                HStack {
                                    Text(badgeEmoji(tpl.id))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tpl.displayName).font(.system(size: 13))
                                        Text(tpl.notes)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func formSection(_ tpl: ProviderTemplate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("名称").frame(width: 50, alignment: .trailing).font(.system(size: 12))
                        TextField("管线名称（可中文）", text: nameBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }
                    if let id = autoIDPreview(tpl) {
                        Text("中文等名称作显示名，内部 ID 自动用「\(id)」")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    if tpl.plans.count > 1 {
                        // 同一厂商的订阅 Plan 和按量付费是两套端点+两套 key，互不通用
                        // （2026-10-02 实测：Kimi Coding Plan key 打按量端点 401、百炼国内 key 打国际端点 401）。
                        //
                        // 用 radioGroup 而**不是** segmented：分段控件在 340pt 宽的 sheet 里装不下长中文标签，
                        // 实测固有宽度 —— MiniMax 三段 510pt（可用 316pt，溢出 194pt）、火山两段 408pt（溢出 92pt）、
                        // Kimi 两段 313pt（仅余 3pt）。且 SwiftUI 分段控件**既不换行也不滚动**，
                        // 只能溢出到框架外，表现就是"窗口显示不全"。竖排单选实测 207pt ✅ 余 109pt，
                        // 且三个选项全部可见——计费模式选错 = key 配错 = 401，是最不能选错的一项，不该藏在折叠里。
                        Picker("计费模式", selection: $selectedPlanIndex) {
                            ForEach(planGroups(tpl)) { group in
                                if let region = group.region {
                                    Section(region) {
                                        ForEach(group.indices, id: \.self) { i in
                                            Text(tpl.plans[i].label).tag(i)
                                        }
                                    }
                                } else {
                                    ForEach(group.indices, id: \.self) { i in
                                        Text(tpl.plans[i].label).tag(i)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .onChange(of: selectedPlanIndex) { _ in
                            // 没有默认模型的模式要清空：否则沿用上一个模式的模型名（如 Coding Plan 的
                            // doubao-seed-evolving 带进按量）→ 实测报"账号未开通该模型"，用户看不懂（2026-10-08）
                            fieldValues["model"] = tpl.plans[selectedPlanIndex].defaultModel ?? ""
                            if !nameEdited { customName = suggestedID(tpl, planIndex: selectedPlanIndex) }
                            keyNoteExpanded = false
                        }
                    } else if let only = tpl.plans.first {
                        HStack {
                            Text("计费").frame(width: 50, alignment: .trailing).font(.system(size: 12))
                            Text(only.label).font(.system(size: 12)).foregroundColor(.secondary)
                        }
                    }
                    ForEach(tpl.envKeys, id: \.envName) { field in
                        HStack {
                            Text(field.label).frame(width: 50, alignment: .trailing).font(.system(size: 12))
                            Group {
                                if field.isURL {
                                    TextField(field.placeholder, text: binding(for: field.envName))
                                } else {
                                    SecureField(field.placeholder, text: binding(for: field.envName))
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        }
                    }
                    HStack {
                        Text("模型名").frame(width: 50, alignment: .trailing).font(.system(size: 12))
                        TextField(currentPlan(tpl)?.defaultModel ?? "见官方文档", text: binding(for: "model"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }
                    if let notice = KeyFingerprint.notice(newKey: fieldValues["api_key"] ?? "",
                                                          baseURL: effectiveBaseURL(tpl), existing: existingKeys) {
                        Text(notice)
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let plan = currentPlan(tpl), !plan.keyNote.isEmpty {
                        // 默认只露第一句（填什么 key），其余点「详细说明」才展开：用户嫌表单下方小字太多、看不懂（2026-10-09）
                        VStack(alignment: .leading, spacing: 3) {
                            Text("🔑 \(plan.keyNoteLead)")
                            if !plan.keyNoteRest.isEmpty {
                                if keyNoteExpanded {
                                    Text(plan.keyNoteRest)
                                }
                                Button(keyNoteExpanded ? "收起说明" : "详细说明…") { keyNoteExpanded.toggle() }
                                    .buttonStyle(.plain)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(selectedPlanIndex)  // 强制重建：切计费模式时显示对应的 keyNote
                    }
                    Text("保存前会用真实请求实测一次：地址、key、模型名任一不对都会被拦下，不会存进一条用不了的线路")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(12)
            }
            // 报错放在滚动区外、按钮正上方：以前塞在表单末尾，长报错被挤出视野看不全（2026-10-08）
            if let err = errorMessage {
                ScrollView {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .padding(.horizontal, 12)
            }
            HStack {
                Spacer()
                Button(savingStage ?? "添加") { save(tpl) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isSaving || customName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .padding(.bottom, 12)
        }
    }

    private func effectiveBaseURL(_ tpl: ProviderTemplate) -> String {
        let relayURL = fieldValues["base_url"] ?? ""
        return relayURL.isEmpty ? (currentPlan(tpl)?.baseURL ?? "") : relayURL
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { customName },
            set: { customName = $0; nameEdited = true }
        )
    }

    /// 默认名 = 厂商-计费模式（如 volcengine-payg），一眼区分同厂商的订阅/按量；单模式厂商只用厂商 id。
    /// 重名自动加 -2、-3。
    private func suggestedID(_ tpl: ProviderTemplate, planIndex: Int) -> String {
        let base: String
        if tpl.plans.count > 1, tpl.plans.indices.contains(planIndex) {
            base = "\(tpl.id)-\(tpl.plans[planIndex].id)"
        } else {
            base = tpl.id
        }
        return uniqueID(base)
    }

    private func uniqueID(_ base: String) -> String {
        func exists(_ id: String) -> Bool {
            FileManager.default.fileExists(atPath: providersDir.appendingPathComponent(id).appendingPathExtension("json").path)
        }
        guard exists(base) else { return base }
        var n = 2
        while exists("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// 名称不能直接当 ID（含中文、空格等）时，内部 ID 用的自动值；能直接当 ID 时返回 nil
    private func autoIDPreview(_ tpl: ProviderTemplate) -> String? {
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isValidProviderID(name) else { return nil }
        return suggestedID(tpl, planIndex: selectedPlanIndex)
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { fieldValues[key, default: ""] },
            set: { fieldValues[key] = $0 }
        )
    }

    private func currentPlan(_ tpl: ProviderTemplate) -> ProviderTemplate.BillingPlan? {
        guard !tpl.plans.isEmpty else { return nil }
        return tpl.plans[min(selectedPlanIndex, tpl.plans.count - 1)]
    }

    /// 计费模式分组：nil=单站不分组；国内站前、国际站后。
    private struct PlanGroup: Identifiable {
        let region: String?
        let indices: [Int]
        var id: String { region ?? "" }
    }

    private func planGroups(_ tpl: ProviderTemplate) -> [PlanGroup] {
        var groups: [String?: [Int]] = [:]
        for (i, p) in tpl.plans.enumerated() {
            groups[p.region, default: []].append(i)
        }
        // 无分组（nil）最前 → 国内站 → 国际站；未列出的 region 按字母序兜底
        let order: [String?] = [nil, "国内站", "国际站"].filter { groups[$0] != nil }
        let extras = groups.keys
            .filter { k in !order.contains { $0 == k } }
            .sorted { ($0 ?? "") < ($1 ?? "") }
        return (order + extras).map { PlanGroup(region: $0, indices: groups[$0]!) }
    }

    private func save(_ tpl: ProviderTemplate) {
        let typed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        // 名称是 ID（文件名/钥匙串服务名/命令行参数）就只能是 ASCII；中文等名称存为 display_name，ID 自动生成
        let name: String
        var displayName: String?
        if isValidProviderID(typed) {
            name = typed
        } else {
            name = suggestedID(tpl, planIndex: selectedPlanIndex)
            displayName = typed
        }

        let filePath = providersDir.appendingPathComponent(name).appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: filePath.path) {
            errorMessage = "线路 \"\(name)\" 已存在"
            return
        }

        let model = (fieldValues["model"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            errorMessage = "要填模型名：不填的话 Claude Code 会拿 claude 系默认名去请求，大多数量产端点不认"
            return
        }
        let relayURL = fieldValues["base_url"] ?? ""
        let plan = currentPlan(tpl)
        let baseURL = relayURL.isEmpty ? (plan?.baseURL ?? "") : relayURL
        let apiKey = fieldValues["api_key"] ?? ""
        guard !baseURL.isEmpty, !apiKey.isEmpty else {
            errorMessage = "地址和 key 都要填：保存前要靠它们实测这条线路能不能通"
            return
        }

        isSaving = true
        savingStage = "实测中…"
        LinePreflight.check(baseURL: baseURL, apiKey: apiKey, model: model) { outcome in
            guard outcome.ok else {
                isSaving = false
                savingStage = nil
                errorMessage = outcome.message
                return
            }
            var json = tpl.generateJSON(values: fieldValues)
            // env 按 [String: Any] 读：值可能是 {"$exec": …} 引用，强转字符串字典会整体失败、静默丢 key（AGENTS.md）
            var env = (json["env"] as? [String: Any]) ?? [:]
            env["ANTHROPIC_BASE_URL"] = baseURL
            env["ANTHROPIC_MODEL"] = model
            json["env"] = env
            json["claude_args"] = ["--model", model]
            json["source"] = "manual"
            if let displayName { json["display_name"] = displayName }
            if let planID = plan?.id { json["billing_plan"] = planID }
            if let actual = outcome.actualModel, actual != model {
                json["preflight_actual_model"] = actual
            }
            let configToWrite = json
            savingStage = "保存中…"
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try ProviderImportService.write(configToWrite, line: name, allowOverwrite: false)
                    DispatchQueue.main.async {
                        isSaving = false
                        savingStage = nil
                        onComplete?()
                        dismiss()
                    }
                } catch {
                    DispatchQueue.main.async {
                        isSaving = false
                        savingStage = nil
                        errorMessage = "实测通过，但写入失败：\(gatewayVisibleText(error.localizedDescription))"
                    }
                }
            }
        }
    }

    private func badgeEmoji(_ id: String) -> String {
        switch id {
        case "minimax": return "🟠"
        case "glm": return "🟣"
        case "volcengine": return "🔴"
        case "tencent": return "🔵"
        case "aliyun": return "🟤"
        case "deepseek": return "🔷"
        case "kimi": return "🟡"
        case "baidu": return "🟦"
        case "meituan": return "🟨"
        case "jdcloud": return "🟥"
        case "zenmux": return "🟢"
        case "relay": return "🔗"
        default: return "⚪"
        }
    }
}
