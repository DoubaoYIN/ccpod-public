import SwiftUI

struct ProviderImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ProviderImportCandidate] = []
    @State private var selected = Set<String>()
    @State private var notices: [String] = []
    @State private var loading = true
    @State private var importing = false
    @State private var resultMessage: String?
    /// 实测说明（候选 id → 人话），只做展示；不写进 unavailableReason，否则「仍然导入」会被 importSelected 拒绝
    @State private var preflightNotes: [String: String] = [:]
    /// 实测没过、先没导入的条目，等用户明确选择是否仍然导入
    @State private var heldBack: [ProviderImportCandidate] = []
    var onComplete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("导入旧线路").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.disabled(importing)
            }
            .padding(14)
            Divider()
            Text("勾选需要保留的直连线路，再点导入。导入前会对每条发一次最小真实请求实测能不能通；标记“网关已有”的配置通常无需重复导入。")
                .font(.system(size: 11)).foregroundColor(.secondary).padding(12)
            if loading {
                Spacer()
                HStack { Spacer(); ProgressView("读取旧配置并核验网关…"); Spacer() }
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if candidates.isEmpty { Text("没有可导入的旧线路").foregroundColor(.secondary) }
                        ForEach(candidates) { item in
                            Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { enabled in
                                if enabled { selected.insert(item.id) } else { selected.remove(item.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(item.displayName).font(.system(size: 12, weight: .medium))
                                        Spacer()
                                        Text(item.unavailableReason ?? item.gatewayStatus)
                                            .font(.system(size: 10)).foregroundColor(.secondary)
                                    }
                                    Text("\(item.sourceLabel) · \(item.endpoint)")
                                        .font(.system(size: 10)).foregroundColor(.secondary)
                                    Text(item.model).font(.system(size: 10)).foregroundColor(.secondary)
                                        .lineLimit(1)
                                    if let note = preflightNotes[item.id] {
                                        Text(note).font(.system(size: 10)).foregroundColor(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(importing || item.unavailableReason != nil)
                            Divider()
                        }
                        ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                            Text(notice).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        if let resultMessage {
                            Text(resultMessage).font(.system(size: 11)).textSelection(.enabled)
                        }
                        if !heldBack.isEmpty && !importing {
                            Button("仍然导入这 \(heldBack.count) 条（不等实测通过）") { importHeldBack() }
                        }
                    }
                    .padding(12)
                }
            }
            Divider()
            HStack {
                Button("重新读取") { scan() }.disabled(loading || importing)
                Spacer()
                Button(importing ? "正在实测并导入…" : "导入所选（\(selected.count)）") { importSelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading || importing || selected.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 500, height: 510)
        .interactiveDismissDisabled(importing)
        .onAppear { scan() }
    }

    private func scan() {
        loading = true
        selected = []
        resultMessage = nil
        preflightNotes = [:]
        heldBack = []
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ProviderImportService.scan()
            DispatchQueue.main.async {
                candidates = result.candidates
                notices = result.notices
                loading = false
            }
        }
    }

    /// 先实测再导入：与手动新增同一道闸（LinePreflight），但不硬拦——没通过的先留着，由用户决定。
    private func importSelection() {
        let chosen = candidates.filter { selected.contains($0.id) && $0.unavailableReason == nil }
        importing = true
        heldBack = []
        resultMessage = nil
        // $exec 取 key 最多卡 3 秒/条，不能在主线程做
        DispatchQueue.global(qos: .userInitiated).async {
            let plans = chosen.map { ($0, ProviderImportPreflight.plan(for: $0.json)) }
            DispatchQueue.main.async { runPreflight(plans) }
        }
    }

    private func runPreflight(_ plans: [(ProviderImportCandidate, ProviderImportPreflight.Plan)]) {
        var passed: [ProviderImportCandidate] = []
        var failed: [ProviderImportCandidate] = []
        let group = DispatchGroup()
        for (item, plan) in plans {
            switch plan {
            case .localGateway:
                preflightNotes[item.id] = ProviderImportPreflight.localGatewayNote
                passed.append(item)
            case .incomplete(let reason):
                preflightNotes[item.id] = reason
                failed.append(item)
            case let .probe(baseURL, apiKey, model):
                preflightNotes[item.id] = "实测中…"
                group.enter()
                // LinePreflight 自带 15s/25s 超时，回调在主线程，不会无限等
                LinePreflight.check(baseURL: baseURL, apiKey: apiKey, model: model) { outcome in
                    preflightNotes[item.id] = outcome.ok ? "实测通过" : "实测没通过：\(outcome.message)"
                    if outcome.ok { passed.append(item) } else { failed.append(item) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            heldBack = failed
            runImport(passed, verified: true, held: failed)
        }
    }

    private func importHeldBack() {
        let items = heldBack
        heldBack = []
        importing = true
        resultMessage = nil
        runImport(items, verified: false, held: [])
    }

    /// held 显式传入：刚写入的 @State 在同一事件里回读不保证是新值
    private func runImport(_ items: [ProviderImportCandidate], verified: Bool, held: [ProviderImportCandidate]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = items.isEmpty ? (imported: [String](), errors: [String]())
                : ProviderImportService.importSelected(items)
            DispatchQueue.main.async {
                importing = false
                selected = []
                let imported = Set(result.imported)
                for index in candidates.indices where imported.contains(candidates[index].providerID) {
                    candidates[index].unavailableReason = verified ? "已导入" : "已导入（未实测通过）"
                }
                var lines = ["已导入 \(result.imported.count) 条线路" + (verified ? "" : "（未实测通过，用的时候留意）")]
                lines += result.errors
                if !held.isEmpty {
                    lines.append("有 \(held.count) 条实测没通过，先没导入（原因见各条下方）。"
                        + "确定要用的话可以点下面的按钮仍然导入。")
                }
                resultMessage = lines.joined(separator: "\n")
                if !result.imported.isEmpty { onComplete?() }
            }
        }
    }
}
