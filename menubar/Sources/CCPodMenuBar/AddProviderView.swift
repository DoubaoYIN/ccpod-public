import SwiftUI

struct AddProviderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTemplate: ProviderTemplate?
    @State private var selectedPlanIndex = 0
    @State private var fieldValues: [String: String] = [:]
    @State private var customName: String = ""
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
        .frame(width: 340, height: 380)
        .interactiveDismissDisabled(isSaving)
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
                                customName = tpl.id == "relay" ? "" : tpl.id
                                selectedPlanIndex = 0
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
                        TextField("provider 名称", text: $customName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
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
                            if let model = tpl.plans[selectedPlanIndex].defaultModel {
                                fieldValues["model"] = model
                            }
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
                    if let keyNote = currentPlan(tpl)?.keyNote, !keyNote.isEmpty {
                        Text("🔑 \(keyNote)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Text("保存前会用真实请求实测一次：地址、key、模型名任一不对都会被拦下，不会存进一条用不了的线路")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if let err = errorMessage {
                        Text(err).font(.system(size: 11)).foregroundColor(.red)
                    }
                }
                .padding(12)
            }
            Spacer()
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
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard isValidProviderID(name) else {
            errorMessage = "名称只能包含字母、数字、点、下划线、短横线"
            return
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
