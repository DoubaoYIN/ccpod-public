import SwiftUI

// LineSettingsEditor — 默认线路/模型编辑（B 路线④）。
// 五档（主/Opus/Sonnet/Fable/Haiku）经 CCR 管理 RPC 保存并 applyProfile 生效。
// 注意：本编辑器不做模型级探测（探测留在实验室 line-check --probe），保存即生效。
struct LineSettingsEditor: View {
    @ObservedObject var gateway: CCRGatewayService
    @ObservedObject var lineCheck: LineCheckService
    /// 保存成功后通知父视图（刷新线路列表等）；2026-10-02 接入管线管理窗口时加的接线口。
    var onSaved: (() -> Void)? = nil

    @State private var options: [String] = []
    @State private var selections: [String: String] = [:]
    /// 打开时配置里的真实值；nil = 没设置（界面显示的只是默认第一项，用户不碰就绝不写）
    @State private var openedTiers: [String: String?] = [:]
    /// 用户在本窗口主动选过的档位：保存时只写这些（EditorDelta.tiers）
    @State private var touched: Set<String> = []
    @State private var status: String?
    @State private var busy = false
    @State private var loaded = false

    private let tiers: [(label: String, key: String)] = [
        ("主对话", "model"), ("Opus", "opusModel"), ("Sonnet", "sonnetModel"),
        ("Fable", "fableModel"), ("Haiku", "haikuModel")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if loaded {
                ForEach(tiers, id: \.key) { tier in
                    HStack(spacing: 6) {
                        Text(tier.label)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 46, alignment: .leading)
                        Picker("", selection: binding(for: tier.key)) {
                            ForEach(displayOptions, id: \.self) { Text(gatewayModelDisplayName($0)).tag($0) }
                        }
                        .labelsHidden()
                        .font(.system(size: 11))
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        save()
                    } label: {
                        Label(busy ? "保存中…" : "保存并生效", systemImage: "checkmark.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(busy ? .secondary : .accentColor)
                    .disabled(busy)
                    if let status {
                        Text(status)
                            .font(.system(size: 10))
                            .foregroundColor(status.hasPrefix("✅") ? .green : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            } else if busy {
                Text("读取配置中…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else if let status {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重新读取") { load() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
            }
        }
        .onAppear {
            if !loaded && !busy { load() }
        }
    }

    // 列表展示用 slash 形式（provider/model），写库前转回 CCR 的逗号形式
    private var displayOptions: [String] { options }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { selections[key] ?? "" }, set: { value in
            if selections[key] != value { touched.insert(key) }
            selections[key] = value
        })
    }

    private func tierValue(_ config: [String: Any], _ key: String) -> String? {
        guard let profile = config["profile"] as? [String: Any],
              let cc = profile["claudeCode"] as? [String: Any],
              let value = cc[key] as? String, !value.isEmpty else { return nil }
        return value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).joined(separator: "/")
    }

    // 只转换厂商与模型之间的分隔符；模型自身可含命名空间（如 x-ai/grok-4.7）。
    private func storedValue(_ value: String) -> String {
        value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).joined(separator: ",")
    }

    private func load() {
        busy = true
        status = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let state = CCRConfigService.serviceState() else {
                    throw NSError(domain: "line-settings", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "读不到网关运行信息（网关未运行？）"])
                }
                let config = try CCRConfigService.fetchConfig(state: state)
                var opts: [String] = []
                if let providers = config["Providers"] as? [[String: Any]] {
                    for p in providers {
                        guard let name = p["name"] as? String, !name.isEmpty else { continue }
                        let models = (p["models"] as? [Any])?.compactMap { $0 as? String } ?? []
                        opts.append(contentsOf: models.map { "\(name)/\($0)" })
                    }
                }
                var sel: [String: String] = [:]
                var opened: [String: String?] = [:]
                for tier in tiers {
                    let value = tierValue(config, tier.key)
                    opened[tier.key] = .some(value)
                    sel[tier.key] = value ?? opts.first ?? ""
                }
                DispatchQueue.main.async {
                    options = opts.sorted()
                    selections = sel
                    openedTiers = opened
                    touched = []
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
        // 只写用户在本窗口主动改过的档位；没碰的（含界面默认显示的第一项）以网关里的为准。
        // 原来五档全写：窗口开着时别处改过的档位会被回滚，没设置过的档位会被写成列表第一项。
        let changed = EditorDelta.tiers(opened: openedTiers, selected: selections, touched: touched)
        guard !changed.isEmpty else {
            status = "没有改动，没写网关"
            return
        }
        busy = true
        status = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let state = CCRConfigService.serviceState() else {
                    throw NSError(domain: "line-settings", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "读不到网关运行信息"])
                }
                var config = try CCRConfigService.fetchConfig(state: state)
                // 选的模型保存时已不在网关清单里 → 写进去会被网关静默转给别家（PITFALLS #43），整笔拦下
                var fresh = Set<String>()
                for p in config["Providers"] as? [[String: Any]] ?? [] {
                    guard let name = p["name"] as? String, !name.isEmpty else { continue }
                    for m in (p["models"] as? [Any])?.compactMap({ $0 as? String }) ?? [] { fresh.insert("\(name)/\(m)") }
                }
                let gone = EditorDelta.missing(changed, options: fresh)
                guard gone.isEmpty else {
                    throw NSError(domain: "line-settings", code: 3, userInfo: [NSLocalizedDescriptionKey:
                        "\(gone.joined(separator: "、")) 已不在网关清单里，先点「重新读取」再选"])
                }
                guard var profile = config["profile"] as? [String: Any],
                      var cc = profile["claudeCode"] as? [String: Any] else {
                    throw NSError(domain: "line-settings", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "配置缺少 profile.claudeCode"])
                }
                for tier in tiers {
                    guard let value = changed[tier.key] else { continue }
                    let stored = storedValue(value)
                    cc[tier.key] = stored
                    if tier.key == "haikuModel" { cc["smallFastModel"] = stored }
                }
                profile["claudeCode"] = cc
                if var profiles = profile["profiles"] as? [[String: Any]] {
                    for index in profiles.indices where profiles[index]["agent"] as? String == "claude-code" {
                        for tier in tiers {
                            if let value = changed[tier.key] {
                                profiles[index][tier.key] = storedValue(value)
                                if tier.key == "haikuModel" { profiles[index]["smallFastModel"] = storedValue(value) }
                            }
                        }
                    }
                    profile["profiles"] = profiles
                }
                config["profile"] = profile
                try CCRConfigService.saveAndApply(config: config, state: state)
                DispatchQueue.main.async {
                    status = "✅ 已保存并生效"
                    busy = false
                    for (key, value) in changed { openedTiers[key] = .some(value) }
                    touched = []
                    gateway.refresh()
                    lineCheck.refresh()
                    onSaved?()
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
