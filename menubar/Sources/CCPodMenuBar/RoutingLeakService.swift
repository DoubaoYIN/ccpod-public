import Foundation
import SQLite3
import UserNotifications

// 网关静默换模的周期检查：只读本机 CCR 账本，不联网、不碰密钥、毫秒级。判定与节奏在 RoutingLeakPolicy。
enum RoutingLeakService {
    static let windowHours = 24
    static let lastAlertKey = "routingLeakLastAlertedAt"   // `defaults read com.ccpod.menubar` 可查

    /// 近 24 小时真实会话（client = Profile: Claude Code；CC Daily 探测故意拿裸名去打各厂商，不算）
    /// 按「请求模型 × 实际路由」聚合；账本读不了 → nil（不知道，UI 什么都不说）。
    static func rows() -> [RoutingLeakRow]? {
        let since = RoutingLeakPolicy.ledgerTimestamp(Date().addingTimeInterval(-Double(windowHours) * 3600))
        return ModelOnboardService.withLedger { db in
            ModelOnboardService.query(db, """
                select model, logical_model, count(*), max(created_at) from usage_events
                where created_at >= ?1 and client = 'Profile: Claude Code' and model != 'unknown'
                  and logical_model like '%/%'
                group by model, logical_model
                """, since, columns: 4)?
                .map { RoutingLeakRow(model: $0[0], logicalModel: $0[1], count: Int($0[2]) ?? 0, last: $0[3]) }
        }
    }

    /// 后台线程调用。返回弹窗那一行（nil = 没有换模或账本读不了），顺带按节奏发系统通知。
    static func check(now: Date = Date()) -> String? {
        guard let rows = rows() else { return nil }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: lastAlertKey) as? Date
        if RoutingLeakPolicy.shouldAlert(rows: rows, lastAlertedAt: last, now: now),
           let alert = RoutingLeakPolicy.alert(rows, hours: windowHours) {
            defaults.set(now, forKey: lastAlertKey)
            postNotification(title: alert.title, body: alert.body)
        }
        return RoutingLeakPolicy.summary(rows, hours: windowHours)
    }

    private static func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }   // 没授权时弹窗那一行和 ccdoctor 仍然会说（PITFALLS #42）
            let content = UNMutableNotificationContent()
            content.title = gatewayVisibleText(title)
            content.body = gatewayVisibleText(body)
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "routing-leak-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }
}
