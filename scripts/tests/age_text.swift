import Foundation

// AgeText 单测：线路测通结果、额度更新时间共用的「多久以前」说法。

@main struct AgeTextTests {
    static var failures: [String] = []

    static func expect(_ actual: String, _ expected: String, _ label: String) {
        if actual == expected {
            print("  ok   \(label)")
        } else {
            failures.append(label)
            print("  FAIL \(label) —— 期望「\(expected)」，实际「\(actual)」")
        }
    }

    static func main() {
        let now = Date(timeIntervalSince1970: 1_791_500_000)   // 2026-10-09 07:33 +0800
        func ago(_ seconds: Int) -> String { AgeText.ago(now.addingTimeInterval(TimeInterval(-seconds)), now: now) }

        expect(ago(0), "刚刚", "0 秒")
        expect(ago(59), "刚刚", "59 秒")
        expect(ago(60), "1 分钟前", "整 1 分钟")
        expect(ago(3_599), "59 分钟前", "差 1 秒到 1 小时")
        expect(ago(3_600), "1 小时前", "整 1 小时")
        expect(ago(86_399), "23 小时前", "差 1 秒到 1 天")
        expect(ago(86_400), "1 天前", "整 1 天")
        expect(ago(50 * 3_600), "2 天前", "50 小时（原额度文案写「50 小时前」）")
        expect(ago(7 * 86_400), "7 天前", "整 7 天")
        expect(ago(-120), "刚刚", "时钟回拨（未来时间）")

        // 超过 7 天写日期：用同一时区算期望值，不把本机时区写死进断言
        let old = now.addingTimeInterval(-23 * 86_400)
        let parts = Calendar.current.dateComponents([.month, .day], from: old)
        expect(AgeText.ago(old, now: now), "\(parts.month!) 月 \(parts.day!) 日", "23 天前写日期")

        if failures.isEmpty {
            print("PASS age_text")
        } else {
            print("FAIL age_text: \(failures.joined(separator: ", "))")
            exit(1)
        }
    }
}
