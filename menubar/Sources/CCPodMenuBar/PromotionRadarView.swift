import SwiftUI

/// 优惠雷达面板。
///
/// 三条用户偏好落在这里（memory「大白话+诚实标注」）：
/// 1. **单一滚动区**：整窗只有一个 ScrollView，不嵌套。
/// 2. **报错收起，只露 ⚠️**：失败原文默认折起来，点标题才展开——但 ⚠️ 本身永远看得见。
/// 3. **能力边界如实标注**：`verified == false` 的活动一律带 ❓ 和「未核实」，
///    并且永远不发通知（`PromotionNotifyPolicy.isAlertable` 已把这条钉死）。
///
/// ⚠️ 硬约束（spec §0.3）：这个窗口**没有任何按钮会改配置**。
/// 唯一的动作是「立即抓取」和「打开厂商原页」。加任何「一键切线路」之前先读 spec §0.3。
struct PromotionRadarView: View {
    @ObservedObject private var service = PromotionService.shared
    /// 展开了哪几条情报的原文摘录。key = `Promotion.rowID`（id|line）——
    /// **不能用 `p.id`**：同一 URL 配在两条线路上时两条情报 id 相同，
    /// 用 id 会出现「点一行的原文，另一行也跟着展开」。
    @State private var shownErrors: Set<String> = []
    /// 「已过期」默认折起：用户来看的是「现在能省什么」，不是历史
    @State private var showExpired = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let why = service.unavailable {
                        notice(why)
                    }
                    section("生效中", items: filtered(.active),
                            empty: "现在没有已核实的优惠在跑。下面「情报来源」能看到 ccpod 读了哪些页。")
                    section("即将开始", items: filtered(.upcoming), empty: nil)
                    expiredSection
                    sourcesSection
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 540, height: 600)
        // 打开窗口时对一次通知权限：用户可能刚在系统设置里改过，
        // 不同步的话面板会说「会提醒你」而实际上提醒是哑的。
        .onAppear { service.refreshNotifyPermission() }
    }

    // MARK: 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("优惠雷达")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    service.runFetch(manual: true)
                } label: {
                    Label(service.running ? "抓取中…" : "立即抓取",
                          systemImage: service.running ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .disabled(service.running)
                .help("现在就把所有配了优惠页的线路重抓一遍。平时每天 21:00 自动跑。")
            }
            HStack(spacing: 6) {
                if let at = service.lastRunAt {
                    Text("上次抓取")
                    Text(at, style: .relative)
                        .font(.system(size: 11, design: .monospaced))
                } else {
                    Text("还没抓过。点右上「立即抓取」，或等每天 21:00。")
                }
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            if service.notifyBlocked {
                notice("🔕 系统通知权限是关的——情报照抓、面板照显示，但不会弹提醒。"
                     + "要提醒就去「系统设置 → 通知 → CCPod」打开。")
            }
        }
        .padding(14)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    // MARK: 情报三节

    private func filtered(_ status: PromotionStatus) -> [Promotion] {
        service.promotions.filter { $0.status == status }
    }

    @ViewBuilder
    private func section(_ title: String, items: [Promotion], empty: String?) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                // id: \.rowID 是**必须**的，不是风格选择：Promotion.id 在数组里不唯一
                // （见模型注释），拿它当行标识会触发 "Multiple children have the same
                // identity" 且渲染行为未定义。Promotion 故意不 conform Identifiable，
                // 所以漏写这个 `id:` 会直接编译不过 —— 别为了少打几个字去补那个 conformance。
                ForEach(items, id: \.rowID) { p in
                    promotionRow(p)
                }
            }
        } else if let empty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(empty)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var expiredSection: some View {
        let items = filtered(.expired)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    showExpired.toggle()
                } label: {
                    Label("已过期（\(items.count)）",
                          systemImage: showExpired ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                if showExpired {
                    ForEach(items, id: \.rowID) { p in
                        promotionRow(p).opacity(0.6)
                    }
                }
            }
        }
    }

    private func promotionRow(_ p: Promotion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // 🌙 = 已核实（官方页字面写着，可以照着安排）
                // ❓ = 未核实（永远不发通知，只在面板里露个脸）
                Text(p.verified ? "🌙" : "❓")
                    .font(.system(size: 12))
                Text(p.title)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let w = p.window, let cd = PromotionNotifyPolicy.countdownText(window: w, now: Date()) {
                    Text(cd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text(p.line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                if let w = p.window {
                    Text("\(w.start)–\(w.endsNextDay ? "次日 " : "")\(w.end)（\(w.tz)）")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if let d = p.discount?.text {
                    Text(d).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
            }

            if !p.verified {
                Text("未核实：这条是限时活动一类的说法，ccpod 没法从公开页确认它对你的账号成立。自己去看原页，别照着它安排用量。")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if let from = p.validFrom { Text("自 \(from)").font(.system(size: 10)).foregroundColor(.secondary) }
                if let until = p.validUntil { Text("至 \(until)").font(.system(size: 10)).foregroundColor(.secondary) }
                Spacer()
                // 打开厂商原页。这是**用户主动点击**，不是自动抓取——
                // 「不打开用户正在使用的浏览器」那条红线管的是自动化，不管用户自己点链接。
                if let url = URL(string: p.source.url) {
                    Button("看原页") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                }
                if !p.evidence.isEmpty {
                    Button(shownErrors.contains(p.rowID) ? "收起原文" : "原文") {
                        if shownErrors.contains(p.rowID) { shownErrors.remove(p.rowID) }
                        else { shownErrors.insert(p.rowID) }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
            }

            if shownErrors.contains(p.rowID) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(p.evidence.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: 情报来源（页级四态）

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("情报来源")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            if service.pages.isEmpty {
                Text("还没有任何线路配了优惠页。去「管线管理」，在某条 gateway 管线下填一个公开定价页网址。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(service.pages) { page in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(PromotionPageCopy.label(page.status))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(page.status == .ok ? .secondary : .orange)
                            Text(page.line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                            if page.status != .ok, let url = URL(string: page.url) {
                                Button("看原页") { NSWorkspace.shared.open(url) }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 10))
                            }
                        }
                        if page.status != .ok {
                            Text(PromotionPageCopy.explanation(page))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(page.status == .ok ? 0.02 : 0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
    }
}
