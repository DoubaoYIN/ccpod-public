import Foundation

// 网关静默换模（请求的模型 ≠ 实际路由）的判定与提醒节奏。纯函数、无依赖，
// scripts/tests/test_routing_leak.sh 脱离 App 单测。
//
// 为什么要盯：CCR 回 200 并回显请求的模型名，会话记录 / 状态栏 / 子代理的身份提示全写 Opus，
// 唯一说真话的是账本的 logical_model。2026-10-09：子代理被换成 GLM 从 09-26 持续两周没人发现，
// 根因是 ccdoctor「网关路由」要人手动跑（PITFALLS #57）。
struct RoutingLeakRow: Equatable {
    let model: String          // 账本 model：请求的模型，裸名（无厂商前缀，可能带 [1m]）
    let logicalModel: String   // 账本 logical_model：实际路由，"厂商/模型"
    let count: Int
    let last: String           // max(created_at)，ISO 文本，字符串比较即时间比较
}

enum RoutingLeakPolicy {
    /// 修复前启动的会话会一直产生换模记录，不能每轮都响
    static let minAlertGap: TimeInterval = 6 * 60 * 60

    /// 与 ccdoctor「网关路由」同一判据：实际路由不是「某厂商/请求的模型」就是被换了。[1m] 后缀两边都剥掉再比。
    /// 入站 401 不进账本、直连请求不进账本，所以 logical_model 为空的行不判。
    static func isSwapped(model: String, logicalModel: String) -> Bool {
        guard model != "unknown", !model.isEmpty, let slash = logicalModel.firstIndex(of: "/") else { return false }
        return bare(model) != bare(String(logicalModel[logicalModel.index(after: slash)...]))
    }

    static func bare(_ model: String) -> String {
        model.lowercased().hasSuffix("[1m]") ? String(model.dropLast(4)) : model
    }

    static func swapped(_ rows: [RoutingLeakRow]) -> [RoutingLeakRow] {
        rows.filter { isSwapped(model: $0.model, logicalModel: $0.logicalModel) }
    }

    /// 弹窗那一行；nil = 没有换模。最多列 3 组，按条数降序。
    static func summary(_ rows: [RoutingLeakRow], hours: Int) -> String? {
        let hit = swapped(rows)
        guard !hit.isEmpty else { return nil }
        let total = hit.reduce(0) { $0 + $1.count }
        let detail = hit.sorted { $0.count > $1.count }.prefix(3)
            .map { "\($0.model) → \($0.logicalModel) ×\($0.count)" }.joined(separator: "、")
        return "近 \(hours) 小时有 \(total) 条请求被网关换成别的模型：\(detail)"
    }

    /// 首次发现就提醒；之后只在「距上次提醒 ≥ 6 小时」且「有比上次提醒更新的换模记录」时再提醒。
    static func shouldAlert(rows: [RoutingLeakRow], lastAlertedAt: Date?, now: Date) -> Bool {
        let hit = swapped(rows)
        guard !hit.isEmpty else { return false }
        guard let last = lastAlertedAt else { return true }
        guard now.timeIntervalSince(last) >= minAlertGap else { return false }
        let since = ledgerTimestamp(last)
        return hit.contains { $0.last > since }
    }

    static func alert(_ rows: [RoutingLeakRow], hours: Int) -> (title: String, body: String)? {
        guard let body = summary(rows, hours: hours) else { return nil }
        return ("网关把请求换成了别的模型", body + "。会话里显示的模型名不可信；详见菜单栏线路区或 ccdoctor「网关路由」")
    }

    /// 账本 created_at 的格式："2026-10-09T01:50:31.716Z"
    static func ledgerTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
