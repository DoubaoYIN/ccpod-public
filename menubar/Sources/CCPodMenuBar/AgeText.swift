import Foundation

/// 「多久以前」的统一说法：线路测通结果、额度更新时间共用。
/// 原来各写各的，额度那边超过一天还在说「50 小时前更新」，测通结果干脆没有时间（2026-10-09 线路状态审查）。
enum AgeText {
    /// 刚刚 / N 分钟前 / N 小时前 / N 天前；超过 7 天直接写日期（「23 天前」不如「9 月 16 日」好认）。
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))   // 时钟回拨按「刚刚」算，不出负数
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3_600) 小时前" }
        let days = seconds / 86_400
        if days <= 7 { return "\(days) 天前" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日"
        return formatter.string(from: date)
    }
}
