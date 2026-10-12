import Foundation

// RoutingLeakPolicy 单测：输入用 2026-10-09 CCR 账本里的真实形态。

@main struct RoutingLeakTests {
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ label: String, _ what: String) {
        if condition {
            print("  ok   \(label)")
        } else {
            failures.append(label)
            print("  FAIL \(label) —— \(what)")
        }
    }

    static func main() {
        typealias P = RoutingLeakPolicy
        let iso = ISO8601DateFormatter()

        // 判定（与 ccdoctor「网关路由」同一判据）
        expect(P.isSwapped(model: "claude-opus-5-5", logicalModel: "glm/glm-5.3"), "Opus 落到 GLM = 换模", "10-09 账本 435 条就是它")
        expect(!P.isSwapped(model: "glm-5.3", logicalModel: "glm/glm-5.3"), "请求就写 GLM = 不算换模", "新会话的子代理档")
        expect(!P.isSwapped(model: "claude-fable-5-1[1m]", logicalModel: "aigocode/claude-fable-5-1"), "[1m] 后缀不算换", "全局默认模型带 [1m]")
        expect(!P.isSwapped(model: "claude-fable-5-1", logicalModel: "aigocode/claude-fable-5-1[1M]"), "实际路由带 [1M] 也不算换", "")
        expect(!P.isSwapped(model: "unknown", logicalModel: "glm/glm-5.3"), "unknown 不判", "")
        expect(!P.isSwapped(model: "claude-opus-5-5", logicalModel: ""), "没有实际路由不判", "入站 401 / 直连请求不进账本")

        // 摘要
        let swapped = RoutingLeakRow(model: "claude-opus-5-5", logicalModel: "glm/glm-5.3", count: 385, last: "2026-10-09T01:38:07.645Z")
        let fine = RoutingLeakRow(model: "glm-5.3", logicalModel: "glm/glm-5.3", count: 40, last: "2026-10-09T02:00:00.000Z")
        let small = RoutingLeakRow(model: "claude-sonnet-5-5", logicalModel: "glm/glm-5.3", count: 1, last: "2026-10-09T13:17:31.429Z")
        let s = P.summary([fine, small, swapped], hours: 24)
        expect(s == "近 24 小时有 386 条请求被网关换成别的模型：claude-opus-5-5 → glm/glm-5.3 ×385、claude-sonnet-5-5 → glm/glm-5.3 ×1",
               "摘要只算被换的、按条数降序", s ?? "nil")
        expect(P.summary([fine], hours: 24) == nil, "没被换 = 没摘要", "")
        expect(P.alert([fine], hours: 24) == nil, "没被换 = 不发通知", "")

        // 节奏
        let now = iso.date(from: "2026-10-09T03:00:00Z")!
        expect(P.shouldAlert(rows: [swapped], lastAlertedAt: nil, now: now), "首次发现要提醒", "")
        expect(!P.shouldAlert(rows: [fine], lastAlertedAt: nil, now: now), "没被换不提醒", "")
        expect(!P.shouldAlert(rows: [swapped], lastAlertedAt: now.addingTimeInterval(-3600), now: now), "1 小时内不重复", "旧会话会一直产生换模记录")
        expect(P.shouldAlert(rows: [swapped], lastAlertedAt: iso.date(from: "2026-10-08T20:00:00Z")!, now: now), "7 小时后且有新记录 → 再提醒", "")
        let stale = RoutingLeakRow(model: "claude-opus-5-5", logicalModel: "glm/glm-5.3", count: 3, last: "2026-10-08T19:00:00.000Z")
        expect(!P.shouldAlert(rows: [stale], lastAlertedAt: iso.date(from: "2026-10-08T20:00:00Z")!, now: now), "7 小时后但没有新记录 → 不提醒", "")
        expect(P.ledgerTimestamp(now) == "2026-10-09T03:00:00.000Z", "时间戳格式与账本一致", P.ledgerTimestamp(now))

        if failures.isEmpty {
            print("RoutingLeakPolicy: all passed")
        } else {
            print("RoutingLeakPolicy: \(failures.count) failed: \(failures.joined(separator: ", "))")
            exit(1)
        }
    }
}
